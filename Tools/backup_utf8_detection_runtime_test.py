#!/usr/bin/env python3
"""Run the production backup detector against UTF-8 prefix boundaries."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PARSER = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
DETECTOR = PARSER.split("+ (BOOL)isInstacastBackupData:", 1)[1].split(
    "+ (void)parseData:", 1
)[0]

HARNESS = r'''
#import <Foundation/Foundation.h>

@interface BackupDetector : NSObject
+ (BOOL)isInstacastBackupData:(NSData *)data;
@end

@implementation BackupDetector
+ (BOOL)isInstacastBackupData:DETECTOR_METHOD
@end

static NSUInteger failures = 0;

static void check(NSString *name, NSString *xml, BOOL expected) {
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    if (![parser parse]) {
        fprintf(stderr, "%s: invalid XML fixture\n", name.UTF8String);
        failures++;
        return;
    }
    BOOL actual = [BackupDetector isInstacastBackupData:data];
    if (actual != expected) {
        fprintf(stderr, "%s: expected backup=%s, actual=%s\n",
                name.UTF8String, expected ? "YES" : "NO", actual ? "YES" : "NO");
        failures++;
    }
}

int main(void) {
    @autoreleasepool {
        NSString *prefix = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<instacast version=\"1\" date=\"2026-09-24T10:00:00+0200\">\n"
            "  <podcasts>\n"
            "    <podcast url=\"https://example.org/feed.xml\" rank=\"0\" title=\"";
        NSString *suffix = @"\">\n    </podcast>\n  </podcasts>\n</instacast>\n";
        check(@"normal backup", [NSString stringWithFormat:@"%@Podcast%@", prefix, suffix], YES);
        for (NSString *character in @[@"ü", @"🎧"]) {
            NSUInteger byteLength = [character lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            for (NSUInteger split = 1; split < byteLength; split++) {
                NSMutableString *xml = [prefix mutableCopy];
                while ([xml lengthOfBytesUsingEncoding:NSUTF8StringEncoding] < 500 - split) {
                    [xml appendString:@"a"];
                }
                [xml appendString:character];
                [xml appendString:suffix];
                check([NSString stringWithFormat:@"%@ split after byte %lu", character, (unsigned long)split], xml, YES);
            }
        }
        check(@"non-backup XML", @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><body/></opml>", NO);
        if (failures > 0) return 1;
        puts("Backup UTF-8 detection runtime checks passed");
        return 0;
    }
}
'''.replace("DETECTOR_METHOD", DETECTOR)


with tempfile.TemporaryDirectory(prefix="instacast-backup-utf8-") as directory:
    temporary = Path(directory)
    source = temporary / "main.m"
    executable = temporary / "backup-detector"
    source.write_text(HARNESS)
    subprocess.run(
        ["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(source), "-o", str(executable)],
        cwd=ROOT,
        check=True,
    )
    subprocess.run([str(executable)], cwd=ROOT, check=True)
