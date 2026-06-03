#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Parser" / "ICFeedParser.m").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


method = SOURCE[
    SOURCE.index("- (BOOL) _parseAsync:(BOOL)async error:(NSError**)outError"):
    SOURCE.index("#pragma mark XMLParser Delegate")
]

http_error_start = method.index("if (!error && statusCode >= 400)")
data_hash_start = method.index("NSString* dataHash = [feedData MD5Hash];")
http_error_block = method[http_error_start:data_hash_start]

require(
    "goto end;" not in http_error_block,
    "HTTP status errors before parser-local object declarations must not jump to the end label.",
)
require(
    "return [self _finishParsingAsync:async error:error outError:outError];" in http_error_block,
    "HTTP status errors must use the shared parser completion path directly.",
)
require(
    "- (BOOL)_finishParsingAsync:(BOOL)async error:(NSError*)error outError:(NSError**)outError" in SOURCE,
    "ICFeedParser must keep the shared completion/error delivery logic in a helper callable before later object declarations.",
)
require(
    method.count("return [self _finishParsingAsync:async error:error outError:outError];") >= 2,
    "Both pre-parse HTTP errors and the end label must use the same completion helper.",
)
