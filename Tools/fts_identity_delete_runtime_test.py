#!/usr/bin/env python3
"""Identity deletes must not decompress unrelated FTS4 documents (background CPU kill)."""

from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes/Model/ICFTSController.m").read_text()
CALLBACKS = SOURCE.split("static const unsigned char kICFTSCompressedContentMagic", 1)[1]
CALLBACKS = "static const unsigned char kICFTSCompressedContentMagic" + CALLBACKS.split(
    "static NSString* ICFTSString", 1
)[0]
helper = re.search(r"static NSString\* ICFTSIdentityQuery\([^}]+\}", SOURCE)
queries = re.findall(r'@"(DELETE FROM (feeds|episodes) WHERE (uid|feed_uid)[^"]+)"', SOURCE)
assert len(queries) == 15, "Exercise every production identity-delete call site"

HARNESS = r'''
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdint.h>
#include <sqlite3.h>
#include <zlib.h>

__CALLBACKS__
__HELPER__

static int uncompressedValues;
static void countedUncompress(sqlite3_context *context, int count, sqlite3_value **values) {
    uncompressedValues++;
    ICFTSUncompressValue(context, count, values);
}
static void check(BOOL success, NSString *message) {
    if (!success) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}
static void execute(sqlite3 *db, const char *sql) {
    check(sqlite3_exec(db, sql, NULL, NULL, NULL) == SQLITE_OK,
          [NSString stringWithUTF8String:sqlite3_errmsg(db)]);
}
static int scalar(sqlite3 *db, NSString *sql) {
    sqlite3_stmt *stmt;
    check(sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK, @"prepare count");
    check(sqlite3_step(stmt) == SQLITE_ROW, @"read count");
    int result = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return result;
}
static int identityCount(sqlite3 *db, NSString *table, NSString *column, NSString *uid) {
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM %@ WHERE %@ = ?", table, column];
    sqlite3_stmt *stmt;
    check(sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK, @"prepare identity count");
    sqlite3_bind_text(stmt, 1, uid.UTF8String, -1, SQLITE_TRANSIENT);
    check(sqlite3_step(stmt) == SQLITE_ROW, @"read identity count");
    int result = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return result;
}
static void insert(sqlite3 *db, NSString *table, NSString *identity) {
    NSString *sql = [NSString stringWithFormat:@"INSERT INTO %@(uid,feed_uid,fulltext) VALUES(?,?,?)", table];
    sqlite3_stmt *stmt;
    check(sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK, @"prepare insert");
    sqlite3_bind_text(stmt, 1, identity.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, identity.UTF8String, -1, SQLITE_TRANSIENT);
    NSString *text = [@"Technology science and podcast discussion. " stringByPaddingToLength:8192
                                                                         withString:@"podcast " startingAtIndex:0];
    sqlite3_bind_text(stmt, 3, text.UTF8String, -1, SQLITE_TRANSIENT);
    check(sqlite3_step(stmt) == SQLITE_DONE, @"insert document");
    sqlite3_finalize(stmt);
}
int main(void) {
    @autoreleasepool {
        sqlite3 *db;
        check(sqlite3_open(":memory:", &db) == SQLITE_OK, @"open database");
        check(ICFTSRegisterCompressionFunctions(db) == SQLITE_OK, @"register callbacks");
        sqlite3_create_function_v2(db, "ic_fts_uncompress", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
                                  NULL, countedUncompress, NULL, NULL, NULL);
        for (NSString *table in @[@"feeds", @"episodes"]) {
            execute(db, [NSString stringWithFormat:@"CREATE VIRTUAL TABLE %@ USING fts4(uid,feed_uid,fulltext,compress=ic_fts_compress,uncompress=ic_fts_uncompress)", table].UTF8String);
            for (int i = 0; i < 600; i++) {
                insert(db, table, [NSString stringWithFormat:@"https://unrelated.example/%d", i]);
            }
        }
        NSArray *cases = __QUERIES__;
        NSArray *identities = @[@"190610f85b085efce02e5cde4b6d4f59",
            @"https://example.test/a-b", @"https://example.test/a OR b?x=1&y=2",
            @"https://example.test/a\"b", @"https://example.test/ü?q=🙃"];
        for (NSArray *entry in cases) {
            NSString *sql = entry[0], *table = entry[1], *column = entry[2];
            for (NSString *uid in identities) {
                // Same FTS tokens, different identity: MATCH narrows candidates, equality decides.
                NSString *neighbor = [uid stringByAppendingString:@"/"];
                insert(db, table, neighbor);
                insert(db, table, uid);
                insert(db, table, uid); // Historical duplicate identities must both be removed.
                NSString *countSQL = [NSString stringWithFormat:@"SELECT count(*) FROM %@_content", table];
                int before = scalar(db, countSQL);
                for (int pass = 0; pass < 2; pass++) {
                    sqlite3_stmt *stmt;
                    check(sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK, @"prepare production delete");
                    __BIND__
                    uncompressedValues = 0;
                    check(sqlite3_step(stmt) == SQLITE_DONE,
                          [NSString stringWithUTF8String:sqlite3_errmsg(db)]);
                    sqlite3_finalize(stmt);
                    check(scalar(db, countSQL) == before - 2, @"Delete lost exact identity semantics");
                    check(uncompressedValues <= 30,
                          [NSString stringWithFormat:@"%@ unpacked %d values for one identity; unrelated documents must not be scanned", sql, uncompressedValues]);
                    check(identityCount(db, table, column, uid) == 0, @"Target identity survived deletion");
                    check(identityCount(db, table, column, neighbor) > 0, @"Token-equivalent neighbor was deleted");
                }
            }
        }
        sqlite3_close(db);
        puts("FTS identity deletes: exact matches, duplicates, missing IDs and bounded decompression passed");
    }
}
'''

if helper:
    bindings = '''NSString *query = ICFTSIdentityQuery(uid);
                    sqlite3_bind_text(stmt, 1, query.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(stmt, 2, uid.UTF8String, -1, SQLITE_TRANSIENT);'''
    for sql, _, _ in queries:
        assert f'@"{sql}", ICFTSIdentityQuery(' in SOURCE, "Every identity delete must bind the literal FTS query"
else:
    bindings = "sqlite3_bind_text(stmt, 1, uid.UTF8String, -1, SQLITE_TRANSIENT);"

cases = "@[" + ",".join(f'@[@"{sql}",@"{table}",@"{column}"]' for sql, table, column in sorted(set(queries))) + "]"
program = HARNESS.replace("__CALLBACKS__", CALLBACKS).replace("__HELPER__", helper[0] if helper else "")
program = program.replace("__QUERIES__", cases).replace("__BIND__", bindings)
with tempfile.TemporaryDirectory(prefix="instacast-fts-identity-") as directory:
    source, binary = Path(directory) / "proof.m", Path(directory) / "proof"
    source.write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(source), "-lsqlite3", "-lz", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
