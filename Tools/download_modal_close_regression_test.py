#!/usr/bin/env python3
"""Pins the Downloads close button to the modal that is actually presented."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "MainViewController_4.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


close_action = method_body("- (void) playerCloseButtonAction:")
require("downloadsViewController" not in close_action,
        "Closing Downloads must not instantiate a disconnected controller.")
require("self.presentedViewController" in close_action,
        "The close action must dismiss the modal currently presented by MainViewController.")
require("dismissViewControllerAnimated:YES" in close_action,
        "The actual Downloads modal must be dismissed visibly.")


print("Downloads modal-close regression checks passed")
