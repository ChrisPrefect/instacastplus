from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    next_method = source.find("\n- (", start + len(signature))
    return source[start:] if next_method == -1 else source[start:next_method]


def method_body_any(source: str, signatures: list[str]) -> str:
    for signature in signatures:
        if signature in source:
            return method_body(source, signature)
    raise SystemExit(f"Missing method: {' or '.join(signatures)}")


source = (ROOT / "Classes" / "FeedEpisodesTableViewController.m").read_text()
episodes_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
en_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
model_source = (
    ROOT
    / "Resources"
    / "Models"
    / "Model4.xcdatamodeld"
    / "Model.xcdatamodel"
    / "contents"
).read_text()

update_episodes = method_body(source, "- (void) updateEpisodes")
downloaded_update = method_body_any(
    source,
    ["- (void) downloadedUpdateEpisodes", "-(void) downloadedUpdateEpisodes"],
)
view_did_load = method_body(source, "- (void)viewDidLoad")
dealloc = method_body(source, "- (void) dealloc")
empty_state = method_body(source, "- (void)_updateFilterEmptyState")
reload_with_filter = method_body(source, "- (void) reloadDataWithFilter:")
controller_did_change = method_body(
    source,
    "- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller",
)

require(
    'attribute name="downloaded" optional="YES" transient="YES"' in model_source,
    "Episode.downloaded is no longer transient; revisit the feed download-filter regression.",
)
require(
    "downloaded ==" not in downloaded_update,
    "The feed download filter must not execute a store fetch against transient Episode.downloaded.",
)
require(
    "cachedEpisodeObjectHashes" in downloaded_update
    and "objectHash IN" in downloaded_update,
    "The feed download filter must use the authoritative cache hash index.",
)
require(
    "NSFetchedResultsController" in downloaded_update
    and "self.fetchController.delegate = self;" in downloaded_update
    and "performFetch" in downloaded_update,
    "The downloaded result set needs its own fetched-results controller so table updates and rows share one source of truth.",
)
require(
    "self.episodes = [self.fetchController fetchedObjects]" in update_episodes
    and "isDownloadedFilter" not in update_episodes,
    "Every feed filter, including Downloaded, must derive its displayed rows from the active fetched-results controller.",
)
require(
    'forKeyPath:@"cachedEpisodes"' in view_did_load
    and "isDownloadedFilter" in view_did_load
    and "downloadedUpdateEpisodes" in view_did_load,
    "The visible Downloaded filter must rebuild when the cache index changes.",
)
require(
    'removeTaskObserver:self forKeyPath:@"cachedEpisodes"' in dealloc,
    "The feed controller must remove its cache-index observer during deallocation.",
)
require(
    'isEqualToString:@"All"' in empty_state
    and "self.searchTerm.length == 0" in empty_state
    and "self.episodes.count == 0" in empty_state
    and '"Keine Folgen mit diesem Filter".ls' in empty_state,
    "An empty active podcast filter must show the requested message while All and search results remain unchanged.",
)
require(
    "NSTextAlignmentCenter" in empty_state
    and "ICMutedTextColor" in empty_state
    and "self.tableView.backgroundView" in empty_state,
    "The filtered-empty message must be a centered table background view using the app appearance.",
)
require(
    "[self _updateFilterEmptyState]" in reload_with_filter
    and "[self _updateFilterEmptyState]" in controller_did_change
    and "[self _updateFilterEmptyState]" in downloaded_update,
    "The filtered-empty message must follow filter selection, fetched-result changes, and download-cache changes.",
)
for strings, language, value in (
    (de_strings, "German", "Keine Folgen mit diesem Filter"),
    (en_strings, "English", "No Episodes with This Filter"),
):
    require(
        f'"Keine Folgen mit diesem Filter" = "{value}";' in strings,
        f"{language} localization is missing the filtered-empty message.",
    )

remove_after_mutation = method_body(
    source,
    "- (BOOL) _removeEpisodeFromDisplayedListIfNeededAfterMutation:(CDEpisode*)episode atIndexPath:(NSIndexPath*)indexPath",
)
require(
    "self.fetchController.fetchRequest.predicate" in remove_after_mutation
    and "evaluateWithObject:episode" in remove_after_mutation,
    "A mutation must evaluate membership against the active feed filter.",
)
require(
    "self.episodes =" in remove_after_mutation
    and "deleteRowsAtIndexPaths:@[indexPath]" in remove_after_mutation
    and "return YES;" in remove_after_mutation,
    "When an episode stops matching Favorites/Unplayed/etc., update the data source and remove exactly that visible row.",
)

context_menu = method_body(
    episodes_source,
    "- (UIMenu *) _contextMenuForIndexPath:(NSIndexPath *)indexPath",
)
require(
    "[DMANAGER markEpisode:episode asConsumed:flag];" in context_menu
    and "_removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:currentIndexPath" in context_menu,
    "Played/Unplayed changes from the context menu must immediately remove episodes that no longer match the active feed filter.",
)
require(
    "strongSelf.suppressNextListReload = YES;" in context_menu
    and context_menu.find("strongSelf.suppressNextListReload = YES;")
    < context_menu.find("[DMANAGER markEpisode:episode asConsumed:flag];"),
    "The context-menu mutation must arm the list-reload suppression before DatabaseManager schedules its delayed count invalidation.",
)
