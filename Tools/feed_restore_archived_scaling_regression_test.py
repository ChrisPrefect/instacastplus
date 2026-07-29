#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "FeedSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


rows = method_body("numberOfRowsInSection:")
count = method_body("- (void)_reloadArchivedEpisodeCount")
restore = method_body("-(void)restoreDeletedEpisodes")
view_did_appear = method_body("- (void)viewDidAppear:")

require(
    "countForFetchRequest" not in rows
    and "archivedEpisodeCount" in rows,
    "UITableView row counting must use a prepared archived-count snapshot, never synchronous SQL.",
)
require(
    "newBackgroundContext" in count
    and "countForFetchRequest" in count
    and "NSNotFound" in count
    and "archivedEpisodeCountError" in count,
    "Archived-count loading must run off-main and preserve count failures as an explicit UI state.",
)
require(
    "newBackgroundContext" in restore
    and "NSManagedObjectIDResultType" in restore
    and "ICRestoreArchivedEpisodeBatchSize" in restore
    and "save:&batchError" in restore
    and "mergeChangesFromRemoteContextSave" in restore
    and "restoreInfo.progress" in restore,
    "Mass restore must save bounded background batches, merge object IDs, and show progress.",
)
require(
    "context = DMANAGER.objectContext" not in restore
    and "setEpisode:" not in restore,
    "Mass restore must not materialize or mutate every archived episode on the main context.",
)
require(
    "[self.tableView reloadData]" in view_did_appear
    and "_reloadArchivedEpisodeCount" in view_did_appear
    and view_did_appear.index("[self.tableView reloadData]")
    < view_did_appear.index("_reloadArchivedEpisodeCount"),
    "Archived-count refresh must follow the full table synchronization after feed settings appear.",
)


print("Feed archived-episode restore scaling regression checks passed")
