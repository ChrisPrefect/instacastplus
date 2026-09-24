#!/usr/bin/env python3
"""Compile real client state/persistence/import methods against a controlled HTTP peer."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/ServerTranscriptionManager.swift").read_text()

def declaration(signature):
    start = source.index(signature)
    if source[max(0, start - len("nonisolated ")):start] == "nonisolated ":
        start -= len("nonisolated ")
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(signature)


signatures = [
    "@objc func dequeueEpisodeHash(", "@objc func retryEpisodeHash(", "@objc func cancelAll()",
    "@objc func resumeIfNeeded()", "@objc func retryQueueStorage()", "private func clientIdentifier()", "@objc func retryPendingCancellations()", "func whenQueuePersisted(",
    "private func makeItem(", "private func updateStatusDetail(", "private func queueCancellation(",
    "private func processPendingCancellation()", "private func checkCurrentAttempt(",
    "private func cancelLocally(", "private func processNext()", "private func apply(",
    "private func schedulePoll(", "private func fail(", "private func handle(error:",
    "private func awaitQueuePersistence()", "private func finishAdmissionFeedback(",
    "private func rejectAdmission(", "private func admissionRejectionMessage(",
    "private func isRemoteCancellation(", "private func localizedServiceUnavailableDetail(",
    "private func validateDownloadedArtifacts(", "private func buildServerAnalysis(",
    "private func validateServerTranscriptBounds(", "private func submitEpisode(", "private func submissionAudioSHA256(", "private func fetchEpisode(", "private func importArtifacts(", "private func verifiedImportAudio(", "private func importAudioIsCurrent(",
    "private func localizedPhase(", "private func serverContractError(", "private func isTransient(",
    "private func podcastURL(", "private func duration(", "private func retryAfter(",
    "private func scheduleRetryWake()", "private func persistQueue()", "private func loadPersistedQueue()",
    "private func removeMetadata(", "private func publishProcessingChange()", "private func postQueueChange()",
]
fixture = (ROOT / "Tools/fixtures/server_transcription_cancellation_harness.swift").read_text()
admission_run = (ROOT / "Tools/fixtures/server_transcription_error_cases.swift").read_text()
start = fixture.index(" static func run(in dir:URL)")
end = fixture.index("\n}\n@main", start)
fixture = fixture[:start] + admission_run + fixture[end:]
fixture = fixture.replace("// PRODUCTION_TYPES", source.split("@MainActor\n@objc class ServerTranscriptionManager", 1)[0])
fixture = fixture.replace("// PRODUCTION_METHODS", "\n".join(("@discardableResult\n" if signature == "private func schedulePoll(" else "") + declaration(signature) for signature in signatures))
# Fail the actual atomic snapshot-write boundary, while retaining all production
# state/continuation/cleanup methods around it.
fixture = fixture.replace("try data.write(to: fileURL, options: .atomic)", "try SnapshotWriter.shared.write(data, to: fileURL)")
with tempfile.TemporaryDirectory(prefix="server-cancellation-test-") as directory:
    swift = Path(directory) / "main.swift"
    executable = Path(directory) / "run"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
