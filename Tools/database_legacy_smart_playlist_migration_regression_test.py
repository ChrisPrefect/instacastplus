#!/usr/bin/env python3
"""Pins the legacy CDList migration to real managed objects, keyed by uid."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = DATABASE.find("- (void) _migrateOldSmartPlaylists")
end = DATABASE.find("+ (NSString *)normalizedFeedURLStringForURLString:", start)
require(start != -1 and end != -1, "Legacy smart-playlist migration boundary is missing.")
migration = DATABASE[start:end]

# The migration deduplicates by uid, but the values sent through the type-dispatch loop must
# remain CDList objects. Storing only NSString uids makes every isKindOfClass check unreachable.
require("NSMutableDictionary<NSString*, CDList*>* uniqueRecords" in migration,
        "Legacy list deduplication must retain typed CDList values keyed by uid.")
uid_guard = migration.find("object.uid.length > 0")
object_store = migration.find("uniqueRecords[object.uid] = object")
value_list = migration.find("uniqueRecords.allValues")
typed_loop = migration.find("for(CDList* list in lists)")
require(-1 not in (uid_guard, object_store, value_list, typed_loop)
        and uid_guard < object_store < value_list < typed_loop,
        "The migration must guard the uid, retain the managed object, then dispatch over dictionary values.")
require("[uniqueRecords addObject:object.uid]" not in migration,
        "A uid string must never enter the CDList type-dispatch collection.")

# CDPlaylist is still the live model behind user-created playlists. The old deletion branch was
# unreachable while the collection contained NSString uids; making the type dispatch work must
# not activate that latent data-loss path.
require("[list isKindOfClass:[CDPlaylist class]]" not in migration,
        "Legacy smart-list migration must preserve supported user-created CDPlaylist objects.")

print("Legacy smart-playlist migration regression checks passed")
