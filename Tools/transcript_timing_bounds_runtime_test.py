#!/usr/bin/env python3
"""Run the publisher cue parser against valid and unseekable timing bounds."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()
functions = source[source.index("static NSDictionary* ICTranscriptCueMake("):
                   source.index("static NSArray<NSDictionary*>* ICTranscriptParseLRC(")]
program = r'''
#import <Foundation/Foundation.h>
#import <math.h>
@interface NSString (ParserStub)
- (NSString*)stringByStrippingHTML;
@end
@implementation NSString (ParserStub)
- (NSString*)stringByStrippingHTML { return self; }
@end
FUNCTIONS
int main() { @autoreleasepool {
    int failures = 0;
    #define CHECK(name, expression) do { BOOL passed = (expression); printf("%s: %s\n", name, passed ? "PASS" : "FAIL"); failures += !passed; } while (0)
    NSString *valid = @"WEBVTT\n\n00:02:20.988 --> 00:02:28.514\nPublisher cue\n\n";
    NSArray *cues = ICTranscriptParseArrowTimedText(valid);
    CHECK("Freak Show timestamp retains precise start", cues.count == 1 && fabs([cues[0][@"start"] doubleValue] - 140.988) < 0.0001);
    CHECK("Freak Show timestamp retains precise end", cues.count == 1 && fabs([cues[0][@"end"] doubleValue] - 148.514) < 0.0001);
    for (NSString *bounds in @[@"00:00:1e999 --> 00:00:1e999", @"00:00:01 --> 00:00:1e999", @"1e99 --> 1e100", @"-1 --> 2"]) {
        NSString *invalid = [NSString stringWithFormat:@"WEBVTT\n\n%@\nInvalid cue\n\n", bounds];
        CHECK("Unseekable publisher bounds are discarded", ICTranscriptParseArrowTimedText(invalid).count == 0);
        CHECK("An invalid cue does not discard valid following cues", ICTranscriptParseArrowTimedText([invalid stringByAppendingString:valid]).count == 1);
    }
    CHECK("NaN start is rejected", ICTranscriptCueMake(NAN, 2, @"Invalid") == nil);
    CHECK("NaN end is rejected", ICTranscriptCueMake(1, NAN, @"Invalid") == nil);
    NSArray *inferred = ICTranscriptNormalizeCues(@[ICTranscriptCueMake(5, 0, @"LRC cue")]);
    CHECK("Formats without explicit end retain inferred cue duration", inferred.count == 1 && [inferred[0][@"end"] doubleValue] == 7);
    return failures ? 1 : 0;
}}
'''.replace("FUNCTIONS", functions)
with tempfile.TemporaryDirectory(prefix="instacast-transcript-bounds-") as directory:
    path = Path(directory)
    (path / "test.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(path / "test.m"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
