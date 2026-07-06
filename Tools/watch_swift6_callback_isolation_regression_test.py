#!/usr/bin/env python3
"""Pins the Swift-6 callback-isolation crash fixes on the watch.

Background (symbolicated .ips, 05.07.2026, watchOS 26.5, SWIFT_VERSION = 6.0):
Closures formed inside @MainActor-isolated code inherit MainActor isolation.
Several ObjC SDK callbacks are NOT annotated NS_SWIFT_SENDABLE, so such a
closure keeps its inferred isolation, and when the framework invokes it on its
own queue the Swift runtime traps with EXC_BREAKPOINT (dispatch_assert_queue):

- WCSession.sendMessage errorHandler → invoked on WatchConnectivity's
  NSOperationQueue whenever a reliable send FAILS. Crashed the whole app
  ("crasht sofort beim Play" — play sends diagnostics first; 11 identical .ips).
- MPRemoteCommandCenter addTarget handlers → invoked on MediaPlayer's
  accessQueue ~2 s after playback starts WHEN HEADPHONES ARE CONNECTED
  (MediaRemote fires the command registration). 2 identical .ips, exact
  symbolication against the installed binary UUID 3327EE80.
- MPMediaItemArtwork requestHandler → invoked by the system off-main when the
  now-playing artwork is rendered.
- AVAudioSession.activate completionHandler → invoked on AVFAudio's queue.

Every closure handed to these APIs must be @Sendable (making it nonisolated)
and hop to the MainActor explicitly for any actor state.

Also pinned here: a FAILED long-form session activation (no Bluetooth
headphones / dismissed route picker) must NOT delete the downloaded file. The
old path called markEpisodePlaybackFailed which removed the file and forced a
re-download (customer repro 05.07.).
"""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


player = read("InstacastWatch/WatchPlayerController.swift")
connectivity = read("InstacastWatch/WatchConnectivityController.swift")

# 1. Every MPRemoteCommandCenter handler must be @Sendable.
remote_commands = function_body(player, "private func configureRemoteCommands(")
add_target_count = remote_commands.count(".addTarget")
sendable_add_target_count = len(re.findall(r"\.addTarget\s*\{\s*@Sendable", remote_commands))
require(
    add_target_count >= 6 and add_target_count == sendable_add_target_count,
    "Every MPRemoteCommandCenter addTarget handler must be @Sendable — MediaPlayer invokes "
    "them on its accessQueue; a MainActor-inferred handler traps (EXC_BREAKPOINT) ~2 s after "
    "playback starts with connected headphones.",
)

# 2. The artwork request handler must be @Sendable.
require(
    re.search(r"MPMediaItemArtwork\(boundsSize:[^)]*\)\s*\{\s*@Sendable", player) is not None,
    "The MPMediaItemArtwork requestHandler must be @Sendable — the system calls it off-main.",
)

# 3. The AVAudioSession activation completion must be @Sendable.
require(
    re.search(r"session\.activate\(options:[^)]*\)\s*\{\s*@Sendable", player) is not None,
    "The AVAudioSession.activate completion must be @Sendable — AVFAudio calls it on its own queue.",
)

# 4. The reliable-send errorHandler must be @Sendable.
require(
    re.search(r"errorHandler:\s*\{\s*@Sendable", connectivity) is not None,
    "The WCSession.sendMessage errorHandler must be @Sendable — WatchConnectivity invokes it "
    "on its NSOperationQueue whenever a reliable send fails; without @Sendable every failed "
    "send crashed the app.",
)

# 5. A failed session activation must not destroy the download.
play_body = function_body(player, "func play(_ episode: WatchEpisode) async -> Bool")
activation_catch = play_body.split("activateLongFormAudioSession()", 1)[1]
activation_catch = activation_catch.split("guard generation == playbackGeneration", 1)[0]
activation_catch = "\n".join(
    line for line in activation_catch.splitlines() if not line.strip().startswith("//")
)
require(
    "markEpisodePlaybackFailed" not in activation_catch
    and "removeLocalFile" not in activation_catch,
    "A failed long-form session activation (no headphones / dismissed route picker) must NOT "
    "mark the episode failed or delete the downloaded file — it says nothing about the file.",
)

print("watch swift6 callback isolation regression test passed")
