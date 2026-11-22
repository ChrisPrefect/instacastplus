//
//  ICSileroVAD.swift
//  InstacastPlus
//
//  Voice activity detection for pause shortening: Silero VAD v6.2.3 (Silero Team, MIT license,
//  see SileroVAD-LICENSE.txt), 16 kHz model. The forward pass is a direct port of the official
//  ONNX graph (silero_vad_16k_op15.onnx) to Accelerate, so it runs on every supported OS
//  (iOS 17, Mac Catalyst) without an inference runtime. The weights are the graph's initializers,
//  exported unchanged into silero_vad_16k_v6.2.3.bin. Tools/SilenceTrim/README.md describes the
//  numerical check against ONNX Runtime.
//
//  Per call the model takes 512 new samples (32 ms) plus the last 64 samples of the previous
//  call and returns the probability that the window contains speech. The LSTM state carries
//  context from call to call; `reset()` starts a new stream.
//
//  Not thread safe; the compressor drives one instance from its serial queue.
//

import Foundation
import Accelerate

/// The immutable weights, loaded once and shared by every stream.
final class ICSileroVADModel: @unchecked Sendable {
    fileprivate let stftBasis: [Float]          // [258 x 256]
    fileprivate let convWeights: [[Float]]      // [O x C*3] per layer
    fileprivate let convBiases: [[Float]]
    fileprivate static let convShapes: [(out: Int, inp: Int, stride: Int)] = [(128, 129, 1), (64, 128, 2), (64, 64, 2), (128, 64, 1)]
    fileprivate let lstmWeightIH: [Float]       // [512 x 128]
    fileprivate let lstmWeightHH: [Float]       // [512 x 128]
    fileprivate let lstmBias: [Float]           // bias_ih + bias_hh, [512]
    fileprivate let finalWeight: [Float]        // [128]
    fileprivate let finalBias: Float
    // Layouts for time-major matrix products (computed once from the ONNX tensors).
    fileprivate let stftBasisT: [Float]         // [256 x 258]
    fileprivate let convWeightsT: [[Float]]     // [(tap, channel) x out] per layer

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: ICSileroVADModel?   // guarded by cacheLock
    /// Where command line tools find the weights (no app bundle).
    nonisolated(unsafe) static var resourceURLOverride: URL?

