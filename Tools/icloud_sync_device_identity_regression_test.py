#!/usr/bin/env python3
"""Pins a per-installation iCloud device identity across clone/reinstall races.

These checks are deliberately red until production stops treating a cloneable
UserDefaults value as the installation identity.  The small model makes every
interleaving deterministic; the source assertions bind that contract to the real
manager and its nonisolated CKSyncEngine callback path.
"""

from __future__ import annotations

import threading
import unittest
from dataclasses import dataclass, replace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
SOURCE = "\n".join((MANAGER, ENGINE, METADATA))


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    if brace == -1:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


class KeychainFailure(RuntimeError):
    pass


class MarkerCommitFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class KeychainIdentityState:
    current_device_id: str
    marker_commit_pending: bool
    pending_cleanup_device_ids: tuple[str, ...]


class IdentityStoreModel:
    """Reference transaction: marker and ThisDeviceOnly keychain must agree."""

    def __init__(self, *, keychain_id=None, keychain_state=None,
                 marker_id=None, legacy_default_id=None):
        self.keychain_state = keychain_state or (
            KeychainIdentityState(keychain_id, False, ())
            if keychain_id is not None else None
        )
        self.marker_id = marker_id
        self.legacy_default_id = legacy_default_id
        self.keychain_status = (
            "success" if self.keychain_state is not None else "not-found"
        )
        self.fail_next_marker_commit = False
        self.generated_count = 0
        self._lock = threading.Lock()

    def _new_id(self) -> str:
        self.generated_count += 1
        return f"fresh-{self.generated_count}-{id(self)}"

    def resolve(self) -> str:
        with self._lock:
            if self.keychain_status not in ("success", "not-found"):
                raise KeychainFailure(self.keychain_status)

            state = self.keychain_state
            if state is not None and state.marker_commit_pending:
                # Resume the interrupted marker commit with the already durable UUID.
                if self.fail_next_marker_commit:
                    self.fail_next_marker_commit = False
                    raise MarkerCommitFailure("atomic marker write aborted")
                self.marker_id = state.current_device_id
                self.keychain_state = replace(state, marker_commit_pending=False)
                return state.current_device_id

            if (state is not None
                    and self.marker_id == state.current_device_id):
                return state.current_device_id

            # Missing/mismatched marker means a fresh installation. A copied marker or
            # legacy default identifies the still-active Quick Start source, not a stale
            # record that the destination may delete. Only a surviving ThisDeviceOnly
            # state proves that this physical device previously owned an ID.
            cleanup_ids = set(state.pending_cleanup_device_ids if state else ())
            if state is not None:
                cleanup_ids.add(state.current_device_id)
            new_id = self._new_id()
            self.keychain_state = KeychainIdentityState(
                new_id,
                True,
                tuple(sorted(cleanup_ids)),
            )
            self.keychain_status = "success"
            if self.fail_next_marker_commit:
                self.fail_next_marker_commit = False
                raise MarkerCommitFailure("atomic marker write aborted")
            self.marker_id = new_id
            self.keychain_state = replace(
                self.keychain_state,
                marker_commit_pending=False,
            )
            return new_id


