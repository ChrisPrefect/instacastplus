#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "CDEpisodeList.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require(
    "- (void) calculateNumberOfEpisodesCompletion:" in SOURCE,
    "CDEpisodeList count calculation method is missing.",
)

count_method = SOURCE.split("- (void) calculateNumberOfEpisodesCompletion:", 1)[1].split("- (void) invalidateCaches", 1)[0]
require(
    "[self.episodes count]" not in count_method,
    "Episode list count calculation must not fault the main-context episodes relationship; this crashes during launch when the relationship is invalidated.",
)
require(
    "[self.episodes count]" not in SOURCE and "[self.episodes array]" not in SOURCE,
    "Episode lists must not directly fault the episodes relationship on startup paths.",
)
require(
    "explicitEpisodeRelationshipCountInContext:" in SOURCE
    and "episodeList:" in SOURCE
    and "episodeLists CONTAINS %@" in SOURCE,
    "Explicit episode-list membership must be counted with a Core Data fetch instead of faulting the relationship set.",
)
require(
    "explicitEpisodeRelationshipObjectsWithFetchLimit:" in SOURCE,
    "Explicit episode-list membership must be fetched without faulting the relationship set.",
)
require(
    "NSManagedObjectContext* mainContext = self.managedObjectContext;" in count_method,
    "Async episode-list counts must capture the main context before background work starts instead of using a stale managed object later.",
)
require(
    "existingObjectWithID:selfId error:" in count_method,
    "Async episode-list count completion must re-fetch the main-context EpisodeList by objectID before updating cached count.",
)
require(
    "calculatedList.cachedEpisodesCount" in count_method,
    "Async episode-list count completion must update the validated main-context EpisodeList, not the originally captured self.",
)
for callback in count_method.split("dispatch_async(dispatch_get_main_queue(), ^{")[1:]:
    body = callback.split("});", 1)[0]
    require(
        "self.cachedEpisodesCount" not in body,
        "Main-queue count callbacks must not write to captured self; it can be an inaccessible Core Data fault by callback time.",
    )
