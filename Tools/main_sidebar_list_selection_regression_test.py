#!/usr/bin/env python3
"""Pins sidebar list taps to the list identity rendered in the tapped row."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "MainSidebarController.h").read_text()
MAIN_VIEW = (ROOT / "Classes" / "MainViewController_4.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


# The failing customer scenario is deterministic: the visible rows were built from one
# MainMenuListUIDs order, then restored/synced settings changed that order before the tap.
# Re-resolving the row's ordinal tag against the new array selects a different list.
rendered_uids = ["default.downloaded", "legacy.unplayed"]
current_uids = ["legacy.unplayed", "default.downloaded"]
rendered_tag = 100
require(rendered_uids[rendered_tag - 100] != current_uids[rendered_tag - 100],
        "The regression fixture must demonstrate that a dynamic ordinal can change identity.")

require(
    "NSString* listUID" in HEADER,
    "A rendered sidebar list item must retain its stable list UID instead of only an ordinal tag.",
)

sidebar_item = method_body(MAIN_VIEW, "- (MainSidebarItem*) _sidebarItemForListUID:")
require(
    "item.listUID = uid" in sidebar_item,
    "The sidebar row must retain the exact UID whose title and icon it renders.",
)

view_did_load = method_body(MAIN_VIEW, "- (void)viewDidLoad")
require(
    "item.listUID.length > 0" in view_did_load
    and "_selectMainSidebarListWithUID:item.listUID" in view_did_load,
    "Tapping a rendered list row must select its retained UID, not re-resolve its ordinal tag.",
)

select_list = method_body(MAIN_VIEW, "- (BOOL) _selectMainSidebarListWithUID:")
require(
    "[self _listForUID:uid]" in select_list
    and "ListEpisodesTableViewController" in select_list,
    "Stable list selection must resolve the retained UID and open that list controller.",
)

select_tag = method_body(MAIN_VIEW, "- (BOOL) _selectMainSidebarItemWithTag:")
dynamic_branch = select_tag[:select_tag.find("switch (tag)")]
require(
    "if (tag >= 100)" in dynamic_branch
    and "return NO;" in dynamic_branch,
    "An unresolved dynamic tag must fail selection instead of falling through to Podcasts.",
)

print("Main-sidebar stable list-selection regression checks passed")