    /// The model in the app bundle (silero_vad_16k_v6.2.3.bin), loaded on first use.
    static var bundled: ICSileroVADModel? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return cached }
        guard let url = resourceURLOverride ?? Bundle.main.url(forResource: "silero_vad_16k_v6.2.3", withExtension: "bin") else { return nil }
        cached = ICSileroVADModel(weightsURL: url)
        return cached
    }

    /// Loads the weights written by Tools/SilenceTrim (format "SVAD", version 1).
    init?(weightsURL: URL) {
        guard let data = try? Data(contentsOf: weightsURL), data.count > 12 else { return nil }
        var tensors: [String: [Float]] = [:]
        let ok: Bool = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            func u32() -> UInt32? {
                guard offset + 4 <= raw.count else { return nil }
                let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
                return UInt32(littleEndian: value)
            }
            guard raw.count >= 4, raw[0] == 0x53, raw[1] == 0x56, raw[2] == 0x41, raw[3] == 0x44 else { return false }
            offset = 4
            guard u32() == 1, let count = u32() else { return false }
            for _ in 0..<count {
                guard let nameLength = u32(), offset + Int(nameLength) <= raw.count else { return false }
                let name = String(decoding: raw[offset..<(offset + Int(nameLength))], as: UTF8.self)
                offset += Int(nameLength)
                guard let elements = u32(), offset + Int(elements) * 4 <= raw.count else { return false }
                var values = [Float](repeating: 0, count: Int(elements))
                for i in 0..<Int(elements) {
                    values[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + i * 4, as: UInt32.self)))
                }
                offset += Int(elements) * 4
                tensors[name] = values
            }
            return true
        }
        guard ok,
              let basis = tensors["model.stft.forward_basis_buffer"], basis.count == 258 * 256,
              let wih = tensors["model.decoder.rnn.weight_ih"], wih.count == 512 * 128,
              let whh = tensors["model.decoder.rnn.weight_hh"], whh.count == 512 * 128,
              let bih = tensors["model.decoder.rnn.bias_ih"], bih.count == 512,
              let bhh = tensors["model.decoder.rnn.bias_hh"], bhh.count == 512,
              let fw = tensors["model.decoder.decoder.2.weight"], fw.count == 128,
              let fb = tensors["model.decoder.decoder.2.bias"], fb.count == 1 else { return nil }
        var weights: [[Float]] = []
        var biases: [[Float]] = []
        for (k, shape) in Self.convShapes.enumerated() {
            guard let w = tensors["model.encoder.\(k).reparam_conv.weight"], w.count == shape.out * shape.inp * 3,
                  let b = tensors["model.encoder.\(k).reparam_conv.bias"], b.count == shape.out else { return nil }
            weights.append(w)
            biases.append(b)
        }
        stftBasis = basis
        convWeights = weights
        convBiases = biases
        lstmWeightIH = wih
        lstmWeightHH = whh
        var bias = [Float](repeating: 0, count: 512)
        vDSP_vadd(bih, 1, bhh, 1, &bias, 1, 512)
        lstmBias = bias
        finalWeight = fw
        finalBias = fb[0]
        var basisT = [Float](repeating: 0, count: 256 * 258)
        vDSP_mtrans(basis, 1, &basisT, 1, 256, 258)
        stftBasisT = basisT
        var transposed: [[Float]] = []
        for (k, shape) in Self.convShapes.enumerated() {
            var t = [Float](repeating: 0, count: 3 * shape.inp * shape.out)
            for o in 0..<shape.out {
                for ch in 0..<shape.inp {
                    for tap in 0..<3 {
                        t[(tap * shape.inp + ch) * shape.out + o] = weights[k][(o * shape.inp + ch) * 3 + tap]
                    }
                }
            }
            transposed.append(t)
        }
        convWeightsT = transposed
    }
}

/// One speech detection stream (LSTM state and context) on a shared model.
///
/// Every step is an Accelerate call on contiguous, time-major buffers, so the pass is fast in
/// debug builds too (a scalar version took 1.1 ms per chunk unoptimised, 28x real time).
final class ICSileroVAD {
    static let sampleRate = 16000.0
    static let chunkLength = 512
    static let contextLength = 64

    private let model: ICSileroVADModel
    private var h = [Float](repeating: 0, count: 128)
    private var c = [Float](repeating: 0, count: 128)
    private var context = [Float](repeating: 0, count: ICSileroVAD.contextLength)

    // Scratch buffers, allocated once.
    private var padded = [Float](repeating: 0, count: 640)
    private var frameRows = [Float](repeating: 0, count: 4 * 256)
    private var spectrum = [Float](repeating: 0, count: 4 * 258)
    private var layerInput = [Float](repeating: 0, count: 4 * 129)   // [time x channels]
    private var layerOutput = [Float](repeating: 0, count: 4 * 128)
    private var columns = [Float](repeating: 0, count: 4 * 3 * 129)
    private var gates = [Float](repeating: 0, count: 512)
    private var recurrent = [Float](repeating: 0, count: 512)
    private var activated = [Float](repeating: 0, count: 512)
    private var scratch = [Float](repeating: 0, count: 512)

    init(model: ICSileroVADModel) {
        self.model = model
    }

    /// Starts a new stream (after a seek).
    func reset() {
        vDSP_vclr(&h, 1, 128)
        vDSP_vclr(&c, 1, 128)
        vDSP_vclr(&context, 1, vDSP_Length(Self.contextLength))
    }

