#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def objc_method(source: str, signature: str) -> str:
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
    raise AssertionError(f"Unterminated method body: {signature}")


def source_between(source: str, start: str, end: str) -> str:
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


icloud_manager = read("Classes/ICiCloudSyncManager.swift")
appearance_settings = read("Classes/AppearanceSettingsViewController.m")
subscription_manager = read("Classes/Model/SubscriptionManager.m")
feed_parser = read("Classes/Parser/ICFeedParser.m")
feed_parser_header = read("Classes/Parser/ICFeedParser.h")
de_strings = read("Resources/de.lproj/Localizable.strings")
en_strings = read("Resources/en.lproj/Localizable.strings")

status_text = source_between(icloud_manager, "@objc var statusText: String {", "\n    @objc var devices")
disabled_guard = 'guard anySyncEnabled else { return NSLocalizedString("Aus", comment: "") }'
require(disabled_guard in status_text, "Disabled iCloud Sync must always display Aus instead of stale receiving/sending/status text.")
require(
    status_text.index(disabled_guard) < status_text.index("defaults.string(forKey: Self.lastErrorKey)")
    and status_text.index(disabled_guard) < status_text.index("syncProgressStatusText()")
    and status_text.index(disabled_guard) < status_text.index("defaults.string(forKey: Self.lastStatusKey)"),
    "The disabled iCloud Sync status guard must run before stale error/progress/status metadata is read.",
)

require(
    "case kEpisodesSection:\n            return 3;" in appearance_settings,
    "Appearance > Episodes must expose Tap on Episode together with the swipe action settings.",
)
appearance_cells = objc_method(appearance_settings, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:")
episodes_cell_block = source_between(appearance_cells, "else if (indexPath.section == kEpisodesSection)", "\n    else if (indexPath.section == kAppearanceThemeSection)")
require('"Tap on Episode".ls' in episodes_cell_block and "TapOnEpisodeAction" in episodes_cell_block, "Appearance episode settings must show the Tap on Episode row.")
require(
    '"Swipe Right".ls' in episodes_cell_block
    and '"Swipe Left".ls' in episodes_cell_block
    and "indexPath.row == 1" in episodes_cell_block,
    "Appearance episode swipe rows must shift below Tap on Episode.",
)
appearance_select = objc_method(appearance_settings, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
episodes_select_block = source_between(appearance_select, "else if (indexPath.section == kEpisodesSection)", "\n    else if (indexPath.section == kPlayerColor)")
require(
    "controller.key = TapOnEpisodeAction" in episodes_select_block
    and "ICTapOnEpisodeActionOpenContextMenu" in episodes_select_block,
    "Selecting Appearance > Episodes > Tap on Episode must edit the existing TapOnEpisodeAction setting.",
)
require(
    "controller.key = (indexPath.row == 1) ? EpisodeSwipeRightAction : EpisodeSwipeLeftAction" in episodes_select_block,
    "Appearance swipe settings must still edit the right/left swipe keys after the tap row is restored.",
)

for relative_path, signature in [
    ("Classes/ListEpisodesTableViewController.m", "- (void) refresh:(id)sender"),
    ("Classes/FeedEpisodesTableViewController.m", "- (void) pullToRefresh:(id)sender"),
    ("Classes/PlaylistsTableViewController.m", "- (void) refresh:(id)sender"),
    ("Classes/SubscriptionsTableViewController.m", "- (void) refresh:(id)sender"),
]:
    body = objc_method(read(relative_path), signature)
    require(
        "presentError:error" not in body,
        f"{relative_path} must not show raw refresh errors directly; the gated refresh-failure UI owns these messages.",
    )

friendly_error = objc_method(subscription_manager, "- (NSString*) _friendlyRefreshFailureReasonForError:(NSError*)error")
require(
    "ICFeedParserHTTPStatusCodeErrorKey" in feed_parser_header
    and "ICFeedParserHTTPStatusCodeErrorKey" in feed_parser,
    "Feed parser errors must preserve HTTP status codes for refresh-failure classification.",
)
require(
    "statusCode >= 400" in feed_parser
    and "NSURLErrorBadServerResponse" in feed_parser
    and "ICFeedParserHTTPStatusCodeErrorKey: @(statusCode)" in feed_parser,
    "Feed parser HTTP errors must carry the original status code instead of being flattened into parser errors.",
)
require("NSXMLParserErrorDomain" in friendly_error, "XML parser refresh errors must be mapped to a user-facing reason.")
require(
    'if ([error.domain isEqualToString:NSXMLParserErrorDomain]) {\n        return @"Feed contains invalid XML.".ls;\n    }' in friendly_error,
    "NSXMLParserErrorDomain must mean malformed feed XML.",
)
require(
    'if ([error.domain isEqualToString:@"kPodcastFeedParserErrorDomain"]) {\n        return @"Unsupported podcast feed format.".ls;\n    }' in friendly_error,
    "Parser-domain failures without XML parser details must be reported as unsupported feed format, not malformed XML.",
)
require(
    'return @"Unsupported podcast feed format.".ls;' in friendly_error.split('The podcast could not be read, either because the feed does not exist or because the feed format is not supported.', 1)[1].split('NSNumber* httpStatusCode', 1)[0],
    "The parser's generic no-feed/unsupported-format recovery text must map to unsupported feed format.",
)
for key in [
    "Domain not found.",
    "Feed not found or removed.",
    "Server temporarily unavailable.",
    "No internet connection.",
    "No access.",
    "Website returned instead of podcast feed.",
    "Feed contains invalid XML.",
    "Unsupported podcast feed format.",
    "Server rejected the feed request.",
    "Secure connection failed.",
]:
    require(f'@"{key}".ls' in friendly_error or f'return @"{key}".ls;' in friendly_error, f"Refresh failures must classify {key}")
    for strings, language in [(de_strings, "German"), (en_strings, "English")]:
        require(f'"{key}" =' in strings, f"{language} localization is missing {key}")
require(
    "return error.localizedDescription" not in friendly_error,
    "Refresh failure status text must not fall back to raw NSError descriptions with domains or numeric codes.",
)
require(
    '"Podcast feed could not be read."' not in de_strings
    and '"Podcast feed could not be read."' not in en_strings
    and "Podcast feed could not be read." not in subscription_manager,
    "The generic podcast-feed error text is too vague and must not be used.",
)

print("Current reported sync/settings regression checks passed.")
