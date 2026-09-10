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
output = subprocess.check_output([
    "xcrun", "llvm-objdump",
    "--disassemble-symbols=_ICAITranscriptionFeaturesAvailable",
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
