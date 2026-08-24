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


episodes = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
up_next = (ROOT / "Classes" / "UpNextTableViewController.m").read_text()
downloads = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
watch = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
transcription = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
player_info = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
directory = (ROOT / "Classes" / "DirectoryFeedViewController.m").read_text()
project = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()

handler_header_path = ROOT / "Classes" / "ICEpisodeSwipeActionHandler.h"
handler_source_path = ROOT / "Classes" / "ICEpisodeSwipeActionHandler.m"
require(handler_header_path.exists() and handler_source_path.exists(),
        "Special episode lists need one shared configured-right swipe-action handler.")
handler_header = handler_header_path.read_text()
handler_source = handler_source_path.read_text()

require(
    "configuredRightSwipeActionForEpisode:" in handler_header
    and "EpisodeSwipeRightAction" in handler_source,
    "The shared handler must resolve the global right-swipe setting from its single defaults key.",
)
require(
    "ICEpisodeSwipeActionHandler.m in Sources" in project,
    "The shared episode swipe handler must be compiled into the iOS app target.",
)

# Normal podcast/list episode screens keep both user-configurable directions.
normal_leading = method_body(
    episodes,
    "- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath",
)
normal_trailing = method_body(
    episodes,
    "- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath",
)
require("EpisodeSwipeRightAction" in normal_leading and "EpisodeSwipeLeftAction" in normal_trailing,
        "Normal podcast and smart-list screens must retain both configured swipe directions.")

# Every special list with real episode rows uses the configured action on swipe right.
for source, filename in [
    (up_next, "UpNextTableViewController.m"),
    (downloads, "DownloadsViewController.m"),
    (watch, "AppleWatchEpisodesViewController.m"),
    (transcription, "TranscriptionQueueViewController.m"),
    (player_info, "PlayerInfoViewController_v5.m"),
]:
    require(
        "configuredRightSwipeActionForEpisode:" in source,
        f"{filename} must route swipe right through the globally configured episode action.",
    )

up_next_trailing = method_body(
    up_next,
    "- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath",
)
require(
    "EpisodeSwipeLeftAction" not in up_next_trailing
    and "_removeSwipeActionAtIndexPath:indexPath" in up_next_trailing,
    "Play Next swipe left must always remove the episode, independent of the global left setting.",
)

downloads_trailing = method_body(
    downloads,
    "- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath",
)
require(
    "cancelCachingEpisode:episode disableAutoDownload:YES" in downloads_trailing
    and "clearDownloadErrorForEpisode:episode" in downloads_trailing,
    "Downloads swipe left must remove both active and failed download entries.",
)

watch_leading = method_body(
    watch,
    "- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath",
)
require(
    "configuredRightSwipeActionForEpisode:" in watch_leading
    and "prioritizeEpisodeOnWatch:" not in watch_leading,
    "Apple Watch swipe right must use the global action; Watch retry remains in the context menu.",
)

require(
    "leadingSwipeActionsConfigurationForRowAtIndexPath" not in directory
    and "trailingSwipeActionsConfigurationForRowAtIndexPath" not in directory,
    "Directory and preview episode rows must remain free of swipe actions.",
)

print("Episode swipe policy regression checks passed")
