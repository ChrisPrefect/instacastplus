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


def method_body_any(source: str, signatures: list[str]) -> str:
    for signature in signatures:
        start = source.find(signature)
        if start != -1:
            next_method = source.find("\n- (", start + 1)
            return source[start:] if next_method == -1 else source[start:next_method]
    raise SystemExit(f"Missing method: {' or '.join(signatures)}")


episodes_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
episodes_header = (ROOT / "Classes" / "EpisodesTableViewController.h").read_text()
list_episodes_source = (ROOT / "Classes" / "ListEpisodesTableViewController.m").read_text()
up_next_source = (ROOT / "Classes" / "UpNextTableViewController.m").read_text()
apple_watch_source = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
player_info_source = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
cell_header = (ROOT / "Classes" / "EpisodesTableViewCell.h").read_text()
cell_source = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()

cell_signature = "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath"
episodes_cell = method_body(episodes_source, cell_signature)
up_next_cell = method_body(up_next_source, cell_signature)
apple_watch_cell = method_body_any(
    apple_watch_source,
    [cell_signature, "- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath"],
)
player_info_cell = method_body(player_info_source, cell_signature)
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
list_observing = method_body(
    list_episodes_source,
    "- (void) _setObserving:(BOOL)observing",
)
list_remove_after_mutation = method_body(
    list_episodes_source,
    "- (BOOL) _removeEpisodeFromDisplayedListIfNeededAfterMutation:(CDEpisode*)episode atIndexPath:(NSIndexPath*)indexPath",
)
cell_layout = method_body(
    cell_source,
    "- (void) layoutSubviews",
)
cell_layout_code = "\n".join(
    line for line in cell_layout.splitlines()
    if not line.lstrip().startswith("//")
)


def outside_contextual_action_handler(source: str) -> str:
    before_handler, separator, after_handler = source.partition("handler:^")
    require(separator, "Missing UIContextualAction handler block.")
    end = after_handler.find("}];")
    require(end != -1, "Could not find end of UIContextualAction handler block.")
    return before_handler + after_handler[end + len("}];") :]


def assert_no_swipe_mutation_before_release(source: str, name: str) -> None:
    non_handler_source = outside_contextual_action_handler(source)
    forbidden_markers = [
        "_performSwipeAction:",
        "_toggleDownloadAtIndexPath:",
        "_removeEpisodeAtIndexPath:",
        "markEpisode:",
        "removeCacheForEpisode:",
        "cancelCachingEpisode:",
        "cacheEpisode:",
        "setEpisode:",
        "deleteRowsAtIndexPaths:",
        "reloadData",
        "reloadDataAndPreserveSelection",
        "self.suppressNextListReload = YES;",
        "PlaySoundFile(",
    ]
    offenders = [marker for marker in forbidden_markers if marker in non_handler_source]
    require(
        not offenders,
        f"{name} must not mutate app state while UIKit is merely revealing a swipe action; found {', '.join(offenders)} outside the release handler.",
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
    (apple_watch_cell, "Apple Watch episode cells"),
    (player_info_cell, "player Up Next cells"),
]:
    require(
        "cell.usesNativeSwipeActions = YES;" in cell_block,
        f"{name} must opt EpisodesTableViewCell into native-swipe layout, not only disable the custom pan recognizer.",
    )
    require(
        "cell.panRecognizer.enabled = NO;" not in cell_block,
        f"{name} must not bypass the cell's native-swipe layout mode by toggling the recognizer directly.",
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
    "@property (nonatomic) BOOL usesNativeSwipeActions;" in cell_header
    and "- (void)setUsesNativeSwipeActions:(BOOL)usesNativeSwipeActions" in cell_source,
    "EpisodesTableViewCell needs an explicit native-swipe mode so native UIKit swipes do not run through the legacy panning container.",
)
require(
    "self.panRecognizer.enabled = !usesNativeSwipeActions;" in cell_source,
    "Native-swipe mode must own the old custom pan recognizer state.",
)
require(
    "_moveEpisodeContentToView:self.panningContentView" in cell_source
    and "_moveEpisodeContentToView:self.contentView" not in cell_source,
    "Episode artwork/text/buttons must stay inside one shared content container; direct contentView subviews can move independently when UIKit changes contentView bounds during native swipes.",
)
require(
    "if (self.usesNativeSwipeActions)" not in cell_layout
    and "self.panningContentView.frame = self.contentView.bounds;" not in cell_layout
    and "CGRect contentBounds = self.contentView.bounds;\n    contentBounds.origin = CGPointZero;\n    self.panningContentView.frame = contentBounds;" in cell_layout,
    "Native UIKit swipes must not relayout the episode container to contentView.bounds while the swipe view is moving; keep one zero-origin content container so artwork and text travel as one row.",
)
require(
    "BOOL usesTableEditingLayout = self.editing && self.showsEditControl;" in cell_layout_code
    and "if (usesTableEditingLayout)" in cell_layout_code
    and "if (self.editing)" not in cell_layout_code
    and "(self.editing)" not in cell_layout_code
    and "imageViewRect.origin.x = -CGRectGetMinX(self.contentView.frame)-56;" in cell_layout_code,
    "Native swipe actions can put UITableViewCell into an editing transition without table edit controls; only the real table-editing layout may counter-position the episode artwork.",
)
require(
    "self.panningContentView.hidden = YES" not in cell_source,
    "Native-swipe rows must not hide the shared episode content container.",
)
assert_no_swipe_mutation_before_release(episodes_swipe_action, "Episode swipe actions")
assert_no_swipe_mutation_before_release(up_next_download_swipe_action, "Up Next download swipe action")
assert_no_swipe_mutation_before_release(up_next_remove_swipe_action, "Up Next remove swipe action")
require(
    "@property (nonatomic) BOOL suppressNextListReload;" in episodes_header,
    "Swipe actions need an explicit one-shot list reload suppression flag; userAction is reset before DatabaseManager's delayed list invalidation arrives.",
)
require(
    "if (weakSelf.suppressNextListReload)" in list_observing
    and "weakSelf.suppressNextListReload = NO;" in list_observing
    and list_observing.find("if (weakSelf.suppressNextListReload)") < list_observing.find("reloadDataAndPreserveSelection"),
    "ListEpisodesTableViewController must consume the delayed list invalidation from swipe actions before it can full-reload the table and shift scroll position.",
)
require(
    "_removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath" in episodes_source
    and episodes_source.count("self.suppressNextListReload = YES;") >= 5,
    "Episode swipe mutations must suppress their delayed list invalidation and use row-level updates instead of allowing a later full reload.",
)
require(
    "_episode:episode matchesCurrentEpisodeList:" in list_remove_after_mutation
    and "deleteRowsAtIndexPaths:@[indexPath]" in list_remove_after_mutation
    and "self.suppressNextListReload = YES;" in list_remove_after_mutation,
    "When a swipe mutation removes an episode from the current smart list, the visible row must be deleted immediately and the delayed full reload suppressed.",
)
