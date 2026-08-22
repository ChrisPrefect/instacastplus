#!/usr/bin/env python3
"""Regression checks for app-owned warnings emitted during an attached launch."""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LLAMA_XCFRAMEWORK = ROOT / "Frameworks" / "llama.xcframework"
APP_DELEGATE = ROOT / "Classes" / "InstacastAppDelegate.m"
WATCH_MANAGER = ROOT / "Classes" / "AppleWatchSyncManager.m"


def method_body(source: str, signature: str) -> str:
    implementation = f"{signature}\n{{"
    start = source.find(implementation)
    if start >= 0:
        opening = start + len(implementation) - 1
    else:
        start = source.index(signature)
        opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


failures: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


with (LLAMA_XCFRAMEWORK / "Info.plist").open("rb") as handle:
    xcframework_info = plistlib.load(handle)

for library in xcframework_info["AvailableLibraries"]:
    debug_symbols_path = library.get("DebugSymbolsPath")
    if not debug_symbols_path:
        continue
    symbols_directory = LLAMA_XCFRAMEWORK / library["LibraryIdentifier"] / debug_symbols_path
    for dsym in symbols_directory.glob("*.dSYM"):
        result = subprocess.run(
            ["xcrun", "dwarfdump", "--debug-info", str(dsym)],
            check=True,
            capture_output=True,
            text=True,
        )
        require(
            "DW_TAG_compile_unit" in result.stdout,
            f"{library['LibraryIdentifier']} advertises an empty llama dSYM; LLDB will warn and search for unusable symbols.",
        )


app_delegate_source = APP_DELEGATE.read_text()
registration = method_body(app_delegate_source, "- (void)_registerTranscriptionBackgroundTasks")
require(
    "registerForTaskWithIdentifier:ICTranscriptionContinuedTaskIdentifier" in registration
    and "registerForTaskWithIdentifier:ICTranscriptionContinuedTaskIdentifierPattern" not in registration,
    "The launch path still submits the known-rejected BGContinuedProcessing wildcard registration before its concrete identifier.",
)


watch_source = WATCH_MANAGER.read_text()
watch_start = method_body(watch_source, "- (void)_finishStartingAfterWatchStateRepair")
watch_refresh = method_body(watch_source, "- (void)_refreshSessionStateAndNotify:(BOOL)notify")
require(
    "session.activationState == WCSessionActivationStateActivated" in watch_start,
    "Watch startup still refreshes WCSession properties immediately after activateSession instead of waiting for activation.",
)
activation_guard = watch_refresh.find("session.activationState == WCSessionActivationStateActivated")
paired_read = watch_refresh.find("session.paired")
installed_read = watch_refresh.find("session.watchAppInstalled")
reachable_read = watch_refresh.find("session.reachable")
require(
    activation_guard >= 0
    and all(index > activation_guard for index in (paired_read, installed_read, reachable_read)),
    "WCSession pairing, installation, or reachability is still read before activation completes.",
)


if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)

print("Debug-launch warning regression checks passed.")
