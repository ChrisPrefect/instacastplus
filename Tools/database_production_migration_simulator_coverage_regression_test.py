#!/usr/bin/env python3
"""Pins a black-box simulator proof through the production migration entry point."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / "Tools" / "database_production_migration_simulator_test.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(PROOF.exists(), "Missing production app-launch migration simulator proof.")
source = PROOF.read_text()

for token, purpose in [
    ("Model4.xcdatamodeld", "compile the last published Core Data model"),
    ("Model7.xcdatamodel", "compile the immediate predecessor model"),
    ("DataStore4.sqlite", "install the last published store generation"),
    ("DataStore5.sqlite", "install the immediate predecessor store generation"),
    ("DataStore6.sqlite", "verify the current store generation"),
    ("simctl", "exercise the real installed simulator application"),
    ("get_app_container", "place and inspect data in the real app container"),
    ("launch", "enter migration through InstacastAppDelegate"),
    ("migration-in-progress", "wait for the durable migration protocol to commit"),
    ("ZEPISODE", "verify migrated episode rows"),
    ("ZFEED", "verify migrated feed rows"),
    ("ZFEED", "verify the Episode-to-Feed relationship"),
    ("quick_check", "verify SQLite integrity after the production launch"),
]:
    require(token in source, f"Production migration proof must {purpose}.")

require("booted" in source.lower(), "The proof must target an explicitly booted iPhone simulator.")
require('for suffix in ["", "-wal", "-shm"]' in source and "walSize > 32" in source,
        "Both predecessor fixtures must include WAL-backed data, not only a checkpointed main file.")
require("unlink" not in source and "remove(DataStore4" not in source,
        "The test harness must not fake production cleanup of the legacy source store.")

print("Production migration simulator coverage regression checks passed")
