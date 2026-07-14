#!/usr/bin/env python3
"""Pins the mutable FTS4 zlib content-compression contract."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FTS = (ROOT / "Classes" / "Model" / "ICFTSController.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function or method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise AssertionError(f"Unterminated body: {signature}")


require(
    "#include <sqlite3.h>" in FTS and "#include <zlib.h>" in FTS,
    "The FTS compression hooks must use the platform SQLite and zlib implementations.",
)
compress = body(FTS, "static void ICFTSCompressValue(")
uncompress = body(FTS, "static void ICFTSUncompressValue(")
register = body(FTS, "static int ICFTSRegisterCompressionFunctions(")

require(
    "SQLITE_TEXT" in compress
    and "kICFTSCompressionMinimumLength" in compress
    and "compressBound" in compress
    and "compress2" in compress
    and "Z_DEFAULT_COMPRESSION" in compress
    and "sqlite3_result_blob" in compress
    and "sqlite3_result_text" in compress,
    "Compression must keep short/unhelpful values as TEXT and store only smaller zlib payloads as BLOBs.",
)
require(
    "kICFTSCompressedContentMagic" in compress
    and "kICFTSCompressedContentHeaderLength" in compress
    and "ICFTSWriteOriginalLength" in compress,
    "Compressed rows need a deterministic magic and original-length prefix.",
)
require(
    "SQLITE_TEXT" in uncompress
    and "sqlite3_result_value" in uncompress
    and "SQLITE_BLOB" in uncompress
    and "memcmp" in uncompress
    and "ICFTSReadOriginalLength" in uncompress
    and "SQLITE_LIMIT_LENGTH" in uncompress
    and "uncompress(" in uncompress
    and "uncompressedLength != originalLength" in uncompress
    and "sqlite3_result_text" in uncompress
    and "SQLITE_CORRUPT" in uncompress,
    "Uncompression must pass through TEXT but reject malformed/truncated BLOBs before returning exact TEXT.",
)
require(
    register.count("sqlite3_create_function_v2") == 2
    and '"ic_fts_compress"' in register
    and '"ic_fts_uncompress"' in register
    and register.count("SQLITE_DETERMINISTIC") >= 1,
    "Both deterministic scalar functions must be registered directly on each SQLite connection.",
)

open_index = body(FTS, "- (void) open")
require(
    open_index.find("ICFTSRegisterCompressionFunctions") < open_index.find("sqlite_master")
    and open_index.find("sqlite_master") < open_index.find("CREATE VIRTUAL TABLE"),
    "The live FMDatabase connection must register compression before inspecting or creating its schema.",
)
live_schema_statements = [
    line for line in open_index.splitlines() if "CREATE VIRTUAL TABLE" in line
]
require(
    len(live_schema_statements) == 2
    and all("compress=ic_fts_compress" in line for line in live_schema_statements)
    and all("uncompress=ic_fts_uncompress" in line for line in live_schema_statements),
    "Both live feeds and episodes schemas must enable FTS4 content compression.",
)
require(
    'stringForColumn:@"sql"' in open_index
    and "rangeOfString:@\"compress=ic_fts_compress\"" in open_index
    and "rangeOfString:@\"uncompress=ic_fts_uncompress\"" in open_index
    and "indexRequiresAuthoritativeRebuild = YES" in open_index
    and "_markIndexDirty:" in open_index,
    "Opening an ordinary pre-compression FTS schema must durably request an authoritative rebuild.",
)

rebuild = body(FTS, "- (void) rebuildIndexWithManagedObjectContext:")
temporary_open = rebuild.find("[database open]")
temporary_register = rebuild.find("ICFTSRegisterCompressionFunctions", temporary_open)
temporary_schema = rebuild.find("CREATE VIRTUAL TABLE", temporary_open)
require(
    temporary_open >= 0
    and temporary_open < temporary_register < temporary_schema
    and rebuild.count("compress=ic_fts_compress") == 2
    and rebuild.count("uncompress=ic_fts_uncompress") == 2,
    "The temporary rebuild connection must register hooks before creating both compressed schemas.",
)
replacement_queue = rebuild.find("FMDatabaseQueue* newQueue")
replacement_register = rebuild.find("ICFTSRegisterCompressionFunctions", replacement_queue)
replacement_publish = rebuild.find("self.queue = newQueue", replacement_queue)
require(
    replacement_queue >= 0
    and replacement_queue < replacement_register < replacement_publish,
    "The post-replacement FMDatabaseQueue must register hooks before becoming the live queue.",
)

require(
    "kFTSIndexVersion = 3" in DATABASE,
    "The compressed schema must advance FTS index version 2 to 3.",
)

print("FTS compressed-content source regression checks passed")