    /// Speech probability of the next 512 samples at 16 kHz (float, about -1...1).
    func process(_ samples: UnsafePointer<Float>) -> Float {
        padded.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            // Model input: 64 context samples + 512 new ones, reflection-padded by 64 on the right.
            context.withUnsafeBufferPointer { base.update(from: $0.baseAddress!, count: 64) }
            (base + 64).update(from: samples, count: 512)
            // padded[576 + i] = padded[574 - i]: copy samples 511...574, then reverse them.
            (base + 576).update(from: base + 511, count: 64)
            vDSP_vrvrs(base + 576, 1, 64)
            context.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base + 512, count: 64) }
            // STFT: 4 frames of 256 samples, hop 128 -> [4 x 258] (time-major).
            frameRows.withUnsafeMutableBufferPointer { rows in
                for t in 0..<4 { (rows.baseAddress! + t * 256).update(from: base + t * 128, count: 256) }
            }
        }
        vDSP_mmul(frameRows, 1, model.stftBasisT, 1, &spectrum, 1, 4, 258, 256)
        spectrum.withUnsafeBufferPointer { spec in
            layerInput.withUnsafeMutableBufferPointer { mag in
                for t in 0..<4 {
                    let row = spec.baseAddress! + t * 258
                    vDSP_vdist(row, 1, row + 129, 1, mag.baseAddress! + t * 129, 1, 129)
                }
            }
        }

        // Encoder: four Conv1d(kernel 3, padding 1) + ReLU as im2col products, time-major.
        var length = 4
        var zero: Float = 0
        for (k, shape) in ICSileroVADModel.convShapes.enumerated() {
            let outLength = (length + 2 - 3) / shape.stride + 1
            let width = 3 * shape.inp
            layerInput.withUnsafeBufferPointer { input in
                columns.withUnsafeMutableBufferPointer { cols in
                    for t in 0..<outLength {
                        for tap in 0..<3 {
                            let source = t * shape.stride + tap - 1
                            let destination = cols.baseAddress! + t * width + tap * shape.inp
                            if source >= 0 && source < length {
                                destination.update(from: input.baseAddress! + source * shape.inp, count: shape.inp)
                            } else {
                                vDSP_vclr(destination, 1, vDSP_Length(shape.inp))
                            }
                        }
                    }
                }
            }
            vDSP_mmul(columns, 1, model.convWeightsT[k], 1, &layerOutput, 1,
                      vDSP_Length(outLength), vDSP_Length(shape.out), vDSP_Length(width))
            layerOutput.withUnsafeMutableBufferPointer { out in
                model.convBiases[k].withUnsafeBufferPointer { bias in
                    for t in 0..<outLength {
                        let row = out.baseAddress! + t * shape.out
                        vDSP_vadd(row, 1, bias.baseAddress!, 1, row, 1, vDSP_Length(shape.out))
                    }
                }
                vDSP_vthr(out.baseAddress!, 1, &zero, out.baseAddress!, 1, vDSP_Length(outLength * shape.out))
                layerInput.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: out.baseAddress!, count: outLength * shape.out) }
            }
            length = outLength
        }

        // LSTM cell (PyTorch gate order i, f, g, o) on the single remaining time step.
        vDSP_mmul(model.lstmWeightIH, 1, layerInput, 1, &gates, 1, 512, 1, 128)
        vDSP_mmul(model.lstmWeightHH, 1, h, 1, &recurrent, 1, 512, 1, 128)
        vDSP_vadd(gates, 1, recurrent, 1, &gates, 1, 512)
        vDSP_vadd(gates, 1, model.lstmBias, 1, &gates, 1, 512)
        var count = Int32(512)
        // Sigmoid of all gates (the cell gate is replaced by its tanh below).
        vDSP_vneg(gates, 1, &scratch, 1, 512)
        vvexpf(&activated, scratch, &count)
        var one: Float = 1
        vDSP_vsadd(activated, 1, &one, &activated, 1, 512)
        vvrecf(&activated, activated, &count)
        var cellCount = Int32(128)
        activated.withUnsafeMutableBufferPointer { a in
            gates.withUnsafeBufferPointer { g in vvtanhf(a.baseAddress! + 256, g.baseAddress! + 256, &cellCount) }
            let i = a.baseAddress!, f = a.baseAddress! + 128, gg = a.baseAddress! + 256, o = a.baseAddress! + 384
            // c = f * c + i * g;  h = o * tanh(c)
            vDSP_vmul(f, 1, c, 1, &c, 1, 128)
            vDSP_vma(i, 1, gg, 1, c, 1, &c, 1, 128)
            vvtanhf(&scratch, c, &cellCount)
            vDSP_vmul(o, 1, scratch, 1, &h, 1, 128)
        }

        // Decoder: ReLU, 1x1 convolution, sigmoid.
        vDSP_vthr(h, 1, &zero, &scratch, 1, 128)
        var sum: Float = 0
        vDSP_dotpr(scratch, 1, model.finalWeight, 1, &sum, 128)
        return 1 / (1 + expf(-(sum + model.finalBias)))
    }
}

