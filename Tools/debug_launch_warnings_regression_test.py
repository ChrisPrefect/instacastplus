#!/usr/bin/env python3
"""Validate that bundled llama debug symbols contain usable compilation units."""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LLAMA_XCFRAMEWORK = ROOT / "Frameworks" / "llama.xcframework"
failures: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


for dsym in LLAMA_XCFRAMEWORK.rglob("*.dSYM"):
    result = subprocess.run(
        ["xcrun", "dwarfdump", "--debug-info", str(dsym)],
        check=True,
        capture_output=True,
        text=True,
    )
    require(
        "DW_TAG_compile_unit" in result.stdout,
        f"{dsym.relative_to(LLAMA_XCFRAMEWORK)} is an empty llama dSYM; LLDB will warn and search for unusable symbols.",
    )


if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)

print("Bundled llama debug-symbol checks passed.")
