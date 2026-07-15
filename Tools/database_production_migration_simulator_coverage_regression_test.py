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
    ("same-generation-model7", "exercise Model7 already stored as DataStore6"),
    ("ZACKNOWLEDGEDREVISION", "verify the Model8 receipt schema after launch"),
    ("ZACKNOWLEDGEDOPERATION", "verify both Model8 receipt columns after launch"),
    ("committing-target-model7", "preserve a target-only row from an interrupted committing migration"),
    ("write_committing_marker", "exercise the durable committing-marker path"),
    ("simctl", "exercise the real installed simulator application"),
    ("get_app_container", "place and inspect data in the real app container"),
    ("InstacastPlus.app", "install the actual simulator product bundle"),
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
require('mode=ro' in source and 'uri=True' in source
        and 'sqlite3.connect(store)' not in source
        and 'sqlite3.connect(target)' not in source,
        "Fixture metadata reads and live migration polling must never checkpoint or create a store.")
require('SELECT Z_UUID FROM Z_METADATA' in source,
        "The committing marker must bind the actual Core Data store UUID column.")
require(source.count("assert_wal_sizes(expected_wal_sizes)") >= 2
        and "expected_wal_sizes_before_launch" in source,
        "The committing proof must pin both WAL sizes immediately before production launch.")
require('"entityCounts": entity_counts' in source
        and "fixture_entity_counts(PREDECESSOR_MODEL)" in source,
        "The committing fixture must use the full predecessor-model entity-count payload.")
require("unlink" not in source and "remove(DataStore4" not in source,
        "The test harness must not fake production cleanup of the legacy source store.")

print("Production migration simulator coverage regression checks passed")
