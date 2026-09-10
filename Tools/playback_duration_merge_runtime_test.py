#!/usr/bin/env python3
"""Execute the actual feed-copy, refresh and measured-duration Objective-C paths.

--history also executes the normal-refresh clauses before/after 7150f05e and
1c4fa4ef, proving when shortening an already-started episode became possible.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--history', action='store_true')
args = parser.parse_args()


def read(path, revision=None):
    if revision:
        return subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)


def refresh(source):
    marker = 'NSInteger remoteDuration = remoteEpisode.duration;'
    if marker not in source:
        return ''  # Historical predecessor did not update existing durations.
    return marker + source.split(marker, 1)[1].split('BOOL newer =', 1)[0]


subscription = read('Classes/Model/SubscriptionManager.m')
database = read('Classes/Model/DatabaseManager.m')
playback = read('Classes/PlaybackManager.m')
copy_sub = method(subscription, '- (void)_copyEpisodeValuesFrom:')
copy_db = method(database, '- (void) _copyEpisodeValuesFrom:')
ready = playback.split('if (currentItem.status == AVPlayerItemStatusReadyToPlay', 1)[1]
ready = 'episode.lastPlayed = [NSDate date];' + ready.split('episode.lastPlayed = [NSDate date];', 1)[1].split('[DMANAGER save]', 1)[0]
properties = ' '.join('@property (strong) id ' + name + ';' for name in (
    'objectHash', 'title', 'subtitle', 'guid', 'pubDate', 'imageURL', 'linkURL', 'link',
    'author', 'summary', 'fulltext', 'textDescription', 'transcripts', 'paymentURL',
    'deeplinkURL', 'deeplink', 'lastPlayed'))
source = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
static int failures;
static void require(BOOL ok, NSString* message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}
@interface ICEpisode : NSObject
PROPERTIES
@property int32_t duration;
@property int32_t position;
@property BOOL consumed;
@property BOOL video;
@property BOOL explicitContent;
@end
@implementation ICEpisode
@end
@interface CDEpisode : ICEpisode
@end
@implementation CDEpisode
@end
@interface ProbePlayer : NSObject
@property double duration;
@property double initialPlaybackTime;
@end
@implementation ProbePlayer
@end
@interface SubscriptionManager : NSObject
@end
@implementation SubscriptionManager
COPY_SUB
@end
@interface DatabaseManager : NSObject
@end
@implementation DatabaseManager
COPY_DB
@end
static void refreshCurrent(CDEpisode* localEpisode, ICEpisode* remoteEpisode) {
REFRESH
}
static void readyCurrent(CDEpisode* episode, ProbePlayer* weakSelf) {
READY
}
HISTORY_FUNCTIONS
int main() { @autoreleasepool {
    ICEpisode* remote = [ICEpisode new]; remote.duration=3180; remote.title=@"updated";
    NSDate* playedAt=[NSDate dateWithTimeIntervalSince1970:1700000000];
    for (int route=0; route<3; route++) {
        for (NSNumber* consumed in @[@NO, @YES]) {
            for (NSNumber* measured in @[@NO, @YES]) {
                CDEpisode* episode=[CDEpisode new];
                episode.duration=3600; episode.position=3180; episode.consumed=consumed.boolValue;
                episode.lastPlayed=measured.boolValue ? playedAt : nil;
                if (route==0) [[SubscriptionManager new] _copyEpisodeValuesFrom:remote toPersistentEpisode:episode];
                if (route==1) [[DatabaseManager new] _copyEpisodeValuesFrom:remote to:episode];
                if (route==2) refreshCurrent(episode, remote);
                require(episode.duration==(measured.boolValue ? 3600 : 3180),
                        [NSString stringWithFormat:@"route %d overwrote played episode duration (%d)",route,episode.duration]);
                require(episode.position==3180 && episode.consumed==consumed.boolValue &&
                        episode.lastPlayed==(measured.boolValue ? playedAt : nil), @"feed merge changed playback state");
                if (route<2) require([episode.title isEqual:@"updated"], @"metadata was not refreshed");
            }
        }
    }
    CDEpisode* episode=[CDEpisode new]; episode.duration=3180; episode.position=3180; episode.consumed=NO;
    ProbePlayer* player=[ProbePlayer new]; player.duration=3600; player.initialPlaybackTime=0;
    readyCurrent(episode,player);
    require(episode.duration==3600 && player.initialPlaybackTime==3180 && !episode.consumed,
            @"legacy too-short duration must resume at actual saved position, without inventing completion");
    episode.duration=3600; episode.position=3180; player.duration=3000; player.initialPlaybackTime=0;
    readyCurrent(episode,player);
    require(episode.duration==3000 && !episode.consumed, @"shorter replacement audio does not prove a completed listen");
HISTORY_CHECKS
    if (failures==0) puts("Actual duration-copy, refresh and resume paths passed");
    return failures ? 1 : 0;
} }
'''
history_functions = []
history_checks = []
if args.history:
    for index, (revision, expected) in enumerate([('7150f05e^', 3600), ('7150f05e', 3180), ('1c4fa4ef', 3600)]):
        clause = refresh(read('Classes/Model/SubscriptionManager.m', revision))
        history_functions.append(f'static void history{index}(CDEpisode* localEpisode, ICEpisode* remoteEpisode) {{\n{clause}\n}}')
        history_checks.append(f'''episode.duration=3600; episode.position=3180; episode.consumed=NO; episode.lastPlayed=playedAt;
    history{index}(episode,remote);
    require(episode.duration=={expected} && episode.position==3180 && !episode.consumed, @"historical behavior differs: {revision}");
    printf("History {revision}: duration=%d position=%d consumed=%d\\n",episode.duration,episode.position,episode.consumed);''')
for key, value in [('PROPERTIES', properties), ('COPY_SUB',copy_sub), ('COPY_DB',copy_db),
                   ('REFRESH',refresh(subscription)), ('READY',ready),
                   ('HISTORY_FUNCTIONS','\n'.join(history_functions)), ('HISTORY_CHECKS','\n'.join(history_checks))]:
    source = source.replace(key, value)
with tempfile.TemporaryDirectory(prefix='instacast-duration-merge-') as temp:
    path=Path(temp)/'probe.m';path.write_text(source)
    binary=Path(temp)/'probe'
    subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
