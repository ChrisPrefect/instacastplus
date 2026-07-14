#!/usr/bin/env python3
"""Compiles the production FTS callbacks and proves size plus mutable FTS4 behavior."""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FTS = (ROOT / "Classes" / "Model" / "ICFTSController.m").read_text()
START = "static const unsigned char kICFTSCompressedContentMagic"
END = "static NSString* ICFTSString"

if START not in FTS or END not in FTS:
    raise AssertionError("Production FTS compression callbacks are missing")
IMPLEMENTATION = FTS[FTS.index(START):FTS.index(END, FTS.index(START))]

HARNESS = r'''
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sqlite3.h>
#include <zlib.h>

__IMPLEMENTATION__

enum { kEpisodeCount = 4500, kTranscriptLength = 112 * 1024 };

static void fail(sqlite3 *database, const char *operation, int result)
{
    fprintf(stderr, "%s failed (%d): %s\n", operation, result,
            database ? sqlite3_errmsg(database) : "no database");
    exit(1);
}

static void execute(sqlite3 *database, const char *sql)
{
    char *message = NULL;
    int result = sqlite3_exec(database, sql, NULL, NULL, &message);
    if (result != SQLITE_OK) {
        fprintf(stderr, "%s failed (%d): %s\n", sql, result,
                message ? message : sqlite3_errmsg(database));
        sqlite3_free(message);
        exit(1);
    }
}

static void make_transcript(char *buffer, int episode)
{
    static const char paragraph[] =
        "Host: Welcome to this weekly podcast conversation about technology, culture, "
        "science, design, music, and everyday life. Guest: We explain the background, "
        "compare practical examples, and answer the questions listeners sent this week. ";
    int prefix = snprintf(buffer, kTranscriptLength + 1,
                          "uniqueterm%04d episode%04d. ", episode, episode);
    size_t paragraphLength = strlen(paragraph);
    for (int offset = prefix; offset < kTranscriptLength;) {
        int remaining = kTranscriptLength - offset;
        int amount = remaining < (int)paragraphLength ? remaining : (int)paragraphLength;
        memcpy(buffer + offset, paragraph, (size_t)amount);
        offset += amount;
    }
    buffer[kTranscriptLength] = '\0';
}

static int scalar_int(sqlite3 *database, const char *sql)
{
    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v2(database, sql, -1, &statement, NULL);
    if (result != SQLITE_OK) fail(database, "prepare scalar", result);
    result = sqlite3_step(statement);
    if (result != SQLITE_ROW) fail(database, "step scalar", result);
    int value = sqlite3_column_int(statement, 0);
    sqlite3_finalize(statement);
    return value;
}

static void verify_unchanged_text(sqlite3 *database, const char *value, int length)
{
    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v2(database,
        "SELECT typeof(ic_fts_compress(?1)), ic_fts_uncompress(ic_fts_compress(?1))",
        -1, &statement, NULL);
    if (result != SQLITE_OK) fail(database, "prepare unchanged text", result);
    sqlite3_bind_text(statement, 1, value, length, SQLITE_TRANSIENT);
    result = sqlite3_step(statement);
    if (result != SQLITE_ROW) fail(database, "step unchanged text", result);
    const char *storageType = (const char *)sqlite3_column_text(statement, 0);
    const char *roundTrip = (const char *)sqlite3_column_text(statement, 1);
    int roundTripLength = sqlite3_column_bytes(statement, 1);
    if (!storageType || strcmp(storageType, "text") != 0 || !roundTrip ||
        roundTripLength != length || memcmp(roundTrip, value, (size_t)length) != 0) {
        fprintf(stderr, "Unhelpful compression did not preserve TEXT exactly\n");
        exit(1);
    }
    sqlite3_finalize(statement);
}

static void verify_scalar_contract(sqlite3 *database)
{
    static const char shortText[] = "short FTS value";
    verify_unchanged_text(database, shortText, (int)strlen(shortText));

    char noisyText[160];
    uint32_t state = 0x9e3779b9;
    for (int index = 0; index < (int)sizeof(noisyText); index++) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        noisyText[index] = (char)(33 + state % 94);
    }
    verify_unchanged_text(database, noisyText, (int)sizeof(noisyText));

    sqlite3_stmt *malformed = NULL;
    int result = sqlite3_prepare_v2(database,
        "SELECT ic_fts_uncompress(x'49435A0100000080')", -1, &malformed, NULL);
    if (result != SQLITE_OK) fail(database, "prepare malformed content", result);
    result = sqlite3_step(malformed);
    if (result != SQLITE_CORRUPT) {
        fprintf(stderr, "Malformed compressed content returned SQLite result %d\n", result);
        exit(1);
    }
    sqlite3_finalize(malformed);
}

static void verify_search(sqlite3 *database, int episode, const char *expectedUID,
                          const char *expectedTranscript)
{
    char query[64];
    snprintf(query, sizeof(query), "uniqueterm%04d", episode);
    sqlite3_stmt *statement = NULL;
    int result = sqlite3_prepare_v2(database,
        "SELECT uid, fulltext FROM episodes WHERE episodes MATCH ?", -1, &statement, NULL);
    if (result != SQLITE_OK) fail(database, "prepare search", result);
    sqlite3_bind_text(statement, 1, query, -1, SQLITE_TRANSIENT);
    result = sqlite3_step(statement);
    if (result != SQLITE_ROW) fail(database, "search row", result);
    const char *uid = (const char *)sqlite3_column_text(statement, 0);
    const char *fulltext = (const char *)sqlite3_column_text(statement, 1);
    int fulltextLength = sqlite3_column_bytes(statement, 1);
    if (!uid || strcmp(uid, expectedUID) != 0 || !fulltext ||
        fulltextLength != kTranscriptLength ||
        memcmp(fulltext, expectedTranscript, (size_t)kTranscriptLength) != 0) {
        fprintf(stderr, "Search did not round-trip episode %d exactly\n", episode);
        exit(1);
    }
    if (sqlite3_step(statement) != SQLITE_DONE) {
        fprintf(stderr, "Unique search returned more than one row\n");
        exit(1);
    }
    sqlite3_finalize(statement);
}

static void build_database(const char *path, int compressed)
{
    sqlite3 *database = NULL;
    int result = sqlite3_open(path, &database);
    if (result != SQLITE_OK) fail(database, "open", result);
    if (compressed) {
        result = ICFTSRegisterCompressionFunctions(database);
        if (result != SQLITE_OK) fail(database, "register compression", result);
        verify_scalar_contract(database);
    }
    execute(database, "PRAGMA journal_mode=OFF");
    execute(database, "PRAGMA synchronous=OFF");
    execute(database, "PRAGMA temp_store=MEMORY");
    if (compressed) {
        execute(database,
            "CREATE VIRTUAL TABLE episodes USING fts4(title, summary, fulltext, uid, feed_uid, "
            "compress=ic_fts_compress, uncompress=ic_fts_uncompress)");
    } else {
        execute(database,
            "CREATE VIRTUAL TABLE episodes USING fts4(title, summary, fulltext, uid, feed_uid)");
    }

    char *transcript = malloc((size_t)kTranscriptLength + 1);
    if (!transcript) fail(database, "allocate transcript", SQLITE_NOMEM);
    sqlite3_stmt *insert = NULL;
    result = sqlite3_prepare_v2(database,
        "INSERT INTO episodes(title, summary, fulltext, uid, feed_uid) VALUES(?,?,?,?,?)",
        -1, &insert, NULL);
    if (result != SQLITE_OK) fail(database, "prepare insert", result);
    execute(database, "BEGIN IMMEDIATE");
    for (int episode = 0; episode < kEpisodeCount; episode++) {
        char title[64], uid[64], summary[128];
        snprintf(title, sizeof(title), "Podcast episode %04d", episode);
        snprintf(uid, sizeof(uid), "episode-hash-%04d", episode);
        snprintf(summary, sizeof(summary),
                 "A detailed conversation and transcript for episode %04d.", episode);
        make_transcript(transcript, episode);
        sqlite3_bind_text(insert, 1, title, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 2, summary, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 3, transcript, kTranscriptLength, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 4, uid, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 5, "feed-uid", -1, SQLITE_STATIC);
        result = sqlite3_step(insert);
        if (result != SQLITE_DONE) fail(database, "insert", result);
        sqlite3_reset(insert);
        sqlite3_clear_bindings(insert);
    }
    sqlite3_finalize(insert);
    execute(database, "COMMIT");

    make_transcript(transcript, 4321);
    verify_search(database, 4321, "episode-hash-4321", transcript);
    if (compressed) {
        sqlite3_stmt *storage = NULL;
        result = sqlite3_prepare_v2(database,
            "SELECT typeof(c0title), typeof(c2fulltext), length(c2fulltext) "
            "FROM episodes_content WHERE docid=4322", -1, &storage, NULL);
        if (result != SQLITE_OK || sqlite3_step(storage) != SQLITE_ROW) {
            fail(database, "inspect compressed storage", result);
        }
        const char *titleType = (const char *)sqlite3_column_text(storage, 0);
        const char *fulltextType = (const char *)sqlite3_column_text(storage, 1);
        int storedLength = sqlite3_column_int(storage, 2);
        if (!titleType || strcmp(titleType, "text") != 0 ||
            !fulltextType || strcmp(fulltextType, "blob") != 0 ||
            storedLength >= kTranscriptLength / 4) {
            fprintf(stderr, "Short TEXT or compressed BLOB storage contract failed\n");
            exit(1);
        }
        sqlite3_finalize(storage);
    }

    make_transcript(transcript, 4321);
    memcpy(transcript, "replacementtoken4321 ", 21);
    sqlite3_stmt *update = NULL;
    result = sqlite3_prepare_v2(database,
        "UPDATE episodes SET fulltext=? WHERE uid='episode-hash-4321'", -1, &update, NULL);
    if (result != SQLITE_OK) fail(database, "prepare update", result);
    sqlite3_bind_text(update, 1, transcript, kTranscriptLength, SQLITE_TRANSIENT);
    if (sqlite3_step(update) != SQLITE_DONE) fail(database, "update", sqlite3_errcode(database));
    sqlite3_finalize(update);
    if (scalar_int(database,
        "SELECT count(*) FROM episodes WHERE episodes MATCH 'uniqueterm4321'") != 0 ||
        scalar_int(database,
        "SELECT count(*) FROM episodes WHERE episodes MATCH 'replacementtoken4321'") != 1) {
        fprintf(stderr, "FTS update left stale or missing search terms\n");
        exit(1);
    }
    execute(database, "DELETE FROM episodes WHERE uid='episode-hash-4321'");
    if (scalar_int(database,
        "SELECT count(*) FROM episodes WHERE episodes MATCH 'replacementtoken4321'") != 0) {
        fprintf(stderr, "FTS delete left a stale search term\n");
        exit(1);
    }
    execute(database, "INSERT INTO episodes(episodes) VALUES('optimize')");
    execute(database, "VACUUM");
    free(transcript);
    sqlite3_close(database);
}

static long long file_size(const char *path)
{
    struct stat status;
    if (stat(path, &status) != 0) {
        perror("stat");
        exit(1);
    }
    return (long long)status.st_size;
}

int main(int argc, char **argv)
{
    if (argc != 3) return 2;
    build_database(argv[1], 0);
    build_database(argv[2], 1);
    printf("ordinary=%lld compressed=%lld\n", file_size(argv[1]), file_size(argv[2]));
    return 0;
}
'''.replace("__IMPLEMENTATION__", IMPLEMENTATION)

