#!/usr/bin/env python3
"""Pins Siri media donations to accepted, direct in-app playback starts."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


playback_header = read("Classes/PlaybackViewController.h")
playback = read("Classes/PlaybackViewController.m")

require(
    "playbackViewControllerWithUserInitiatedEpisode:" in playback_header,
    "Playback UI needs an explicit direct-user factory; automatic starts must remain the default.",
)
for token in [
    "#import <Intents/Intents.h>",
    "INMediaItemTypePodcastEpisode",
    "INMediaItemTypePodcastShow",
    "INPlayMediaIntent",
    "INInteraction",
    "donateInteractionWithCompletion:",
    "donatesUserInitiatedPlayback",
    "[audioSession.episode isEqual:self.episode]",
    "autostart",
]:
    require(token in playback, f"Direct media donation is missing required behavior: {token}")

donation = playback.split("+ (void) donateUserInitiatedPlaybackOfEpisode:", 1)[1].split("+ (PlaybackViewController*) playbackViewController", 1)[0]
require(
    "playbackSpeed:nil" in donation
    and "playbackSpeed:@([PlaybackManager playbackManager].playbackRate)" not in donation,
    "A pure play donation must not persist the previous episode's playback speed.",
)
require(
    "NSString* episodeHash = [episode.objectHash copy];" in donation,
    "Donation callbacks need an immutable episode hash copied on the Core Data context thread.",
)
donation_completion = donation.split("donateInteractionWithCompletion:", 1)[1]
require(
    "episode.objectHash" not in donation_completion and "episodeHash" in donation_completion,
    "The asynchronous donation callback must not dereference CDEpisode off its Core Data queue.",
)

play_call = "[audioSession playEpisode:self.episode"
donation_call = "donateUserInitiatedPlaybackOfEpisode:self.episode"
require(
    play_call in playback and donation_call in playback,
    "Accepted direct playback must donate the selected episode.",
)
require(
    playback.find(play_call) < playback.find(donation_call),
    "Donation must happen only after AudioSession accepted the playback start.",
)
presentation = playback.split("- (void) _presentFromParentViewController:", 1)[1]
require(
    "requestedDifferentEpisode" not in presentation
    and presentation.find("else if (autostart)") < presentation.find(donation_call),
    "A direct user resume of the already loaded episode must donate the accepted play interaction too.",
)

direct_entry_files = [
    "Classes/EpisodesTableViewController.m",
    "Classes/EpisodeViewController.m",
    "Classes/UpNextTableViewController.m",
    "Classes/BookmarksTableViewController.m",
    "Classes/DirectoryFeedViewController.m",
    "Classes/TranscriptionQueueViewController.m",
    "Classes/AppleWatchEpisodesViewController.m",
    "Classes/DonationViewController.m",
]
for path in direct_entry_files:
    require(
        "playbackViewControllerWithUserInitiatedEpisode:" in read(path),
        f"Direct episode playback must opt in to Siri donation: {path}",
    )

require(
    "[audioSession.episode isEqual:episode]" in read("Classes/PlayerInfoViewController_v5.m")
    and "donateUserInitiatedPlaybackOfEpisode:episode" in read("Classes/PlayerInfoViewController_v5.m"),
    "Selecting a different Up Next episode inside the player must donate that direct user start.",
)

for path in [
    "Classes/AudioSession.m",
    "Classes/PlaybackManager.m",
    "Classes/AppIntents/ICIntentBridge.swift",
    "Classes/WidgetDataExporter.m",
    "Classes/InstacastSceneDelegate.m",
]:
    source = read(path)
    require(
        "donateInteractionWithCompletion:" not in source
        and "donateUserInitiatedPlaybackOfEpisode:" not in source,
        f"Automatic/remote/restore playback must never create a direct-user media donation: {path}",
    )

print("Siri media donation regression checks passed.")
