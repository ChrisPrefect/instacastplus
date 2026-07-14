#!/usr/bin/env python3
"""Pins external-backup preview presentation above an already open modal."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "MainViewController_4.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start >= 0, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace >= 0, f"Missing body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


open_backup = method_body("- (void)openBackupFileURL:")
require("_presentBackupPreviewWithData:" in open_backup,
        "Successful parsing must use one visibility-aware preview presenter.")

present_preview = method_body("- (void)_presentBackupPreviewWithData:")
require("presentedViewController" in present_preview,
        "Preview presentation must detect an already open modal.")
require("dismissViewControllerAnimated:" in present_preview and "completion:" in present_preview,
        "An existing modal must be dismissed before the backup preview is pushed.")
require("dispatch_block_t presentPreview" in present_preview
        and "dismissViewControllerAnimated:YES completion:presentPreview" in present_preview
        and "pushViewController:" in present_preview,
        "The preview push must be the dismissal completion, never an immediate push behind the modal.")


print("Backup preview presentation lifecycle regression checks passed")