with tempfile.TemporaryDirectory(prefix="instacast-fts-compression-") as directory:
    directory_path = Path(directory)
    source = directory_path / "fts_compression_proof.c"
    executable = directory_path / "fts_compression_proof"
    ordinary = directory_path / "ordinary.sqlite"
    compressed = directory_path / "compressed.sqlite"
    source.write_text(HARNESS)
    compile_result = subprocess.run(
        ["xcrun", "clang", "-std=c11", "-O2", str(source), "-lsqlite3", "-lz", "-o", str(executable)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if compile_result.returncode != 0:
        raise AssertionError(compile_result.stdout)
    proof = subprocess.run(
        [str(executable), str(ordinary), str(compressed)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=240,
    )
    if proof.returncode != 0:
        raise AssertionError(proof.stdout)
    match = re.search(r"ordinary=(\d+) compressed=(\d+)", proof.stdout)
    if not match:
        raise AssertionError(f"Missing size result: {proof.stdout}")
    ordinary_size, compressed_size = map(int, match.groups())
    ratio = compressed_size / ordinary_size
    if ratio >= 0.30:
        raise AssertionError(
            f"Compressed FTS is {ratio:.1%} of ordinary FTS; required less than 30%"
        )
    print(
        "FTS compressed-content runtime proof passed: "
        f"{ordinary_size / 1024 / 1024:.1f} MiB -> "
        f"{compressed_size / 1024 / 1024:.1f} MiB ({ratio:.1%})"
    )
