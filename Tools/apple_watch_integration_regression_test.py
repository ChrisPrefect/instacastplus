from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


watch_plist_values = plistlib.loads((ROOT / "InstacastWatch" / "Info.plist").read_bytes())
require(
    watch_plist_values.get("WKApplication") is True
    and "WKWatchKitApp" not in watch_plist_values,
    "The executable Watch app Info.plist must use WKApplication without the legacy WKWatchKitApp key.",
)
require(
    "audio" in watch_plist_values.get("UIBackgroundModes", []),
    "The executable Watch app must declare UIBackgroundModes/audio; App Store Connect rejects WKBackgroundModes/audio for Watch audio.",
)

print("Watch executable bundle metadata checks passed")
