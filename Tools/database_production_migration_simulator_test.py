#!/usr/bin/env python3
"""Black-box the production DataStore migration in a booted iPhone simulator.

The selected simulator's existing InstacastPlus data is replaced. Set
INSTACAST_ALLOW_SIMULATOR_DATA_RESET=1 explicitly after choosing a disposable
simulator. INSTACAST_SIMULATOR_UDID and INSTACAST_APP_PATH are optional.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.iteconomy.instacastplus"
PUBLISHED_MODEL = ROOT / "Resources" / "Models" / "Model4.xcdatamodeld" / "Model.xcdatamodel"
PREDECESSOR_MODEL = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model7.xcdatamodel"

FIXTURE_SWIFT = r'''
import CoreData
import Foundation
import SQLite3

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(description: message) }
}

func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let database else {
        throw FixtureFailure(description: "Could not open fixture SQLite store")
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
        sqlite3_free(message)
        throw FixtureFailure(description: detail)
    }
}

let environment = ProcessInfo.processInfo.environment
guard let modelPath = environment["FIXTURE_MODEL"],
      let sourcePath = environment["FIXTURE_SOURCE"],
      let outputPath = environment["FIXTURE_OUTPUT"],
      let label = environment["FIXTURE_LABEL"] else {
    fatalError("Missing fixture environment")
}
guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: modelPath)) else {
    throw FixtureFailure(description: "Could not load fixture model")
}
for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }

let sourceURL = URL(fileURLWithPath: sourcePath)
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: sourceURL,
    options: [
        NSPersistentHistoryTrackingKey: false,
        NSSQLitePragmasOption: ["journal_mode": "WAL", "wal_autocheckpoint": "0"],
    ]
)
try execute("PRAGMA wal_checkpoint(TRUNCATE)", at: sourceURL)

let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
try context.performAndWait {
    guard let feedEntity = model.entitiesByName["Feed"],
          let episodeEntity = model.entitiesByName["Episode"] else {
        throw FixtureFailure(description: "Fixture model lacks Feed or Episode")
    }
    let feed = NSManagedObject(entity: feedEntity, insertInto: context)
    feed.setValue("production-migration-feed-\(label)", forKey: "uid")
    feed.setValue("Production Migration Podcast \(label)", forKey: "title")
    feed.setValue("https://example.test/production-migration-\(label).xml", forKey: "sourceURL_")
    feed.setValue(true, forKey: "subscribed")
    feed.setValue(7, forKey: "rank")

    let episode = NSManagedObject(entity: episodeEntity, insertInto: context)
    episode.setValue("production-migration-episode-uid-\(label)", forKey: "uid")
    episode.setValue("production-migration-guid-\(label)", forKey: "guid")
    episode.setValue("production-migration-episode-\(label)", forKey: "objectHash")
    episode.setValue("Production Migration Episode \(label)", forKey: "title")
    episode.setValue(3_601, forKey: "duration")
    episode.setValue(911, forKey: "position")
    episode.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "pubDate")
    episode.setValue(feed, forKey: "feed")
    try context.save()
}

let walURL = URL(fileURLWithPath: sourceURL.path + "-wal")
let walSize = (try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value ?? 0
try require(walSize > 32, "Fixture episode was not retained in WAL")

let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
let destination = outputURL.appendingPathComponent(sourceURL.lastPathComponent)
for suffix in ["", "-wal", "-shm"] {
    let source = URL(fileURLWithPath: sourceURL.path + suffix)
    if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(
            at: source,
            to: URL(fileURLWithPath: destination.path + suffix)
        )
    }
}
print("Created \(destination.lastPathComponent) with \(walSize) WAL bytes")
'''


def run(
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"Command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}"
        )
    return result


def booted_iphone_udid() -> str:
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"]).stdout)
    requested = os.environ.get("INSTACAST_SIMULATOR_UDID")
    matches: list[tuple[str, str]] = []
    for runtime, runtime_devices in devices.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in runtime_devices:
            if device.get("state") != "Booted" or not device.get("isAvailable", True):
                continue
            if requested and device.get("udid") != requested:
                continue
            matches.append((device["udid"], device.get("name", "iPhone Simulator")))
    if not matches:
        qualifier = f" {requested}" if requested else ""
        raise AssertionError(f"No booted iPhone simulator{qualifier}; boot the intended test device first.")
    if len(matches) > 1 and not requested:
        choices = ", ".join(f"{name} ({udid})" for udid, name in matches)
        raise AssertionError(
            "More than one iPhone simulator is booted; set INSTACAST_SIMULATOR_UDID. " + choices
        )
    return matches[0][0]


def compile_model(source: Path, destination: Path, sdk_path: str) -> None:
    result = run([
        "xcrun",
        "momc",
        "--sdkroot",
        sdk_path,
        str(source),
        str(destination),
    ])
    if result.stdout.strip():
        print(result.stdout.strip())


def create_fixture(
    *,
    model: Path,
    source_name: str,
    label: str,
    directory: Path,
) -> Path:
    working = directory / f"working-{label}"
    output = directory / f"fixture-{label}"
    working.mkdir()
    output.mkdir()
    environment = os.environ.copy()
    environment.update({
        "FIXTURE_MODEL": str(model),
        "FIXTURE_SOURCE": str(working / source_name),
        "FIXTURE_OUTPUT": str(output),
        "FIXTURE_LABEL": label,
    })
    result = run(["xcrun", "swift", "-e", FIXTURE_SWIFT], environment=environment)
    if result.stdout.strip():
        print(result.stdout.strip())
    source_store = output / source_name
    if not source_store.exists() or not Path(str(source_store) + "-wal").exists():
        raise AssertionError(f"Incomplete fixture for {label}")
    return source_store


def build_app(udid: str, derived_data: Path) -> Path:
    supplied = os.environ.get("INSTACAST_APP_PATH")
    if supplied:
        app = Path(supplied).resolve()
        if not app.is_dir():
            raise AssertionError(f"INSTACAST_APP_PATH is not an app bundle: {app}")
        return app
    result = run([
        "xcodebuild",
        "-quiet",
        "-project",
        "Instacast.xcodeproj",
        "-scheme",
        "Instacast",
        "-destination",
        f"id={udid}",
        "-derivedDataPath",
        str(derived_data),
        "build",
    ])
    if result.stdout.strip():
        print(result.stdout.strip())
    candidates = list((derived_data / "Build" / "Products").glob("*-iphonesimulator/Instacast.app"))
    if len(candidates) != 1:
        raise AssertionError(f"Could not locate exactly one built Instacast.app: {candidates}")
    return candidates[0]


def app_is_installed(udid: str) -> bool:
    return run(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        check=False,
    ).returncode == 0


def install_clean_app(udid: str, app: Path) -> Path:
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)
    run(["xcrun", "simctl", "uninstall", udid, BUNDLE_ID], check=False)
    run(["xcrun", "simctl", "install", udid, str(app)])
    container = run([
        "xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"
    ]).stdout.strip()
    if not container:
        raise AssertionError("Installed app has no simulator data container")
    return Path(container)


def copy_store_triplet(source_store: Path, data_directory: Path) -> None:
    data_directory.mkdir(parents=True, exist_ok=True)
    for suffix in ["", "-wal", "-shm"]:
        source = Path(str(source_store) + suffix)
        if source.exists():
            shutil.copy2(source, data_directory / (source_store.name + suffix))


def recent_database_logs(udid: str) -> str:
    return run([
        "xcrun",
        "simctl",
        "spawn",
        udid,
        "log",
        "show",
        "--style",
        "compact",
        "--last",
        "3m",
        "--predicate",
        f'process == "Instacast" OR process == "InstacastPlus"',
    ], check=False).stdout[-12_000:]


def wait_for_production_commit(
    *,
    udid: str,
    data_directory: Path,
    source_store: Path,
    timeout: float = 90.0,
) -> Path:
    target = data_directory / "DataStore6.sqlite"
    marker = data_directory / "DataStore6.sqlite.migration-in-progress"
    run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if target.exists() and not marker.exists() and not (data_directory / source_store.name).exists():
            run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)
            return target
        time.sleep(0.25)
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)
    state = (
        f"target={target.exists()} marker={marker.exists()} "
        f"source={data_directory.joinpath(source_store.name).exists()}"
    )
    raise AssertionError(
        f"Production migration did not commit within {timeout:.0f}s ({state}).\n"
        + recent_database_logs(udid)
    )


def validate_migrated_store(target: Path, label: str) -> None:
    database = sqlite3.connect(target)
    try:
        quick_check = database.execute("PRAGMA quick_check").fetchone()
        if quick_check != ("ok",):
            raise AssertionError(f"{label} target failed SQLite quick_check: {quick_check}")
        feed_count = database.execute(
            "SELECT COUNT(*) FROM ZFEED WHERE ZUID = ?",
            (f"production-migration-feed-{label}",),
        ).fetchone()[0]
        episode_count = database.execute(
            "SELECT COUNT(*) FROM ZEPISODE WHERE ZOBJECTHASH = ?",
            (f"production-migration-episode-{label}",),
        ).fetchone()[0]
        relationship_count = database.execute(
            "SELECT COUNT(*) FROM ZEPISODE e "
            "JOIN ZFEED f ON e.ZFEED = f.Z_PK "
            "WHERE e.ZOBJECTHASH = ? AND f.ZUID = ?",
            (
                f"production-migration-episode-{label}",
                f"production-migration-feed-{label}",
            ),
        ).fetchone()[0]
    finally:
        database.close()
    if (feed_count, episode_count, relationship_count) != (1, 1, 1):
        raise AssertionError(
            f"{label} migrated rows/relationship changed: "
            f"feed={feed_count}, episode={episode_count}, relationship={relationship_count}"
        )


def main() -> None:
    if os.environ.get("INSTACAST_ALLOW_SIMULATOR_DATA_RESET") != "1":
        raise AssertionError(
            "This proof replaces InstacastPlus data on the selected simulator. "
            "Use a disposable booted iPhone simulator and set "
            "INSTACAST_ALLOW_SIMULATOR_DATA_RESET=1."
        )

    udid = booted_iphone_udid()
    with tempfile.TemporaryDirectory(prefix="instacast-production-migration-") as temporary_path:
        temporary = Path(temporary_path)
        sdk_path = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
        published_mom = temporary / "PublishedModel4.mom"
        predecessor_mom = temporary / "PredecessorModel7.mom"
        compile_model(PUBLISHED_MODEL, published_mom, sdk_path)
        compile_model(PREDECESSOR_MODEL, predecessor_mom, sdk_path)
        fixtures = [
            create_fixture(
                model=published_mom,
                source_name="DataStore4.sqlite",
                label="published-model4",
                directory=temporary,
            ),
            create_fixture(
                model=predecessor_mom,
                source_name="DataStore5.sqlite",
                label="predecessor-model7",
                directory=temporary,
            ),
        ]
        app = build_app(udid, temporary / "DerivedData")
        if app_is_installed(udid):
            print(f"Replacing existing {BUNDLE_ID} data on simulator {udid}")
        for source_store in fixtures:
            container = install_clean_app(udid, app)
            data_directory = container / "Documents" / "Data"
            copy_store_triplet(source_store, data_directory)
            target = wait_for_production_commit(
                udid=udid,
                data_directory=data_directory,
                source_store=source_store,
            )
            validate_migrated_store(target, source_store.parent.name.removeprefix("fixture-"))
            print(f"{source_store.name} production launch migration passed")

    print("Production app-launch database migration simulator proof passed")


if __name__ == "__main__":
    main()
