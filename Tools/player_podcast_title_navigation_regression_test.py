#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


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


player_controller = read("Classes/PlayerController.m")
main_controller = read("Classes/MainViewController_4.m")
main_header = read("Classes/MainViewController_4.h")

open_from_title = objc_method(player_controller, "- (void) _openCurrentPodcastFromPlayerTitle")
require(
    "showEpisodeListOfEpisode:episode animated:NO" in open_from_title,
    "Tapping the podcast title in the player must open the podcast episode list, not the show-notes restore path.",
)
require(
    "showShowNotesOfEpisode:episode" not in open_from_title,
    "Player podcast-title navigation must not seed DefaultEpisodesSelectedEpisodeUID through showShowNotesOfEpisode:.",
)

require(
    "- (void) showEpisodeListOfEpisode:(CDEpisode*)episode animated:(BOOL)animated;" in main_header,
    "MainViewController_4 must expose a dedicated episode-list navigation entry point for the player.",
)
require(
    '#import "FeedEpisodesTableViewController.h"' in main_controller,
    "MainViewController_4 must build the feed episode controller directly for player title navigation.",
)

show_episode_list = objc_method(main_controller, "- (void) showEpisodeListOfEpisode:(CDEpisode*)episode animated:(BOOL)animated")
require(
    "FeedEpisodesTableViewController* episodesController = [FeedEpisodesTableViewController episodesControllerWithFeed:episode.feed];" in show_episode_list,
    "Player title navigation must create the target feed episode list directly.",
)
require(
    "navController.viewControllers = @[ controller, episodesController ];" in show_episode_list
    and show_episode_list.index("navController.viewControllers = @[ controller, episodesController ];")
    < show_episode_list.index("self.contentViewController ="),
    "The subscriptions navigation stack must contain the episode list before it is shown, avoiding a visible subscriptions-list intermediate state.",
)
require(
    "setObject:episode.uid forKey:kDefaultEpisodesSelectedEpisodeUID" not in show_episode_list,
    "Opening the podcast list from the player must not request show-notes restoration for the current episode.",
)
require(
    "removeObjectForKey:kDefaultEpisodesSelectedEpisodeUID" in show_episode_list,
    "Player title navigation must clear stale show-notes restoration state before showing the episode list.",
)
require(
    "removeObjectForKey:kUIPersistenceSubscriptionsSelectedFeedUID" in show_episode_list,
    "Direct player navigation must clear stale subscription auto-push state so backing out does not re-push or alter scroll position.",
)

show_show_notes = objc_method(main_controller, "- (void) showShowNotesOfEpisode:(CDEpisode*)episode animated:(BOOL)animated")
require(
    "setObject:episode.uid forKey:kDefaultEpisodesSelectedEpisodeUID" in show_show_notes,
    "Existing deep-link/notification show-notes navigation should still seed the selected episode UID.",
)

print("Player podcast title navigation regression checks passed.")
