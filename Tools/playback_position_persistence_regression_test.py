from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


source = (ROOT / "Classes" / "PlaybackManager.m").read_text()


require(
    "@property (nonatomic, strong) id temporaryPositionObserver;" in source,
    "PlaybackManager should keep a dedicated temporary-position observer token.",
)
require(
    "@property (nonatomic, strong) id savedPositionObserver;" in source,
    "PlaybackManager should keep a dedicated durable-position observer token.",
)
require(
    "CMTimeMakeWithSeconds(5,25000) queue:NULL usingBlock:^(CMTime time) {\n        if (weakSelf.ready) {\n            [weakSelf _temporarySavePosition];" in source,
    "Temporary playback positions should be written every 5 seconds.",
)
require(
    "CMTimeMakeWithSeconds(30,25000) queue:NULL usingBlock:^(CMTime time) {\n        if (weakSelf.ready && !weakSelf.paused) {\n            [weakSelf _saveCurrentPlaybackPosition];" in source,
    "Durable playback positions should be saved every 30 seconds while playback is active.",
)
require(
    "if (self.temporaryPositionObserver) {\n            [self.player removeTimeObserver:self.temporaryPositionObserver];" in source
    and "if (self.savedPositionObserver) {\n            [self.player removeTimeObserver:self.savedPositionObserver];" in source,
    "Both playback position observers must be removed when the player closes.",
)
