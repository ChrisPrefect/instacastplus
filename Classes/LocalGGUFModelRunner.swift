//
//  LocalGGUFModelRunner.swift
//  Instacast
//
//  Minimal llama.cpp runner for downloaded GGUF chapter models.
//

import Foundation

#if canImport(llama)
@preconcurrency import llama

private enum LocalGGUFModelError: LocalizedError {
    case modelLoadFailed(String)
    case contextLoadFailed
    case tokenizeFailed
    case promptTooLong(Int, Int)
    case decodeFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            NSLog("[LocalGGUFModelRunner] Model load failed: %@", path)
            return "Kapitelmodell konnte nicht geöffnet werden. Bitte lösche es und lade es erneut."
        case .contextLoadFailed:
            return "Kapitelmodell konnte nicht vorbereitet werden."
        case .tokenizeFailed:
            return "Kapitel konnten nicht vorbereitet werden."
        case .promptTooLong(let count, let limit):
            NSLog("[LocalGGUFModelRunner] Prompt too long: %d/%d tokens", count, limit)
            return "Die Folge ist zu lang für dieses Kapitelmodell."
        case .decodeFailed(let code):
            NSLog("[LocalGGUFModelRunner] Decode failed: %d", code)
            return "Kapitelmodell konnte die Kapitel nicht erstellen."
        case .cancelled:
            return "Kapitelgenerierung abgebrochen."
        }
    }
}

