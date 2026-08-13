#!/usr/bin/env python3
"""Source-aware regression checks for the iPhone player control icons."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROLS = (ROOT / "Classes/PlaybackControlsViewController.m").read_text()
SPEED = (ROOT / "Classes/PlayerSpeedButton.m").read_text()
TIMER = (ROOT / "Classes/PlayerTimerButton.m").read_text()
IMAGE_FUNCTIONS = (ROOT / "Classes/ImageFunctions.m").read_text()
XIB = (ROOT / "Resources-iPhone/Nibs/PlayerControlView.xib").read_text()


def require(source: str, snippet: str, description: str) -> None:
    assert snippet in source, f"Missing {description}: {snippet}"


require(CONTROLS, '@"airplayaudio"', "AirPlay SF Symbol")
require(CONTROLS, '@"bookmark"', "bookmark SF Symbol")
require(SPEED, '@"gauge.with.dots.needle.50percent"', "normal-speed SF Symbol")
require(TIMER, '@"moon.zzz"', "sleep-timer SF Symbol")

require(CONTROLS, 'ICPlayerToolSymbol(@"airplayaudio", 26.f)', "26-point AirPlay symbol")
require(CONTROLS, 'ICPlayerToolSymbol(@"bookmark", 25.f)', "25-point bookmark symbol")
require(SPEED, "configurationWithPointSize:28.5f", "28.5-point speed symbol")
require(SPEED, "CGFloat size = 28.5f", "28.5-point speed image rect")
require(TIMER, "configurationWithPointSize:28.f", "28-point sleep-timer symbol")
require(TIMER, "CGFloat size = 28.f", "28-point sleep-timer image rect")
for source, description in ((CONTROLS, "player controls"), (SPEED, "speed control"), (TIMER, "timer control")):
    require(source, "weight:UIImageSymbolWeightRegular", f"regular symbol weight in {description}")

require(SPEED, "PlaybackSpeedControlNormalSpeed", "normal-speed state branch")
require(SPEED, "[self setTitle:nil forState:UIControlStateNormal]", "icon-only 1x state")
require(SPEED, '@"Player Speed Fill"', "legacy non-1x speed box")
require(SPEED, "titleForSpeedControl", "non-1x speed value")

require(CONTROLS, "ICPlayerTransportImageScale = 1.2f", "20-percent-larger play/pause glyph")
require(CONTROLS, "ICPlayerSkipPointSize = 40.8f", "20-percent-larger seek glyph")
require(CONTROLS, "ICPlayerVolumeImageScale = 1.3f", "30-percent-larger volume glyphs")
require(
    CONTROLS,
    'ICPlayerScaledTemplateImage(@"Player Volume Min", ICPlayerVolumeImageScale)',
    "30-percent-larger minimum-volume glyph",
)
require(
    CONTROLS,
    'ICPlayerScaledTemplateImage(@"Player Volume Max", ICPlayerVolumeImageScale)',
    "30-percent-larger maximum-volume glyph",
)
require(CONTROLS, "UIEdgeInsetsMake(0.f, 26.5f, 0.f, -26.5f)", "backward glyph inward shift")
require(CONTROLS, "UIEdgeInsetsMake(0.f, -26.5f, 0.f, 26.5f)", "forward glyph inward shift")
require(CONTROLS, "CGFloat smallSize = 84;", "large AirPlay and bookmark hit targets")
require(CONTROLS, "CGFloat bigSize = 101;", "large speed and timer hit targets")
require(
    IMAGE_FUNCTIONS,
    "ceilf((sizeValue - textSize.height) * 0.5f) + 0.5f",
    "half-point downward optical alignment for seek numbers",
)
require(IMAGE_FUNCTIONS, "CTLineGetImageBounds", "visible seek-number glyph bounds")
require(
    IMAGE_FUNCTIONS,
    "sizeValue * 0.5f - CGRectGetMidX(glyphBounds)",
    "dynamic optical centering for every seek-number value",
)
assert "seconds == 10" not in IMAGE_FUNCTIONS, "Seek-number centering must not special-case 10."

# The XIB frames remain the generous hit targets while only the glyphs move/scale.
require(XIB, 'id="14" userLabel="Back Button"', "back button")
require(XIB, 'x="5" y="12" width="100" height="60"', "100x60 back hit target")
require(XIB, 'id="13" userLabel="Play Button"', "play button")
require(XIB, 'x="110" y="2" width="100" height="80"', "100x80 play hit target")
require(XIB, 'id="15" userLabel="Forward Button"', "forward button")
require(XIB, 'x="215" y="12" width="100" height="60"', "100x60 forward hit target")

print("player control icon regression checks passed")
