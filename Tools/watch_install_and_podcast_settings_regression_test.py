from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


watch_controller = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
feed_episodes_controller = (ROOT / "Classes" / "FeedEpisodesTableViewController.m").read_text()

header_block = watch_controller.split("- (void)_updateHeaderText", 1)[1].split("- (void)toggleEditMode:", 1)[0]
empty_message_block = watch_controller.split("- (NSString*)_emptyMessage", 1)[1].split("- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:", 1)[0]
empty_cell_block = watch_controller.split("if (self.states.count == 0) {", 1)[1].split("AppleWatchEpisodeState* state = self.states[indexPath.row];", 1)[0]

require(
    'self.summaryLabel.text = @"Die InstacastPlus-Watch-App ist noch nicht installiert.".ls;' in header_block,
    "The Watch page header should show only the short not-installed status.",
)
require(
    'return @"Installiere die InstacastPlus-Watch-App über die Watch-App auf deinem iPhone.' in empty_message_block,
    "The detailed Watch install instructions should appear only in the empty-state row.",
)
# Since d3f40ec9 (31.05.) the not-installed empty state uses a dedicated setup cell with an
# explicit "Watch-App öffnen" button instead of a disclosure-indicator row.
setup_cell_block = watch_controller.split("- (void)_configureWatchSetupCell", 1)[1].split("- (BOOL)_emptyMessageOpensWatchApp", 1)[0]
require(
    "_emptyMessageOpensWatchApp" in empty_cell_block
    and "_configureWatchSetupCell" in empty_cell_block,
    "The Watch install empty state must use the dedicated setup cell when the app is missing.",
)
require(
    '@"Watch-App öffnen".ls' in setup_cell_block
    and "_watchInstallButtonAction" in setup_cell_block,
    "The Watch install setup cell must offer an explicit button that opens the Watch app.",
)
require(
    '- (void)_openWatchApp' in watch_controller
    and '@"itms-watchs://"' in watch_controller
    and "[self _openWatchApp];" in watch_controller,
    "Tapping the Watch install row must open Apple's Watch app.",
)

feed_settings_block = feed_episodes_controller.split("Settings button in navigation bar", 1)[1].split("if ([[NSUserDefaults standardUserDefaults]", 1)[0]
require(
    'systemImageNamed:@"gearshape"' in feed_settings_block
    and 'action:@selector(settings:)' in feed_settings_block,
    "A single podcast episode list must use a settings gear for podcast settings.",
)
require(
    'systemImageNamed:@"pencil"' not in feed_settings_block,
    "A single podcast episode list must not use the edit pencil for podcast settings.",
)