actor LocalGGUFModelRunner {
    private final class Handle: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        var sampler: UnsafeMutablePointer<llama_sampler>
        var batch: llama_batch

        init(model: OpaquePointer, context: OpaquePointer, batchCapacity: Int32) {
            self.model = model
            self.context = context
            self.vocab = llama_model_get_vocab(model)

            let samplerParams = llama_sampler_chain_default_params()
            self.sampler = llama_sampler_chain_init(samplerParams)
            llama_sampler_chain_add(self.sampler, llama_sampler_init_greedy())

            self.batch = llama_batch_init(batchCapacity, 0, 1)
        }

        deinit {
            llama_sampler_free(sampler)
            llama_batch_free(batch)
            llama_model_free(model)
            llama_free(context)
            llama_backend_free()
        }
    }

    private let handle: Handle
    private let contextTokens: Int
    private let batchCapacity: Int32 = 512
    private var pendingUTF8: [CChar] = []
    private var shouldCancel = false

    private init(model: OpaquePointer,
                 context: OpaquePointer,
                 contextTokens: Int) {
        self.contextTokens = contextTokens
        self.handle = Handle(model: model, context: context, batchCapacity: batchCapacity)
    }

    static func create(modelURL: URL, contextTokens: Int32 = LocalGGUFModelRunner.recommendedContextTokens()) throws -> LocalGGUFModelRunner {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = -1
        #endif

        guard let model = llama_model_load_from_file(modelURL.path, modelParams) else {
            llama_backend_free()
            throw LocalGGUFModelError.modelLoadFailed(modelURL.path)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextTokens)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        let threadCount = max(2, min(ProcessInfo.processInfo.processorCount - 1, 6))
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)

        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            llama_backend_free()
            throw LocalGGUFModelError.contextLoadFailed
        }

        return LocalGGUFModelRunner(model: model, context: context, contextTokens: Int(contextTokens))
    }

    static func recommendedContextTokens() -> Int32 {
        let memory = ProcessInfo.processInfo.physicalMemory
        return memory >= 7_500_000_000 ? 65_536 : 32_768
    }

    var maxInputTokens: Int {
        max(contextTokens - 2_048, contextTokens / 2)
    }

    func cancel() {
        shouldCancel = true
    }

    func tokenCount(system: String, user: String) throws -> Int {
        try tokenize(formattedChatPrompt(system: system, user: user), addSpecial: true).count
    }

    func generate(system: String,
                  user: String,
                  maxNewTokens: Int,
                  stopSequences: [String] = ["</s>", "<end_of_turn>", "<|end_of_text|>"]) async throws -> String {
        shouldCancel = false
        pendingUTF8.removeAll()
        llama_memory_clear(llama_get_memory(handle.context), true)
        llama_sampler_reset(handle.sampler)

        let prompt = formattedChatPrompt(system: system, user: user)
        let promptTokens = try tokenize(prompt, addSpecial: true)
        let generationLimit = min(max(maxNewTokens, 1), max(contextTokens - promptTokens.count - 1, 1))
        guard promptTokens.count + generationLimit < contextTokens else {
            throw LocalGGUFModelError.promptTooLong(promptTokens.count + generationLimit, contextTokens)
        }

        var position: Int32 = 0
        var tokenIndex = 0
        while tokenIndex < promptTokens.count {
            try checkCancellation()
            clearBatch()

            let remaining = promptTokens.count - tokenIndex
            let count = min(Int(batchCapacity), remaining)
            for offset in 0..<count {
                let logits = tokenIndex + offset == promptTokens.count - 1
                addToken(promptTokens[tokenIndex + offset], position: position + Int32(offset), logits: logits)
            }

            try decodeCurrentBatch()
            position += Int32(count)
            tokenIndex += count
        }

        var output = ""
        for _ in 0..<generationLimit {
            try checkCancellation()

            let nextToken = llama_sampler_sample(handle.sampler, handle.context, handle.batch.n_tokens - 1)
            llama_sampler_accept(handle.sampler, nextToken)
            if llama_vocab_is_eog(handle.vocab, nextToken) {
                break
            }

            output += piece(for: nextToken)
            if let stop = stopSequences.first(where: { output.contains($0) }) {
                output = output.components(separatedBy: stop).first ?? output
                break
            }

            clearBatch()
            addToken(nextToken, position: position, logits: true)
            try decodeCurrentBatch()
            position += 1
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkCancellation() throws {
        if shouldCancel || Task.isCancelled {
            throw LocalGGUFModelError.cancelled
        }
    }

    private func formattedChatPrompt(system: String, user: String) -> String {
        let fallback = """
        System:
        \(system)

        User:
        \(user)

        Assistant:
        """

        guard let template = llama_model_chat_template(handle.model, nil) else {
            return fallback
        }

        return system.withCString { systemPointer in
            user.withCString { userPointer in
                "system".withCString { systemRole in
                    "user".withCString { userRole in
                        let messages = [
                            llama_chat_message(role: systemRole, content: systemPointer),
                            llama_chat_message(role: userRole, content: userPointer),
                        ]
                        return messages.withUnsafeBufferPointer { messageBuffer in
                            var buffer = [CChar](repeating: 0, count: max((system.utf8.count + user.utf8.count) * 3, 4096))
                            var written = llama_chat_apply_template(template,
                                                                    messageBuffer.baseAddress,
                                                                    messageBuffer.count,
                                                                    true,
                                                                    &buffer,
                                                                    Int32(buffer.count))
                            if written < 0 {
                                return fallback
                            }
                            if Int(written) > buffer.count {
                                buffer = [CChar](repeating: 0, count: Int(written))
                                written = llama_chat_apply_template(template,
                                                                    messageBuffer.baseAddress,
                                                                    messageBuffer.count,
                                                                    true,
                                                                    &buffer,
                                                                    Int32(buffer.count))
                            }
                            guard written > 0, Int(written) <= buffer.count else {
                                return fallback
                            }
                            let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
                            return String(decoding: bytes, as: UTF8.self)
                        }
                    }
                }
            }
        }
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        var capacity = max(text.utf8.count + 8, 32)
        while true {
            var tokens = [llama_token](repeating: 0, count: capacity)
            let tokenCount = text.withCString { textPointer in
                tokens.withUnsafeMutableBufferPointer { tokenBuffer in
                    llama_tokenize(handle.vocab,
                                   textPointer,
                                   Int32(text.utf8.count),
                                   tokenBuffer.baseAddress,
                                   Int32(tokenBuffer.count),
                                   addSpecial,
                                   true)
                }
            }

            if tokenCount >= 0 {
                return Array(tokens.prefix(Int(tokenCount)))
            }

            let required = Int(-tokenCount)
            guard required > capacity else {
                throw LocalGGUFModelError.tokenizeFailed
            }
            capacity = required
        }
    }

    private func clearBatch() {
        handle.batch.n_tokens = 0
    }

    private func addToken(_ token: llama_token, position: llama_pos, logits: Bool) {
        let index = Int(handle.batch.n_tokens)
        handle.batch.token[index] = token
        handle.batch.pos[index] = position
        handle.batch.n_seq_id[index] = 1
        handle.batch.seq_id[index]![0] = 0
        handle.batch.logits[index] = logits ? 1 : 0
        handle.batch.n_tokens += 1
    }

    private func decodeCurrentBatch() throws {
        let result = llama_decode(handle.context, handle.batch)
        guard result == 0 else {
            throw LocalGGUFModelError.decodeFailed(result)
        }
    }

    private func piece(for token: llama_token) -> String {
        var chars = [CChar](repeating: 0, count: 32)
        var byteCount = llama_token_to_piece(handle.vocab, token, &chars, Int32(chars.count), 0, false)
        if byteCount < 0 {
            chars = [CChar](repeating: 0, count: Int(-byteCount))
            byteCount = llama_token_to_piece(handle.vocab, token, &chars, Int32(chars.count), 0, false)
        }
        guard byteCount > 0 else { return "" }

        pendingUTF8.append(contentsOf: chars.prefix(Int(byteCount)))
        var candidate = pendingUTF8
        candidate.append(0)
        if let string = candidate.withUnsafeBufferPointer({ buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            return String(validatingCString: base)
        }) {
            pendingUTF8.removeAll()
            return string
        }
        return ""
    }
}

#else

actor LocalGGUFModelRunner {
    static func create(modelURL: URL, contextTokens: Int32 = LocalGGUFModelRunner.recommendedContextTokens()) throws -> LocalGGUFModelRunner {
        throw NSError(domain: "LocalGGUFModelRunner", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Kapitelmodell ist in dieser App-Version nicht verfügbar."])
    }

    static func recommendedContextTokens() -> Int32 { 0 }
    var maxInputTokens: Int { 0 }
    func cancel() {}
    func tokenCount(system: String, user: String) throws -> Int { 0 }
    func generate(system: String, user: String, maxNewTokens: Int, stopSequences: [String] = []) async throws -> String { "" }
}

#endif
