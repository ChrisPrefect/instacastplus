#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "DataSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


cell = method_body("cellForRowAtIndexPath:")
reload_stats = method_body("- (void)_reloadStatistics")
view_will_appear = method_body("- (void)viewWillAppear:")

require(
    "countForFetchRequest" not in cell,
    "Statistics cells must never run synchronous SQL counts during table rendering.",
)
require(
    "newBackgroundContext" in reload_stats
    and "performBlock:" in reload_stats
    and "specifications" in reload_stats
    and "countForFetchRequest" in reload_stats
    and "NSNotFound" in reload_stats,
    "Subscription and episode statistics need one background snapshot with explicit count failures.",
)
require(
    "statisticsCounts" in cell
    and 'cell.detailTextLabel.text = @"…"' in cell
    and '@"Nicht verfügbar".ls' in cell,
    "Statistics must show loading and unavailable states instead of formatting NSNotFound as a huge integer.",
)
require(
    "_reloadStatistics" in view_will_appear,
    "The statistics snapshot must refresh when the Data screen appears.",
)


print("Data settings statistics-snapshot regression checks passed")
