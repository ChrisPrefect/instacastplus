#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


defines_h = (ROOT / "Classes" / "Defines.h").read_text()
defines_m = (ROOT / "Classes" / "Defines.m").read_text()
notification_settings = (ROOT / "Classes" / "NotificationSettingsViewController.m").read_text()
playback_controls = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()
defaults = (ROOT / "Resources" / "Defaults.plist").read_text()
ipad_defaults = (ROOT / "Resources-iPad" / "Defaults.plist").read_text()
settings_bundle_notifications = (ROOT / "Resources-iPad" / "Settings.bundle" / "Notifications.plist").read_text()


require(
    "EnableRefreshFailureNotification" in defines_h
    and 'NSString* EnableRefreshFailureNotification = @"EnableRefreshFailureNotification";' in defines_m,
    "Refresh-failure notification setting must have a shared defaults key.",
)
require(
    "<key>EnableRefreshFailureNotification</key>\n\t<false/>" in defaults
    and "<key>EnableRefreshFailureNotification</key>\n\t<false/>" in ipad_defaults,
    "Refresh-failure notification setting must default to off on iPhone and iPad.",
)
require(
    "Podcast update failed." in notification_settings
    and "[USER_DEFAULTS boolForKey:EnableRefreshFailureNotification]" in notification_settings
    and "[USER_DEFAULTS setBool:sender.on forKey:EnableRefreshFailureNotification]" in notification_settings,
    "Notifications settings must expose the refresh-failure alert toggle at the top.",
)
require(
    notification_settings.index("Podcast update failed.") < notification_settings.index("Application Badge"),
    "Refresh-failure alert toggle must be above the application badge row.",
)
require(
    "<string>Podcast Updates Failed</string>" in settings_bundle_notifications
    and "<string>EnableRefreshFailureNotification</string>" in settings_bundle_notifications
    and "<false/>" in settings_bundle_notifications.split("<string>EnableRefreshFailureNotification</string>", 1)[1].split("</dict>", 1)[0],
    "iPad Settings.bundle must expose the refresh-failure notification toggle with default off.",
)

for relative_path in [
    "Classes/ListEpisodesTableViewController.m",
    "Classes/FeedEpisodesTableViewController.m",
    "Classes/PlaylistsTableViewController.m",
    "Classes/SubscriptionsTableViewController.m",
]:
    source = (ROOT / relative_path).read_text()
    alert_body = source.split("- (void) _presentRefreshFailureAlert:(NSArray<NSString*>*)failures", 1)[1]
    alert_body = alert_body.split("UIAlertController* alert", 1)[0]
    require(
        "[USER_DEFAULTS boolForKey:EnableRefreshFailureNotification]" in alert_body,
        f"{relative_path} must gate the modal refresh-failure alert behind the new setting.",
    )

require(
    'ICVolumeView* routeButton = [[ICVolumeView alloc]' in playback_controls
    and 'routeButton.prioritizesVideoDevices = [PlaybackManager playbackManager].movingVideo;' in playback_controls
    and 'self.routeButton.prioritizesVideoDevices = pman.movingVideo;' in playback_controls
    and 'setRouteButtonImage:' not in playback_controls,
    "AirPlay routing must use the public AVRoutePickerView and prioritize devices for the loaded media type.",
)
set_tint_body = playback_controls.split("- (void) setTintColor:(UIColor *)tintColor", 1)[1].split("\n}", 1)[0]
require(
    "self.routeButton.tintColor = tintColor;" in set_tint_body
    and "self.routeButton.activeTintColor = tintColor;" in set_tint_body,
    "PlaybackControlsViewController must pass player tint changes directly to the public route picker.",
)
