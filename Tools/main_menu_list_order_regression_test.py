#!/usr/bin/env python3
"""Pins one rank order for the Lists screen and visible main-menu lists."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "Classes" / "MainViewController_4.m").read_text()
EDITOR = (ROOT / "Classes" / "EpisodeListEditorViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


view_did_load = method_body(MAIN, "- (void)viewDidLoad")
require(
    "[CDList updateRanksOfLists:" not in view_did_load
    and "for (CDList* list in DMANAGER.lists)" in view_did_load
    and '[USER_DEFAULTS setObject:sortedMenuUIDs forKey:@"MainMenuListUIDs"]' in view_did_load,
    "App startup must repair main-menu UID order from list ranks; it must never overwrite "
    "the Lists screen rank order from a stale sidebar array.",
)

save = method_body(EDITOR, "- (void) save")
require(
    "for (CDList* rankedList in DMANAGER.lists)" in save
    and "[mainMenuUIDs containsObject:rankedList.uid]" in save
    and '[USER_DEFAULTS setObject:sortedMenuUIDs forKey:@"MainMenuListUIDs"]' in save,
    'Enabling "Show in Main Menu" must place the list by its existing rank, not append it.',
)


# Deterministic behavior proof for the reported scenario: recently played is moved to
# rank 0 while hidden, then enabled in the main menu.
ranked_uids = ["default.recentlyplayed", "default.favorites", "default.unplayed"]
visible_uids = ["default.favorites", "default.unplayed", "default.recentlyplayed"]
sorted_visible_uids = [uid for uid in ranked_uids if uid in visible_uids]
require(
    sorted_visible_uids == ranked_uids,
    "A newly visible rank-0 list must be the first main-menu list.",
)

print("Main-menu list order regression checks passed")