class DeviceIdentityRegressionTests(unittest.TestCase):
    def test_quick_start_clone_ignores_same_legacy_default(self) -> None:
        clone_a = IdentityStoreModel(
            keychain_id=None,
            marker_id="cloned-old-id",
            legacy_default_id="cloned-old-id",
        )
        clone_b = IdentityStoreModel(
            keychain_id=None,
            marker_id="cloned-old-id",
            legacy_default_id="cloned-old-id",
        )
        self.assertNotEqual(clone_a.resolve(), clone_b.resolve())
        self.assertEqual(clone_a.keychain_state.pending_cleanup_device_ids, ())
        self.assertEqual(clone_b.keychain_state.pending_cleanup_device_ids, ())

        marker_only_clone = IdentityStoreModel(
            keychain_id=None,
            marker_id="cloned-marker-id",
            legacy_default_id=None,
        )
        self.assertNotEqual(marker_only_clone.resolve(), "cloned-marker-id")
        self.assertEqual(
            marker_only_clone.keychain_state.pending_cleanup_device_ids,
            (),
        )

        main_device_id = method_body(MANAGER, "var deviceID: String")
        callback_device_id = method_body(
            ENGINE, "nonisolated static func deviceIDForSyncEngineCallback()"
        )
        for body in (main_device_id, callback_device_id):
            self.assertNotIn(
                "string(forKey: Self.deviceIDKey)",
                body,
                "Quick Start clones UserDefaults: neither production device-ID path may "
                "accept the cloned legacy value as this installation's identity.",
            )
        self.assertTrue(
            "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" in SOURCE,
            "The device-ID keychain item must be ThisDeviceOnly so Quick Start cannot copy it.",
        )

    def test_parallel_first_resolution_publishes_exactly_one_id(self) -> None:
        store = IdentityStoreModel()
        start = threading.Barrier(24)
        results: list[str] = []
        failures: list[BaseException] = []

        def resolve() -> None:
            try:
                start.wait(timeout=2)
                results.append(store.resolve())
            except BaseException as error:  # pragma: no cover - diagnostic capture
                failures.append(error)

        threads = [threading.Thread(target=resolve) for _ in range(24)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertFalse(failures)
        self.assertEqual(len(set(results)), 1)
        self.assertEqual(store.generated_count, 1)

        main_device_id = method_body(MANAGER, "var deviceID: String")
        callback_device_id = method_body(
            ENGINE, "nonisolated static func deviceIDForSyncEngineCallback()"
        )
        self.assertIn(
            "resolveInstallationDeviceID",
            main_device_id,
            "MainActor and CKSyncEngine currently have separate UUID creation races; "
            "both must call one process-wide installation-ID resolver.",
        )
        self.assertIn("resolveInstallationDeviceID", callback_device_id)
        resolver = method_body(SOURCE, "func resolveInstallationDeviceID")
        self.assertRegex(
            SOURCE,
            r"static\s+let\s+installationDeviceIdentityLock\s*=\s*NSLock\(\)",
            "The resolver lock must be one process-wide static instance.",
        )
        self.assertIn("installationDeviceIdentityLock.lock()", resolver)
        lock_index = resolver.find("lock()")
        lookup_index = resolver.find("readInstallationDeviceIdentityStateFromKeychain")
        uuid_index = resolver.find("UUID()")
        self.assertTrue(
            -1 not in (lock_index, lookup_index, uuid_index)
            and lock_index < lookup_index < uuid_index,
            "One shared lock must cover keychain read, UUID creation, both commits, and publish.",
        )
        self.assertIn("defer {", resolver)
        self.assertIn("installationDeviceIdentityLock.unlock()", resolver)

    def test_reinstall_rotates_surviving_keychain_and_aborted_marker_never_publishes(self) -> None:
        reinstalled = IdentityStoreModel(
            keychain_id="old-install",
            marker_id=None,
            legacy_default_id=None,
        )
        self.assertNotEqual(reinstalled.resolve(), "old-install")
        self.assertEqual(
            reinstalled.keychain_state.pending_cleanup_device_ids,
            ("old-install",),
        )

        interrupted = IdentityStoreModel()
        interrupted.fail_next_marker_commit = True
        published: list[str] = []
        with self.assertRaises(MarkerCommitFailure):
            published.append(interrupted.resolve())
        self.assertEqual(published, [])
        self.assertTrue(interrupted.keychain_state.marker_commit_pending)
        pending_id = interrupted.keychain_state.current_device_id
        relaunched = IdentityStoreModel(
            keychain_state=interrupted.keychain_state,
            marker_id=interrupted.marker_id,
        )
        committed = relaunched.resolve()
        self.assertEqual(committed, pending_id)
        self.assertEqual(relaunched.resolve(), committed)
        self.assertEqual(interrupted.generated_count + relaunched.generated_count, 1)

        self.assertTrue(
            "installationDeviceMarker" in SOURCE,
            "A keychain item survives uninstall; production needs an app-container "
            "installation marker to rotate it on a genuine reinstall.",
        )
        resolver = method_body(SOURCE, "func resolveInstallationDeviceID")
        pending_resume = resolver.find("markerCommitPending")
        uuid_creation = resolver.find("UUID()")
        self.assertTrue(
            -1 not in (pending_resume, uuid_creation) and pending_resume < uuid_creation,
            "A pending marker transaction must resume its existing ID before UUID creation.",
        )
        pending_resume_branch = resolver[pending_resume:uuid_creation]
        self.assertIn("writeInstallationDeviceMarker", pending_resume_branch)
        self.assertIn(
            "writeInstallationDeviceIdentityStateToKeychain",
            pending_resume_branch,
        )
        fresh_transaction = resolver[uuid_creation:]
        keychain_prepare = fresh_transaction.find(
            "writeInstallationDeviceIdentityStateToKeychain"
        )
        marker_commit = fresh_transaction.find("writeInstallationDeviceMarker")
        keychain_finalize = fresh_transaction.find(
            "writeInstallationDeviceIdentityStateToKeychain",
            keychain_prepare + 1,
        )
        publish = fresh_transaction.rfind("return")
        self.assertTrue(
            -1 not in (keychain_prepare, marker_commit, keychain_finalize, publish)
            and keychain_prepare < marker_commit < keychain_finalize < publish,
            "Persist markerCommitPending first, atomically commit the marker, finalize the "
            "same keychain ID, and only then publish it.",
        )
        self.assertNotIn(
            "try?",
            resolver,
            "An aborted marker commit must be a hard transaction failure, not a published ID.",
        )
        marker_writer = method_body(SOURCE, "func writeInstallationDeviceMarker")
        self.assertIn(".atomic", marker_writer)
        identity_state = method_body(SOURCE, "struct InstallationDeviceIdentityState")
        for field in (
            "currentDeviceID", "markerCommitPending", "pendingCleanupDeviceIDs",
            "cleanupCompletedAccountRecordNames",
        ):
            self.assertIn(field, identity_state)
        self.assertIn(
            "decodeIfPresent",
            identity_state,
            "Identity state written by an earlier build must decode with an empty "
            "per-account cleanup ledger.",
        )
        self.assertIn("deviceIDKey", resolver)
        self.assertIn("readInstallationDeviceMarker", resolver)
        self.assertNotIn(
            "pendingCleanupDeviceIDs.insert(marker)",
            resolver,
            "The Quick Start destination must not delete the active source device's record.",
        )
        self.assertNotIn(
            "pendingCleanupDeviceIDs.insert(legacyDeviceID)",
            resolver,
            "A cloned legacy default is not proof that the destination owns that record.",
        )
        self.assertIn("pendingCleanupDeviceIDs", resolver)
        self.assertNotIn("persistPendingDeviceControlDeleteIntent", resolver)
        self.assertNotIn("deleteRecord", resolver)

    def test_unexpected_keychain_osstatus_is_hard_error_without_fallback(self) -> None:
        store = IdentityStoreModel(legacy_default_id="tempting-fallback")
        store.keychain_status = "interaction-not-allowed"
        with self.assertRaises(KeychainFailure):
            store.resolve()
        self.assertEqual(store.generated_count, 0)

        self.assertTrue(
            "import Security" in SOURCE,
            "Production does not use Keychain yet, so it cannot distinguish not-found "
            "from a real OSStatus failure.",
        )
        for body in (
            method_body(MANAGER, "var deviceID: String"),
            method_body(ENGINE, "nonisolated static func deviceIDForSyncEngineCallback()"),
        ):
            self.assertNotIn("try?", body)
            self.assertNotIn("try!", body)
            self.assertNotIn("UUID()", body)
            self.assertNotIn("fatalError", body)
            self.assertNotIn("preconditionFailure", body)
        resolver_declaration = SOURCE[
            SOURCE.find("func resolveInstallationDeviceID"):
            SOURCE.find("{", SOURCE.find("func resolveInstallationDeviceID"))
        ]
        self.assertIn("throws", resolver_declaration)
        resolver = method_body(SOURCE, "func resolveInstallationDeviceID")
        reader = method_body(
            SOURCE, "func readInstallationDeviceIdentityStateFromKeychain"
        )
        writer = method_body(
            SOURCE, "func writeInstallationDeviceIdentityStateToKeychain"
        )
        self.assertIn("SecItemCopyMatching", reader)
        self.assertIn("errSecItemNotFound", reader)
        self.assertIn("errSecSuccess", reader)
        self.assertIn("throw", reader)
        self.assertIn("SecItemAdd", writer)
        self.assertIn("SecItemUpdate", writer)
        self.assertIn("errSecSuccess", writer)
        self.assertIn("throw", writer)
        self.assertIn("NSOSStatusErrorDomain", SOURCE)
        self.assertNotIn("string(forKey: Self.deviceIDKey)", resolver)


if __name__ == "__main__":
    unittest.main()
