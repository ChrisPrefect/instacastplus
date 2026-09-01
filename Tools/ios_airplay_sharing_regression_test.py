#!/usr/bin/env python3
"""Pins public AirPlay routing and system share-sheet integration on iOS."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


volume_header = read("Classes/ICVolumeView.h")
volume_impl = read("Classes/ICVolumeView.m")
controls_header = read("Classes/PlaybackControlsViewController.h")
controls = read("Classes/PlaybackControlsViewController.m")
audio_session = read("Classes/AudioSession.m")
exports = read("Classes/ImportExportSettingsViewController.m")
media_files = read("Classes/MediaFilesViewController.m")
player_controller = read("Classes/PlayerController.m")
playback_header = read("Classes/PlaybackManager.h")
playback = read("Classes/PlaybackManager.m")

require(
    "#import <AVKit/AVKit.h>" in volume_header
    and "@interface ICVolumeView : AVRoutePickerView" in volume_header,
    "The audio-route control must use Apple's public AVRoutePickerView API.",
)
for forbidden in (
    "objc/runtime.h",
    "+ (void) initialize",
    "NSSelectorFromString",
    "class_getInstanceMethod",
    "method_exchangeImplementations",
    "_setShowsRouteButton",
    "mySetShowsRouteButton",
):
    require(forbidden not in volume_impl, f"The route picker must not use private runtime behavior: {forbidden}")

create_volume_views = method_body(controls, "- (void) createVolumeViews")
require(
    "@property (nonatomic, strong) MPVolumeView* volumeView;" in controls_header
    and "@property (nonatomic, strong) ICVolumeView* routeButton;" in controls_header,
    "The MPVolumeView slider and AVRoutePickerView route control must remain separate.",
)
require(
    "ICVolumeView* routeButton" in create_volume_views
    and "routeButton.prioritizesVideoDevices = [PlaybackManager playbackManager].movingVideo;" in create_volume_views,
    "The public route picker must reflect the current media type when it is created.",
)
update_controls = method_body(controls, "- (void) updateControlsUI")
require(
    "self.routeButton.prioritizesVideoDevices = pman.movingVideo;" in update_controls,
    "The route picker must prioritize televisions only after the loaded asset proves it contains moving video.",
)
for forbidden in ("showsRouteButton", "showsVolumeSlider", "setRouteButtonImage"):
    require(forbidden not in create_volume_views, f"Deprecated MPVolumeView routing API remains: {forbidden}")
require(
    "CGRectMake(8, -17, 84, 84)" in create_volume_views
    and "self.routeButton.hidden = !(self.shown && !self.transcriptAvailable);" in controls,
    "Replacing the route picker must preserve player layout and transcript-control visibility.",
)

for signature in ("- (id) init", "- (void) resetSession"):
    configuration = method_body(audio_session, signature)
    require(
        "setCategory:AVAudioSessionCategoryPlayback" in configuration
        and "mode:AVAudioSessionModeDefault" in configuration
        and "routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongFormAudio" in configuration
        and "options:0" in configuration,
        f"{signature} must configure long-form AirPlay audio.",
    )
reset_session = method_body(audio_session, "- (void) resetSession")
require(
    "session.routeSharingPolicy == AVAudioSessionRouteSharingPolicyIndependent" in reset_session
    and reset_session.find("AVAudioSessionRouteSharingPolicyIndependent")
    < reset_session.find("setCategory:AVAudioSessionCategoryPlayback"),
    "Playback reset must preserve the Independent policy selected by iOS for video AirPlay.",
)
require(
    "setCategory:AVAudioSessionCategoryPlayback withOptions:0" not in audio_session,
    "The old category-only configuration must not overwrite the long-form route policy.",
)
require(
    "AVAudioSessionRouteSharingPolicyLongFormVideo" not in audio_session
    and "AVInitialRouteSharingPolicy" not in audio_session,
    "A podcast app must not reclassify itself globally as a primary long-form video app.",
)
require(
    "stopAirPlayVideo" not in player_controller
    and "stopAirPlayVideo" not in playback_header
    and "stopAirPlayVideo" not in playback,
    "Dismissing the player UI must not terminate active external video playback.",
)

require(
    "UIDocumentInteractionController" not in exports
    and "UIActivityViewController" in exports,
    "Backup, OPML, and bookmark exports must use the system share sheet (including AirDrop).",
)
require(
    "@property (nonatomic, strong) UIActivityViewController* activityViewController;" in exports,
    "The settings controller must retain its presented share sheet.",
)
present_export = method_body(exports, "- (void)_presentExportURL:")
require(
    "initWithActivityItems:@[url]" in present_export
    and "applicationActivities:nil" in present_export
    and "popoverPresentationController.sourceView = self.navigationController.view" in present_export
    and "popoverPresentationController.sourceRect = CGRectZero" in present_export,
    "Export sharing must preserve the existing navigation-view popover anchor.",
)
require(
    "completionWithItemsHandler" in present_export
    and "presentPendingFullExportResultIfNeeded" in present_export
    and "presentPendingSubscriptionsExportResultIfNeeded" in present_export
    and "presentPendingBookmarksExportResultIfNeeded" in present_export,
    "Dismissing a share sheet must continue presenting scene-owned pending export results.",
)
for signature in (
    "- (void)presentPendingFullExportResultIfNeeded",
    "- (void)presentPendingSubscriptionsExportResultIfNeeded",
    "- (void)presentPendingBookmarksExportResultIfNeeded",
):
    require("[self _presentExportURL:url];" in method_body(exports, signature), f"{signature} must open the system share sheet.")

require(
    "UIDocumentInteractionController" not in media_files
    and "@property (nonatomic, strong) UIActivityViewController* activityViewController;" in media_files,
    "Downloaded media must use and retain the system share sheet.",
)
media_selection = method_body(media_files, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
require(
    "initWithActivityItems:@[cacheURL]" in media_selection
    and "applicationActivities:nil" in media_selection
    and "popoverPresentationController.sourceView = self.tableView" in media_selection
    and "popoverPresentationController.sourceRect = cellRect" in media_selection,
    "Downloaded-media sharing must keep the tapped-cell popover anchor.",
)
require(
    "completionWithItemsHandler" in media_selection
    and "deselectRowAtIndexPath" in media_selection,
    "The selected download row must be deselected after the share sheet closes.",
)

print("iOS AirPlay and sharing regression checks passed")
