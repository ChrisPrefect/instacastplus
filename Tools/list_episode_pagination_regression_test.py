#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


controller = read("Classes/ListEpisodesTableViewController.m")
list_header = read("Classes/Model/CDList.h")
list_base = read("Classes/Model/CDList.m")
episode_list = read("Classes/Model/CDEpisodeList.m")
playlist = read("Classes/Model/CDPlaylist.m")
smart_playlist = read("Classes/Model/CDSmartPlaylist.m")
episodes_base = read("Classes/EpisodesTableViewController.m")
cache_manager_header = read("Classes/CacheManager.h")


require("sortedEpisodesWithOffset:(NSUInteger)offset" in list_header and "error:(NSError**)error" in list_header,
        "CDList must expose a real, error-reporting offset/limit page API.")
for source, name in ((episode_list, "CDEpisodeList"),
                     (playlist, "CDPlaylist"),
                     (smart_playlist, "CDSmartPlaylist")):
    require("sortedEpisodesWithOffset:(NSUInteger)offset" in source and "error:(NSError**)error" in source,
            f"{name} must implement store-aware paging instead of the full-list fallback.")

base_page = method_body(list_base, "- (NSArray*) sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit error:")
require("subarrayWithRange" in base_page,
        "The compatibility implementation must honor both offset and limit.")

update = method_body(controller, "- (void) updateEpisodes")
load_page = method_body(controller, "- (void) _loadNextPage")
restore = method_body(controller, "- (void) _restoreScrollPositionIfNeeded")

require("allEpisodes" not in controller and "loadPages" not in controller,
        "The list controller must not retain a second fully materialized episode array.")
require("[list sortedEpisodes]" not in update,
        "Opening a list must never fetch every episode before displaying page one.")
require("sortedEpisodesWithOffset:offset" in load_page and "limit:EPISODE_PAGE_SIZE" in load_page,
        "Each UI page must be fetched directly from the list model.")
require("pageError" in load_page and "pageError" in controller,
        "A failed page fetch must remain retryable and must not be mistaken for list end.")
require("newBackgroundContext" in load_page and "dispatch_get_main_queue" in load_page,
        "Page fetches belong on a private Core Data context and only page results return to main.")
require("arrayByAddingObjectsFromArray" not in controller and "addObjectsFromArray" in load_page,
        "Appending pages must mutate one loaded array instead of copying all prior rows each time.")
require("while (" not in restore,
        "Deep scroll restoration must request pages asynchronously, never loop through pages on main.")

episode_list_page = method_body(episode_list, "- (NSArray*) sortedEpisodesWithOffset:")
require("fetchRequest.fetchOffset = offset" in episode_list_page,
        "Normal episode-list sorting must push the page offset into SQLite.")
require("fetchRequest.fetchLimit = limit" in episode_list_page,
        "Normal episode-list sorting must push the page limit into SQLite.")
require("objectHash" in episode_list_page,
        "Episode-list pages need a deterministic object-hash tie breaker/order reconstruction.")
require("offset == 0 && limit == 0" in episode_list_page,
        "A limited page must never poison the cached total episode count.")

playlist_page = method_body(playlist, "- (NSArray*) sortedEpisodesWithOffset:")
require("fetchOffset = offset" in playlist_page and "fetchLimit = limit" in playlist_page,
        "Manual playlists must page their PlaylistEpisode join rows in rank order.")
require("episode != nil" in playlist_page,
        "Orphaned playlist join rows must not create short pages or inflate offsets.")

smart_page = method_body(smart_playlist, "- (NSArray*) sortedEpisodesWithOffset:")
require("fetchOffset = offset" in smart_page,
        "Smart playlists must page their Core Data request rather than materialize all matches.")
require("intrinsicLimit" in smart_page,
        "Paging must preserve the intentional 25-item cap of recent smart lists.")
require("- (NSInteger)playbackTime" in smart_playlist,
        "Smart-list toolbar duration must use a background store query, not materialize every episode.")
require("self.sortedEpisodes" not in method_body(smart_playlist, "- (NSInteger)playbackTime"),
        "Smart-list statistics must not defeat pagination with a full managed-object fetch.")
require("cachedEpisodeObjectHashes" in cache_manager_header,
        "Background list fetches need a managed-object-free cache membership snapshot.")
require("cachedEpisodes" not in method_body(episode_list, "- (NSPredicate*) _episodesMainPredicate"),
        "CDEpisodeList must not read main-context cached episode objects from its background context.")
require("feed IN %@" in method_body(episode_list, "- (NSPredicate*) _episodesMainPredicate"),
        "Large included-podcast filters must use one SQL IN predicate, not an OR node per podcast.")
require("cachedEpisodes" not in smart_page,
        "Downloaded smart-list pages must refetch cached hashes in their own Core Data context.")

require("loadEpisodeObjectIDsForBulkActionWithCompletion" in episodes_base,
        "Bulk mutations need an overridable asynchronous object-ID source.")
for signature in ("- (void) _setAllAsConsumed:",
                  "- (void) _archiveAllPlayed",
                  "- (void) _clearCacheOfAllPlayed"):
    bulk_action = method_body(episodes_base, signature)
    require("loadEpisodeObjectIDsForBulkActionWithCompletion" in bulk_action,
            f"{signature} must operate on the complete paged list, not just loaded rows.")
    require("enumerateEpisodesUsingBlock" not in bulk_action,
            f"{signature} must not silently stop after the currently loaded page.")
require("loadEpisodeObjectIDsForBulkActionWithCompletion" in controller,
        "A paged list must load all list IDs only after an explicit bulk action.")
require("All Loaded" in controller,
        "The edit-mode selection label must say when it only selects materialized rows.")
bulk_loader = method_body(controller, "- (void) loadEpisodeObjectIDsForBulkActionWithCompletion:")
require("sortedEpisodesWithOffset:offset" in bulk_loader and "dispatch_get_global_queue" in bulk_loader,
        "List-wide bulk IDs must be collected page-by-page off the main thread.")

print("List episode pagination regression checks passed")
