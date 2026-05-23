from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    next_method = source.find("\n- (", start + 1)
    return source[start:] if next_method == -1 else source[start:next_method]


episodes_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
up_next_source = (ROOT / "Classes" / "UpNextTableViewController.m").read_text()
cell_source = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()

cell_signature = "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath"
episodes_cell = method_body(episodes_source, cell_signature)
up_next_cell = method_body(up_next_source, cell_signature)
episodes_swipe_action = method_body(
    episodes_source,
    "- (UIContextualAction*) _contextualSwipeActionForSwipeAction:(ICEpisodeSwipeAction)swipeAction atIndexPath:(NSIndexPath*)indexPath",
)
up_next_download_swipe_action = method_body(
    up_next_source,
    "- (UIContextualAction*) _downloadSwipeActionAtIndexPath:(NSIndexPath*)indexPath",
)
up_next_remove_swipe_action = method_body(
    up_next_source,
    "- (UIContextualAction*) _removeSwipeActionAtIndexPath:(NSIndexPath*)indexPath",
)

for source, name in [
    (episodes_source, "EpisodesTableViewController"),
    (up_next_source, "UpNextTableViewController"),
]:
    require(
        "leadingSwipeActionsConfigurationForRowAtIndexPath:" in source
        and "trailingSwipeActionsConfigurationForRowAtIndexPath:" in source,
        f"{name} must use native UITableView swipe actions for system-consistent commit thresholds and feedback.",
    )
    require(
        "performsFirstActionWithFullSwipe = YES" in source,
        f"{name} must let the system handle full-swipe commits instead of a custom low-distance pan threshold.",
    )
    can_edit = method_body(
        source,
        "- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath",
    )
    editing_style = method_body(
        source,
        "- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath",
    )
    require(
        "return YES;" in can_edit,
        f"{name} must allow table-view editing hooks so UIKit exposes native swipe actions.",
    )
    require(
        "UITableViewCellEditingStyleNone" in editing_style,
        f"{name} must keep normal editing controls hidden while enabling native swipe actions.",
    )

for cell_block, name in [
    (episodes_cell, "episode list cells"),
    (up_next_cell, "Up Next cells"),
]:
    require(
        "cell.panRecognizer.enabled = NO;" in cell_block,
        f"{name} must disable EpisodesTableViewCell's custom pan recognizer so slight swipes cannot commit actions.",
    )
    require(
        "didPanLeft =" not in cell_block
        and "didPanRight =" not in cell_block
        and "SwipeImageProvider =" not in cell_block
        and "SwipeTintProvider =" not in cell_block,
        f"{name} must not wire custom pan callbacks/providers for swipe actions.",
    )

require(
    "_performSwipeAction:" in episodes_source
    and "_contextualSwipeActionForSwipeAction:" in episodes_source,
    "Episode native swipe actions must still route through the shared swipe-action implementation.",
)
require(
    "- (NSIndexPath*) _indexPathForEpisode:(CDEpisode*)episode" in episodes_source,
    "Episode swipe actions must resolve the current index path from the captured episode identity before performing an action.",
)
require(
    "_indexPathForEpisode:episode" in episodes_swipe_action
    and "_performSwipeAction:swipeAction atIndexPath:currentIndexPath" in episodes_swipe_action
    and "_performSwipeAction:swipeAction atIndexPath:indexPath" not in episodes_swipe_action,
    "Episode swipe handlers must not perform actions through the originally configured index path, which can drift to another episode while the swipe is open.",
)
require(
    "_toggleDownloadAtIndexPath:" in up_next_source
    and "_removeEpisodeAtIndexPath:" in up_next_source,
    "Up Next native swipe actions must preserve the existing download and remove behavior.",
)
require(
    "- (NSIndexPath*) _indexPathForEpisode:(CDEpisode*)episode" in up_next_source,
    "Up Next swipe actions must resolve the current index path from the captured episode identity before performing an action.",
)
require(
    "_indexPathForEpisode:episode" in up_next_download_swipe_action
    and "_toggleDownloadAtIndexPath:currentIndexPath" in up_next_download_swipe_action
    and "_toggleDownloadAtIndexPath:indexPath" not in up_next_download_swipe_action,
    "Up Next download swipe handlers must not use the originally configured index path.",
)
require(
    "_indexPathForEpisode:episode" in up_next_remove_swipe_action
    and "_removeEpisodeAtIndexPath:currentIndexPath" in up_next_remove_swipe_action
    and "_removeEpisodeAtIndexPath:indexPath" not in up_next_remove_swipe_action,
    "Up Next remove swipe handlers must not use the originally configured index path.",
)
require(
    "self.panningContentView.frame = self.contentView.bounds;" not in cell_source,
    "Episode rows must not copy contentView.bounds into panningContentView.frame; UIKit swipe changes bounds/frame during gestures, and copying the origin can leave artwork over the swipe action instead of moving with the row.",
)
