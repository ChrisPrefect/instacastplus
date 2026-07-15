#!/usr/bin/env python3
"""Pins restartable, generation-safe low-priority iCloud task ownership."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


options_changed = method_body("@objc func syncOptionsChanged()")
require(
    "if !anySyncEnabled" in options_changed
    and "cancelLowPrioritySyncTask()" in options_changed
    and options_changed.find("cancelLowPrioritySyncTask()")
        < options_changed.find("persistFinalDeviceRecordUpdateIntent()"),
    "Turning the last category off must synchronously cancel and release the queued automatic sync task, even if persisting its final device intent fails.",
)

perform = method_body("func performLowPrioritySync() async")
first_guard = perform.find("guard anySyncEnabled")
cleanup = perform.find("defer")
require(
    cleanup != -1 and first_guard != -1 and cleanup < first_guard,
    "Low-priority task ownership cleanup must be installed before every early return.",
)
require(
    "if !Task.isCancelled" in perform[cleanup:first_guard]
    and "lowPrioritySyncTask = nil" in perform[cleanup:first_guard],
    "A cancelled stale task must not clear a newer task, while the current task always releases its slot.",
)
require(
    perform.count("lowPrioritySyncTask = nil") == 1,
    "Every low-priority exit must share one lifecycle cleanup instead of missing individual guard returns.",
)
require(
    "shouldScheduleContinuation" in perform[cleanup:first_guard]
    and "scheduleLowPrioritySync()" in perform[cleanup:first_guard],
    "Pending work must schedule its continuation only after the current task releases ownership.",
)


class Slot:
    def __init__(self):
        self.owner = None

    def schedule(self, owner):
        if self.owner is None:
            self.owner = owner
            return True
        return False

    def cancel(self):
        old = self.owner
        self.owner = None
        return old

    def finish(self, owner, cancelled):
        if not cancelled and self.owner == owner:
            self.owner = None


slot = Slot()
require(slot.schedule("old"), "Initial automatic sync must be schedulable.")
cancelled_owner = slot.cancel()
require(slot.schedule("new"), "Re-enabling sync must immediately schedule a new automatic cycle.")
slot.finish(cancelled_owner, cancelled=True)
require(slot.owner == "new", "The cancelled old task must not erase the newly scheduled task.")
slot.finish("new", cancelled=False)
require(slot.owner is None, "A normally completed current task must release the slot.")

print("iCloud low-priority task lifecycle regression checks passed")
