#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


account_change = method_body(REMOTE, "func handleAccountChange")
sign_out = account_change.split("case .signOut:", 1)[1].split("case .switchAccounts:", 1)[0]
scope = sign_out.find("ensurePendingLocalOutboxScope()")
close_identity = sign_out.find("setICloudAccountSignedOut(true)")
reset = sign_out.find("resetForICloudAccountTransition")
require(-1 not in (scope, close_identity, reset) and scope < close_identity < reset,
        "A direct CK sign-out must durably arm the offline outbox scope before closing the verified identity gate.")

capture = method_body(LOCAL, "nonisolated static func localOutboxCaptureAccountRecordName")
require("localOutboxHasVerifiedAccountKey" in capture
        and "localOutboxPendingScopeKey" in capture,
        "After sign-out, negative episode/subscription edits must be journaled into the pending account scope.")

print("iCloud direct sign-out capture regression checks passed")
