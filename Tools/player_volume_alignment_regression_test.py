#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


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
    raise SystemExit(f"Unterminated method body: {signature}")


controls = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()
english = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
german = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
create_volume_views = objc_method(controls, "- (void) createVolumeViews")
align_volume_slider = objc_method(controls, "- (void) _alignVolumeSliderTrack")
layout = objc_method(controls, "- (void)viewDidLayoutSubviews")
update_appearance = objc_method(controls, "- (void) updateAppearance")


require(
    "volumeViewYOffset" not in create_volume_views
    and "UIUserInterfaceIdiomPad" not in create_volume_views,
    "The volume track must not depend on a device-specific vertical magic offset.",
)
require(
    "[slider trackRectForBounds:slider.bounds]" in align_volume_slider
    and "[self.view convertRect:trackRect fromView:slider]" in align_volume_slider,
    "Volume alignment must use the rendered UISlider track geometry in player coordinates.",
)
require(
    "self.volumeMinButton.imageView.bounds" in align_volume_slider
    and "fromView:self.volumeMinButton.imageView" in align_volume_slider
    and "self.volumeMaxButton.imageView.bounds" in align_volume_slider
    and "fromView:self.volumeMaxButton.imageView" in align_volume_slider,
    "Volume alignment must derive its target from the rendered speaker images, not their button frames.",
)
require(
    "CGFloat offset = iconCenterY - CGRectGetMidY(trackRectInPlayer);" in align_volume_slider
    and "iconCenterY +" not in align_volume_slider,
    "The volume track must align directly to the rendered speaker center without a cumulative magic offset.",
)
require(
    "CGFloat trackHeight = 4.f;" in update_appearance
    and "setMinimumVolumeSliderImage" not in update_appearance
    and "setMaximumVolumeSliderImage" in update_appearance,
    "The volume track must retain its measured 4-point system thickness.",
)
require(
    "CGRectGetMidY(trackRectInPlayer)" in align_volume_slider
    and "CGRectOffset(self.volumeHitView.frame" in align_volume_slider
    and "CGRectOffset(self.volumeView.frame" not in align_volume_slider,
    "The rendered track and its touch area must move together via their owning container.",
)
require(
    "[self _alignVolumeSliderTrack]" in layout,
    "The volume track must be realigned after UIKit finishes laying out the player.",
)
require(
    "self.volumeMinButton.enabled = YES" in controls
    and "self.volumeMaxButton.enabled = YES" in controls
    and "@selector(_decreaseVolume:)" in controls
    and "@selector(_increaseVolume:)" in controls,
    "Both 44-point speaker buttons must be interactive.",
)
require(
    "1.f / 16.f" in controls
    and "[slider sendActionsForControlEvents:UIControlEventValueChanged]" in controls
    and "PlayHapticFeedback(ICHapticFeedbackLight)" in controls,
    "Speaker taps must change system volume by one standard step with light haptics.",
)
require(
    'self.volumeMinButton.accessibilityLabel = @"Decrease Volume".ls' in controls
    and 'self.volumeMaxButton.accessibilityLabel = @"Increase Volume".ls' in controls
    and '"Decrease Volume" = "Decrease Volume";' in english
    and '"Increase Volume" = "Increase Volume";' in english
    and '"Decrease Volume" = "Lautstärke verringern";' in german
    and '"Increase Volume" = "Lautstärke erhöhen";' in german,
    "Interactive speaker buttons need localized VoiceOver labels.",
)

print("Player volume alignment regression checks passed.")
