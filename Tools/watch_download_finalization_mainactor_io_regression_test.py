#!/usr/bin/env python3
"""Pins Watch download installation and stale-file cleanup off MainActor."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
DE = (ROOT / "InstacastWatch" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "InstacastWatch" / "en.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require(
    "private struct WatchDownloadTransportSnapshot: Sendable" in SOURCE
    and "private enum WatchFinishedDownloadPreparationResult: Sendable" in SOURCE,
    "Detached finalization may receive only an immutable response snapshot and return a Sendable result.",
)

prepare = body("private nonisolated static func prepareFinishedDownloadFile(")
require(
    "Task.detached(priority: .utility)" in prepare
    and "attributesOfItem" in prepare
    and "removeItem" in prepare
    and "moveItem" in prepare,
    "Staged-file stat, destination replacement, and move must execute in utility work off MainActor.",
)
require(
    "URLSessionDownloadTask" not in prepare
    and "HTTPURLResponse" not in prepare,
    "The detached worker must consume primitive transport metadata, never actor-owned URLSession objects.",
)
storage_error_key = "Download-Datei konnte auf der Watch nicht gespeichert werden."
require(
    "NSLocalizedString(" in prepare
    and f'"{storage_error_key}"' in prepare
    and storage_error_key in DE
    and storage_error_key in EN
    and "The Watch downloads directory is unavailable." not in prepare
    and "The Watch application-support directory is unavailable." not in prepare,
    "Rare directory failures must still show one localized, user-facing storage error.",
)

attributes = body("private nonisolated static func downloadedFileAttributes(")
require(
    "AVURLAsset" in attributes
    and "await asset.load(.isPlayable)" in attributes
    and "FileManager" not in attributes,
    "The off-main preparation result must carry file size so async AVAsset validation never stats "
    "the same file again on MainActor.",
)

discard = body("private func discardFinishedDownload(")
remove_files = body("private nonisolated static func removeFinishedDownloadFiles(")
require(
    "async" in SOURCE[SOURCE.find("private func discardFinishedDownload("):SOURCE.find("private func discardFinishedDownload(") + 240]
    and "await Self.removeFinishedDownloadFiles" in discard
    and "FileManager" not in discard,
    "Stale completion cleanup must suspend for an off-main removal instead of deleting on MainActor.",
)
require(
    "Task.detached(priority: .utility)" in remove_files
    and "removeItem" in remove_files,
    "Audio and chapter-artwork cleanup must execute in detached utility work.",
)

process = body("private func processFinishedDownload(")
require(
    "WatchDownloadTransportSnapshot(" in process
    and "await Self.prepareFinishedDownloadFile(" in process
    and "await Self.downloadedFileAttributes(" in process,
    "Completion must snapshot transport primitives and await the two off-main validation phases.",
)
for forbidden in ("FileManager", "WatchStorageManager.shared.localFileURL"):
    require(
        forbidden not in process,
        f"Download completion still performs synchronous MainActor filesystem work: {forbidden}",
    )
require(
    process.count("isCurrentDownload(downloadTask, hash: hash)") >= 4
    and process.find("await Self.prepareFinishedDownloadFile(")
    < process.find("isCurrentDownload(downloadTask, hash: hash)", process.find("await Self.prepareFinishedDownloadFile(")),
    "The URLSession task must still own the episode after every reentrant file/media phase before commit.",
)

print("Watch download-finalization MainActor I/O regression checks passed")