/// Streaming mono resampler to 16 kHz for the VAD: windowed-sinc (Blackman) low-pass at
/// 7.2 kHz with exact rational phases (441/160 for 44.1 kHz, 3/1 for 48 kHz).
final class ICVADResampler {
    private let up: Int          // output phases
    private let down: Int        // input samples per `up` outputs
    private let halfWidth: Int   // input samples on each side of the centre
    private let table: [Float]   // [up x (2 * halfWidth)]
    private var history: [Float] = []
    private var historyBase = 0  // absolute input index of history[0]
    private var nextOutput = 0   // absolute output index

    init(inputRate: Double) {
        let input = Int(inputRate.rounded())
        let output = Int(ICSileroVAD.sampleRate)
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(input, output)
        up = output / g
        down = input / g
        let ratio = Double(input) / Double(output)
        let cutoff = 7200.0 / Double(input) // cycles per input sample
        halfWidth = max(8, Int((8 * ratio).rounded(.up)))
        var table = [Float](repeating: 0, count: up * 2 * halfWidth)
        for phase in 0..<up {
            let fraction = Double(phase * down % up) / Double(up)
            var sum = 0.0
            var row = [Double](repeating: 0, count: 2 * halfWidth)
            for k in 0..<(2 * halfWidth) {
                let t = Double(k - halfWidth + 1) - fraction // input offset relative to the position
                let x = 2 * cutoff * t
                let sinc = abs(x) < 1e-9 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let w = (t + Double(halfWidth)) / Double(2 * halfWidth)
                let blackman = 0.42 - 0.5 * cos(2 * Double.pi * w) + 0.08 * cos(4 * Double.pi * w)
                row[k] = sinc * max(0, blackman)
                sum += row[k]
            }
            for k in 0..<(2 * halfWidth) { table[phase * 2 * halfWidth + k] = Float(row[k] / sum) }
        }
        self.table = table
    }

    func reset() {
        history.removeAll(keepingCapacity: true)
        historyBase = 0
        nextOutput = 0
    }

    /// Appends input samples and returns the 16 kHz samples that became available.
    func process(_ samples: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        history.append(contentsOf: samples)
        let width = 2 * halfWidth
        history.withUnsafeBufferPointer { hist in
            table.withUnsafeBufferPointer { taps in
                while true {
                    let position = nextOutput * down / up          // input index at or before the output
                    let first = position - halfWidth + 1
                    if first + width - 1 >= historyBase + hist.count { break }
                    let row = taps.baseAddress! + (nextOutput % up) * width
                    var acc: Float = 0
                    let index = first - historyBase
                    if index >= 0 {
                        vDSP_dotpr(hist.baseAddress! + index, 1, row, 1, &acc, vDSP_Length(width))
                    } else {
                        // Stream start: the taps before the first sample see silence.
                        for k in (-index)..<width { acc += hist[index + k] * row[k] }
                    }
                    output.append(acc)
                    nextOutput += 1
                }
            }
        }
        // Keep what the next output still needs.
        let needed = nextOutput * down / up - halfWidth + 1 - historyBase
        if needed > 4096 {
            history.removeFirst(needed)
            historyBase += needed
        }
    }
}
