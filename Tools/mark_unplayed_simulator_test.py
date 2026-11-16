#!/usr/bin/env python3
"""Tap the multi-selection Mark as Unplayed action on a disposable iPhone simulator."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import sqlite3
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.iteconomy.instacastplus"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--bypass-simulator-push", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)

    def run(*command, check=True):
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        with (evidence / "commands.log").open("a") as log:
            log.write(shlex.join(command) + "\n" + result.stdout + "\n")
        if check and result.returncode:
            raise RuntimeError(result.stdout[-6000:])
        return result

    devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j").stdout)["devices"]
    runtime, device = next((runtime, item) for runtime, items in devices.items() for item in items if item["udid"] == args.udid)
    assert device["name"] == "Instacast Mark Unplayed" and device["state"] == "Booted", device
    simctl = ("xcrun", "simctl")
    run(*simctl, "uninstall", args.udid, BUNDLE, check=False)
    run(*simctl, "install", args.udid, str(app))
    container = Path(run(*simctl, "get_app_container", args.udid, BUNDLE, "data").stdout.strip())
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").stdout.strip()
    fixtures = ROOT / "Tools/fixtures"
    library = evidence / "MarkUnplayedFixture.dylib"
    run("xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-target", "arm64-apple-ios17.0-simulator",
        "-isysroot", sdk, "-framework", "UIKit", "-framework", "CoreData",
        str(fixtures / "mark_unplayed_seed.m"), "-o", str(library))
    run("codesign", "-s", "-", str(library))

    expected = [[1, 0, 0], [2, 0, 0], [3, 0, 90]]
    expected_temporary = {"mark-unplayed-test-3": 93}
    (evidence / "environment.json").write_text(json.dumps({
        "command": shlex.join([sys.executable, *sys.argv]),
        "runtime": runtime,
        "device": device,
        "app": str(app),
        "appSHA256": hashlib.sha256((app / "InstacastPlus").read_bytes()).hexdigest(),
        "bypassedSimulatorPush": args.bypass_simulator_push,
        "fixture": "Three unconsumed episodes with saved positions of 30, 60 and 90 seconds and temporary positions of 31, 62 and 93.",
        "ui": "Select episodes 1 and 2 in angespielt, tap Als ungespielt markieren; only episode 3 remains. After restart episodes 1 and 2 appear under ungespielt.",
        "expectedStore": expected,
        "expectedTemporaryPositions": expected_temporary,
        "storeColumns": ["fixture episode number", "consumed", "position in seconds"],
    }, indent=2))
    launch_environment = ["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=" + str(library)]
    if args.bypass_simulator_push:
        launch_environment.append("SIMCTL_CHILD_IC_TEST_BYPASS_SIMULATOR_PUSH=1")
    run("/usr/bin/env", *launch_environment,
        *simctl, "launch", f"--stdout={evidence / 'stdout.log'}", f"--stderr={evidence / 'stderr.log'}",
        args.udid, BUNDLE, "-AppleLanguages", "(de)", "-AppleLocale", "de_DE")

    project = evidence / "NativeScroll.xcodeproj"
    project.mkdir(exist_ok=True)
    shutil.copyfile(fixtures / "chapter_scroll_ui_project.pbxproj", project / "project.pbxproj")
    test_source = (fixtures / "mark_unplayed_ui.swift").read_text()
    if args.bypass_simulator_push:
        test_source = test_source.replace("app.launch()", """
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = %s
        app.launchEnvironment["IC_TEST_BYPASS_SIMULATOR_PUSH"] = "1"
        app.launch()
""" % json.dumps(str(library)))
    (evidence / "NativeScrollTests.swift").write_text(test_source)
    ui = run("xcodebuild", "-project", str(project), "-scheme", "NativeScrollTests",
             "-destination", "platform=iOS Simulator,id=" + args.udid,
             "-derivedDataPath", str(evidence / "NativeDerived"), "-parallel-testing-enabled", "NO",
             "-resultBundlePath", str(evidence / "ui.xcresult"), "test", check=False)

    observed = []
    for store in (container / "Documents").rglob("DataStore*.sqlite"):
        with sqlite3.connect(store.as_uri() + "?mode=ro", uri=True) as db:
            if db.execute("SELECT 1 FROM sqlite_master WHERE name = 'ZEPISODE'").fetchone():
                observed = db.execute("""
                    SELECT CAST(substr(ZGUID, -1) AS INTEGER), ZCONSUMED, ZPOSITION
                    FROM ZEPISODE WHERE ZGUID LIKE 'mark-unplayed-test-%' ORDER BY ZGUID
                """).fetchall()
                if observed:
                    break
    observed = [list(row) for row in observed]
    preferences = container / "Library/Preferences" / f"{BUNDLE}.plist"
    defaults = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
    temporary = defaults.get("TemporaryPlaybackPositions", {})
    result = {
        "uiPassed": ui.returncode == 0,
        "expectedStore": expected,
        "observedStore": observed,
        "expectedTemporaryPositions": expected_temporary,
        "observedTemporaryPositions": temporary,
    }
    (evidence / "result.json").write_text(json.dumps(result, indent=2))
    print(ui.stdout[-4500:])
    print(json.dumps(result))
    return 0 if ui.returncode == 0 and observed == expected and temporary == expected_temporary else 1


if __name__ == "__main__":
    sys.exit(main())
