#!/usr/bin/env python3
"""Run the four Shortcuts controls through the real App Intents infrastructure.

Requires a fresh, booted simulator named 'Instacast Shortcuts Controls'. The
fixture probe seeds real Core Data objects and a local WAV, without replacing
production methods. XCTest runs out of process using AppIntentsTesting.
Retains exact commands, fixture, environment, app hashes, logs and xcresult.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import wave
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.iteconomy.instacastplus"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--udid", required=True)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)
for name in ("shortcuts_controls_probe.m", "shortcuts_controls_tests.swift"):
    shutil.copy2(ROOT / "Tools/fixtures" / name, out / name)


def run(command, check=True, stream=False):
    with (out / "commands.log").open("a") as log:
        log.write(shlex.join(command) + "\n")
        log.flush()
        result = subprocess.run(command, stdout=log if stream else subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if not stream:
            log.write(result.stdout)
    if check and result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {out / 'commands.log'}" if stream else result.stdout[-8000:])
    return "" if stream else result.stdout.strip()


devices = json.loads(run(["xcrun", "simctl", "list", "devices", "-j"]))["devices"]
runtime, device = next((r, d) for r, group in devices.items() for d in group if d["udid"] == args.udid)
assert device["name"] == "Instacast Shortcuts Controls" and device["state"] == "Booted"
app = args.app.resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
(out / "environment.json").write_text(json.dumps({
    "command": shlex.join([sys.executable, *sys.argv]), "device": device, "runtime": runtime,
    "app": str(app), "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "appSHA256": hashlib.sha256((app / info["CFBundleExecutable"]).read_bytes()).hexdigest(),
    "expected": "List order and continuation; current episode including paused position; timer seconds; persistent and idempotent automatic timer setting",
    "scope": "Real system intent execution, real models and playback with a generated local WAV; no production method substitution",
}, indent=2) + "\n")

run(["xcrun", "simctl", "terminate", args.udid, BUNDLE], check=False)
run(["xcrun", "simctl", "install", args.udid, str(app)])
container = Path(run(["xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"]))
directory = container / "Documents/ShortcutsControlsProbe"
directory.mkdir(parents=True, exist_ok=True)
for name in ("command.json", "reply.json"):
    (directory / name).unlink(missing_ok=True)
with wave.open(str(directory / "fixture.wav"), "wb") as wav:
    wav.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
    wav.writeframes(b"\0\0" * 8000 * 300)
shutil.copy2(directory / "fixture.wav", out / "fixture.wav")
sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
library = out / "ShortcutsControlsProbe.dylib"
run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", "-target", "arm64-apple-ios17.0-simulator",
     "-isysroot", sdk, "-framework", "UIKit", "-framework", "CoreData",
     str(ROOT / "Tools/fixtures/shortcuts_controls_probe.m"), "-o", str(library)])
run(["codesign", "-s", "-", str(library)])

# A standalone UI-test runner; the production project gains no test-only target.
project = out / "ShortcutsControls.xcodeproj"
project.mkdir(exist_ok=True)
objects = {}


def add(key, isa, **fields):
    objects[key] = dict(isa=isa, **fields)
    return key


add("SOURCE", "PBXFileReference", lastKnownFileType="sourcecode.swift", sourceTree="<absolute>",
    path=str(ROOT / "Tools/fixtures/shortcuts_controls_tests.swift"))
add("SOURCE_BUILD", "PBXBuildFile", fileRef="SOURCE")
add("PRODUCT", "PBXFileReference", explicitFileType="wrapper.cfbundle", sourceTree="BUILT_PRODUCTS_DIR", path="ShortcutsControlsTests.xctest")
add("PRODUCTS", "PBXGroup", children=["PRODUCT"], sourceTree="<group>", name="Products")
add("GROUP", "PBXGroup", children=["SOURCE", "PRODUCTS"], sourceTree="<group>")
add("SOURCES", "PBXSourcesBuildPhase", buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0, files=["SOURCE_BUILD"])
settings = dict(SDKROOT="iphoneos", IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="6.0",
                PRODUCT_NAME="ShortcutsControlsTests", PRODUCT_BUNDLE_IDENTIFIER="com.iteconomy.instacastplus.shortcutstests",
                DEVELOPMENT_TEAM="L95F4M2LHG", CODE_SIGN_STYLE="Automatic", GENERATE_INFOPLIST_FILE="YES",
                TARGETED_DEVICE_FAMILY="1,2", FRAMEWORK_SEARCH_PATHS=["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
                LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"])
add("CONFIG", "XCBuildConfiguration", name="Debug", buildSettings=settings)
add("CONFIGS", "XCConfigurationList", buildConfigurations=["CONFIG"], defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
add("PROJECT_CONFIG", "XCBuildConfiguration", name="Debug", buildSettings={})
add("PROJECT_CONFIGS", "XCConfigurationList", buildConfigurations=["PROJECT_CONFIG"], defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
add("TARGET", "PBXNativeTarget", name="ShortcutsControlsTests", productName="ShortcutsControlsTests", productReference="PRODUCT",
    productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList="CONFIGS", buildPhases=["SOURCES"], buildRules=[], dependencies=[])
add("PROJECT", "PBXProject", attributes={"LastUpgradeCheck": "2700"}, buildConfigurationList="PROJECT_CONFIGS", compatibilityVersion="Xcode 14.0",
    developmentRegion="en", knownRegions=["en", "Base"], mainGroup="GROUP", productRefGroup="PRODUCTS", projectDirPath="", projectRoot="", targets=["TARGET"])
(project / "project.pbxproj").write_bytes(plistlib.dumps(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject="PROJECT")))
scheme = ET.Element("Scheme", LastUpgradeVersion="2700", version="1.3")
build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entry = ET.SubElement(ET.SubElement(build, "BuildActionEntries"), "BuildActionEntry", buildForTesting="YES", buildForRunning="NO", buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="YES")
reference = dict(BuildableIdentifier="primary", BlueprintIdentifier="TARGET", BuildableName="ShortcutsControlsTests.xctest", BlueprintName="ShortcutsControlsTests", ReferencedContainer="container:ShortcutsControls.xcodeproj")
ET.SubElement(entry, "BuildableReference", **reference)
test = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="NO")
ET.SubElement(ET.SubElement(ET.SubElement(test, "Testables"), "TestableReference", skipped="NO"), "BuildableReference", **reference)
env = ET.SubElement(test, "EnvironmentVariables")
for key, value in {"IC_PROBE_DIRECTORY": str(directory), "IC_PROBE_LIBRARY": str(library)}.items():
    ET.SubElement(env, "EnvironmentVariable", key=key, value=value, isEnabled="YES")
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(schemes / "ShortcutsControls.xcscheme", encoding="utf-8", xml_declaration=True)
try:
    run(["xcodebuild", "-project", str(project), "-scheme", "ShortcutsControls", "-destination", f"platform=iOS Simulator,id={args.udid}",
         "-derivedDataPath", str(out / "TestDD"), "-resultBundlePath", str(out / "Tests.xcresult"), "-parallel-testing-enabled", "NO",
         "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "180", "test"], stream=True)
except Exception:
    (out / "result.json").write_text(json.dumps({"passed": False, "evidence": "commands.log and Tests.xcresult"}, indent=2))
    raise
else:
    (out / "result.json").write_text(json.dumps({"passed": True, "evidence": "commands.log and Tests.xcresult"}, indent=2))
    print("PASS: Real App Intents controls flow; evidence:", out)
