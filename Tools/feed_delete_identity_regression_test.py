#!/usr/bin/env python3
"""Keep delayed feed deletion bound to the episodes selected before its dialogs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "FeedEpisodesTableViewController.m").read_text()


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


long_press = method_body("addAdditionalButtonsToLongPressActionSheet:")
context_menu = method_body("additionalContextMenuActionsForIndexPath:")
multi_select = method_body("addAdditionalButtonsToMultiSelectEditActionSheet:")
confirm = method_body("- (void)showDeleteConfirmPopUpForEpisodes:")

for body, surface in ((long_press, "long-press sheet"), (context_menu, "context menu")):
    require(
        "CDEpisode* episode" in body
        and "showDeleteConfirmPopUpForEpisodes:@[episode] behavior:ICFeedEpisodeArchiveBehaviorArchiveAndConsume" in body,
        f"The feed {surface} must capture its episode before the confirmation dialog.",
    )

require(
    "_episodesAtIndexPaths:selectedIndexPathes" in multi_select
    and "showDeleteConfirmPopUpForEpisodes:selectedEpisodes behavior:ICFeedEpisodeArchiveBehaviorArchiveOnly" in multi_select,
    "Multi-select delete must turn rows into stable episode identities before its first dialog closes.",
)
require(
    "ICFeedEpisodeArchiveBehaviorArchiveOnly" in SOURCE
    and "ICFeedEpisodeArchiveBehaviorArchiveAndConsume" in SOURCE
    and "for (CDEpisode* episode in episodes)" in confirm
    and "removeCacheForEpisode:episode" in confirm
    and "[DMANAGER setEpisode:episode archived:YES]" in confirm
    and "episode.archived = YES" in confirm,
    "Confirmation must preserve the existing single- and multi-delete archive contracts for captured episodes.",
)
require(
    "afterDelay:" not in confirm and "dispatch_after" not in confirm,
    "Confirmed feed deletion must run from the alert action instead of an arbitrary delay.",
)
require(
    "self.episodes[" not in confirm
    and "objectAtIndex:" not in confirm
    and "selectedIndexPath" not in confirm
    and "rowIndexPath" not in confirm,
    "A feed confirmation must never map old rows onto the current feed.",
)

episodes = ["A", "B"]
captured = [episodes[1]]
episodes.insert(0, "X")
require(captured == ["B"] and episodes[1] == "A",
        "The fixture must reproduce a shifted feed row.")

print("Feed delete identity regression checks passed")
