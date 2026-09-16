#!/usr/bin/env python3
"""Create the isolated iPhone model-benchmark project in a build directory.

Usage: python3 Tools/ios27_benchmark_project.py INPUT.json OUTPUT_DIRECTORY [--intents-tests]
Then build ChapterBenchmark.xcodeproj, scheme ChapterBenchmark, for the test iPhone.
With --intents-tests, scheme AudioSchemaTests tests an already installed Instacast simulator app.
"""
import argparse
import plistlib
from pathlib import Path
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("input", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--intents-tests", action="store_true")
args = parser.parse_args()
fixture, output = args.input.resolve(), args.output.resolve()
assert fixture.is_file()
source = Path(__file__).with_name("ios27_local_chapter_benchmark.swift").resolve()
project = output / "ChapterBenchmark.xcodeproj"
project.mkdir(parents=True, exist_ok=True)
objects = {}


def obj(identifier, isa, **values):
    objects[identifier] = dict(isa=isa, **values)
    return identifier


source_ref = obj("SOURCE", "PBXFileReference", path=str(source), sourceTree="<absolute>", lastKnownFileType="sourcecode.swift")
input_ref = obj("INPUT", "PBXFileReference", path=str(fixture), sourceTree="<absolute>", lastKnownFileType="text.json")
product = obj("PRODUCT", "PBXFileReference", path="ChapterBenchmark.app", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.application")
source_build = obj("SOURCE_BUILD", "PBXBuildFile", fileRef=source_ref)
input_build = obj("INPUT_BUILD", "PBXBuildFile", fileRef=input_ref)
sources = obj("SOURCES", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[source_build], runOnlyForDeploymentPostprocessing=0)
resources = obj("RESOURCES", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[input_build], runOnlyForDeploymentPostprocessing=0)
frameworks = obj("FRAMEWORKS", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
products = obj("PRODUCTS", "PBXGroup", children=[product], name="Products", sourceTree="<group>")
group = obj("GROUP", "PBXGroup", children=[source_ref, input_ref, products], sourceTree="<group>")
settings = dict(PRODUCT_NAME="ChapterBenchmark", PRODUCT_BUNDLE_IDENTIFIER="com.iteconomy.instacastplus.chapterbenchmark",
                DEVELOPMENT_TEAM="L95F4M2LHG", CODE_SIGN_STYLE="Automatic", SDKROOT="iphoneos",
                IPHONEOS_DEPLOYMENT_TARGET="27.0", SWIFT_VERSION="6.0", TARGETED_DEVICE_FAMILY="1,2",
                GENERATE_INFOPLIST_FILE="YES", INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES",
                INFOPLIST_KEY_UILaunchScreen_Generation="YES", INFOPLIST_KEY_CFBundleDisplayName="Chapter Benchmark",
                MARKETING_VERSION="1.0", CURRENT_PROJECT_VERSION="1", SWIFT_OPTIMIZATION_LEVEL="-O",
                ENABLE_USER_SCRIPT_SANDBOXING="YES", SUPPORTS_MACCATALYST="NO", ALWAYS_SEARCH_USER_PATHS="NO")
project_config = obj("PROJECT_CONFIG", "XCBuildConfiguration", name="Release", buildSettings={})
target_config = obj("TARGET_CONFIG", "XCBuildConfiguration", name="Release", buildSettings=settings)
project_configs = obj("PROJECT_CONFIGS", "XCConfigurationList", buildConfigurations=[project_config], defaultConfigurationName="Release", defaultConfigurationIsVisible=0)
target_configs = obj("TARGET_CONFIGS", "XCConfigurationList", buildConfigurations=[target_config], defaultConfigurationName="Release", defaultConfigurationIsVisible=0)
target = obj("TARGET", "PBXNativeTarget", name="ChapterBenchmark", productName="ChapterBenchmark", productReference=product,
             productType="com.apple.product-type.application", buildConfigurationList=target_configs,
             buildPhases=[sources, frameworks, resources], buildRules=[], dependencies=[])
root = obj("PROJECT", "PBXProject", attributes=dict(LastUpgradeCheck="2700"), buildConfigurationList=project_configs,
           compatibilityVersion="Xcode 14.0", developmentRegion="en", knownRegions=["en", "Base"],
           mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])

if args.intents_tests:
    test_source = obj("TESTSOURCE", "PBXFileReference", path=str(source.with_name("ios27_app_intents_runtime_tests.swift")),
                      sourceTree="<absolute>", lastKnownFileType="sourcecode.swift")
    test_product = obj("TESTPRODUCT", "PBXFileReference", path="AudioSchemaTests.xctest", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.cfbundle")
    test_build = obj("TESTBUILD", "PBXBuildFile", fileRef=test_source)
    test_sources = obj("TESTSOURCES", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[test_build], runOnlyForDeploymentPostprocessing=0)
    test_config = obj("TESTCONFIG", "XCBuildConfiguration", name="Release", buildSettings={
        **settings, "PRODUCT_NAME": "AudioSchemaTests", "PRODUCT_BUNDLE_IDENTIFIER": "com.iteconomy.instacastplus.audioschematests",
        "TEST_TARGET_NAME": "ChapterBenchmark", "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"],
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]})
    test_configs = obj("TESTCONFIGS", "XCConfigurationList", buildConfigurations=[test_config], defaultConfigurationName="Release", defaultConfigurationIsVisible=0)
    test_target = obj("TESTTARGET", "PBXNativeTarget", name="AudioSchemaTests", productName="AudioSchemaTests", productReference=test_product,
                      productType="com.apple.product-type.bundle.ui-testing", buildConfigurationList=test_configs,
                      buildPhases=[test_sources], buildRules=[], dependencies=[])
    objects[group]["children"].append(test_source)
    objects[products]["children"].append(test_product)
    objects[root]["targets"].append(test_target)
    scheme = ET.Element("Scheme", LastUpgradeVersion="2700", version="1.3")
    entries = ET.SubElement(ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES"), "BuildActionEntries")

    def reference(parent, identifier, name, filename):
        ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=identifier,
                      BuildableName=filename, BlueprintName=name, ReferencedContainer="container:ChapterBenchmark.xcodeproj")

    for identifier, name, filename in [(target, "ChapterBenchmark", "ChapterBenchmark.app"), (test_target, "AudioSchemaTests", "AudioSchemaTests.xctest")]:
        entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO", buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="YES")
        reference(entry, identifier, name, filename)
    action = ET.SubElement(scheme, "TestAction", buildConfiguration="Release", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB",
                           selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testable = ET.SubElement(ET.SubElement(action, "Testables"), "TestableReference", skipped="NO")
    reference(testable, test_target, "AudioSchemaTests", "AudioSchemaTests.xctest")
    schemes = project / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(schemes / "AudioSchemaTests.xcscheme", encoding="utf-8", xml_declaration=True)

(project / "project.pbxproj").write_bytes(plistlib.dumps(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=root)))
print(project)
