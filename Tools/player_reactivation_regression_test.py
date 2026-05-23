#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


scene_delegate = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()

widget_deeplink = scene_delegate.split("- (void)_handleWidgetDeepLink:(NSURL *)url", 1)[1]
widget_deeplink = widget_deeplink.split("else if ([host isEqualToString:@\"episode\"])", 1)[0]
open_player_without_action = widget_deeplink.split("if (!action && [PlaybackManager playbackManager].playingEpisode)", 1)[1]
open_player_without_action = open_player_without_action.split("}", 1)[0]

require(
    "presentFromParentViewController:self.mainViewController autostart:NO completion:NULL" in open_player_without_action,
    "Opening the player from a widget/player deeplink must not autostart playback when no explicit play action was requested.",
)
require(
    "playpause" in widget_deeplink and "[pm playPause];" in widget_deeplink,
    "Widget play/pause controls should remain the path that changes playback state.",
)
