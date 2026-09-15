#!/usr/bin/env python3
"""Verify the transcription gate in the actual optimized arm64 iPhone app."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--expected", choices=("enabled", "disabled"), required=True)
args = parser.parse_args()
with (args.app / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
assert info["CFBundleIdentifier"] == "com.iteconomy.instacastplus"
binary = args.app / info["CFBundleExecutable"]
archive = next((parent for parent in args.app.parents if parent.suffix == ".xcarchive"), None)
assert archive is not None, "Expected an app inside an xcarchive"
dwarf = (
    archive / "dSYMs" / f"{args.app.name}.dSYM" /
    "Contents" / "Resources" / "DWARF" / info["CFBundleExecutable"]
)
assert dwarf.is_file(), f"Missing app dSYM binary: {dwarf}"

def arm64_uuid(path):
    uuid_output = subprocess.check_output(
        ["xcrun", "dwarfdump", "--uuid", str(path)], text=True
    )
    match = re.search(r"^UUID: ([0-9A-F-]+) \(arm64\)", uuid_output, re.MULTILINE)
    assert match, f"Missing arm64 UUID for {path}:\n{uuid_output}"
    return match.group(1)

assert arm64_uuid(binary) == arm64_uuid(dwarf), "App binary and dSYM UUID differ"
symbols = subprocess.check_output(["xcrun", "nm", "-nm", str(dwarf)], text=True)
symbol = re.search(
    r"^([0-9a-fA-F]+).* _ICAITranscriptionFeaturesAvailable$",
    symbols, re.MULTILINE,
)
assert symbol, "Missing _ICAITranscriptionFeaturesAvailable in the app dSYM"
address = int(symbol.group(1), 16)
output = subprocess.check_output([
    "xcrun", "llvm-objdump", "--disassemble",
    f"--start-address=0x{address:x}", f"--stop-address=0x{address + 8:x}",
    "--no-show-raw-insn", str(binary),
], text=True)
assert "file format mach-o arm64" in output, "Expected the optimized arm64 iPhone build"
instructions = re.findall(r"^[0-9a-f]+:\s+(.+)$", output, re.MULTILINE)
expected = "1" if args.expected == "enabled" else "0"
assert len(instructions) == 2 and re.fullmatch(
    rf"mov\s+w0, #0x{expected}\s*(?:;.*)?", instructions[0]
) and instructions[1].strip() == "ret", (
    f"Transcription must be {args.expected} in the delivered binary; got:\n{output}"
)
print(f"Transcription {args.expected}: verified in {binary}")
