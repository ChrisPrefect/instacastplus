#!/usr/bin/env python3
"""Execute production start/end skip blocks for first play and replay."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Classes/PlaybackManager.m').read_text()
end=s.split('// Handle auto skip end',1)[1].split('\n        \n        if (weakSelf.player.rate > 0)',1)[0]
start=s.split('- (void) _continueOpeningAsset:',1)[1].split('    AVPlayerItem* playerItem =',1)[0].split('{',1)[1]
remove=s.split('- (void) _removeTemporarySavePosition',1)[1].split('- (void) _saveCurrentPlaybackPosition',1)[0]
skip=s.split('- (void)_finishEpisodeDueToSkip:',1)[1].split('- (void) playerItemDidPlayToEndTimeNotification:',1)[0]
finish=s.split('- (void) playerItemDidPlayToEndTimeNotification:',1)[1].split('- (void) _temporarySavePosition',1)[0]
fixture=r'''
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
NSString* PlayerAutoSkipEndPeriod=@"end";
NSString* PlayerAutoSkipStartPeriod=@"start";
NSString* kDefaultTemporaryPlaybackPositions=@"positions";
NSString* AutoDeleteAfterFinishedPlaying=@"delete";
NSString* PlaybackManagerEpisodeDidFinishNotification=@"finished";
static NSUserDefaults* defaults;
#define USER_DEFAULTS defaults
@interface CDFeed:NSObject
@property NSString* uid;
@property NSMutableDictionary* values;
- (double)doubleForKey:(NSString*)key;
- (BOOL)boolForKey:(NSString*)key;
@end
@implementation CDFeed
- (double)doubleForKey:(NSString*)key{return [self.values[key] doubleValue];}
- (BOOL)boolForKey:(NSString*)key{return [self.values[key] boolValue];}
@end
@interface CDEpisode:NSObject
@property CDFeed* feed;
@property NSString* objectHash;
@property BOOL consumed;
@property BOOL starred;
@property double position;
@property double duration;
@end
@implementation CDEpisode @end
@interface Asset:NSObject
@property CMTime duration;
@end
@implementation Asset @end
@interface AVPlayerItem:NSObject
@property Asset* asset;
@end
@implementation AVPlayerItem @end
@interface Player:NSObject
@property AVPlayerItem* currentItem;
@property CMTime seekTime;
@property int seeks;
@property (copy) void (^seekCompletion)(BOOL);
- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after completionHandler:(void(^)(BOOL))completion;
@end
@implementation Player
- (void)seekToTime:(CMTime)time toleranceBefore:(CMTime)before toleranceAfter:(CMTime)after completionHandler:(void(^)(BOOL))completion {
 self.seekTime=time;self.seeks++;self.seekCompletion=completion;
}
@end
@interface CacheManager:NSObject
+ (instancetype)sharedCacheManager;
- (void)removeCacheForEpisode:(CDEpisode*)episode automatic:(BOOL)automatic;
@end
@implementation CacheManager
+ (instancetype)sharedCacheManager{return [self new];}
- (void)removeCacheForEpisode:(CDEpisode*)episode automatic:(BOOL)automatic{}
@end
@interface Database:NSObject
@property int saves;
- (void)setEpisode:(CDEpisode*)episode position:(double)position;
- (void)save;
@end
@implementation Database
- (void)setEpisode:(CDEpisode*)episode position:(double)position{episode.position=position;}
- (void)save{self.saves++;}
@end
static Database* database;
#define DMANAGER database
@interface ICSharePlayCoordinator:NSObject
@property BOOL active;
@property BOOL owner;
+ (instancetype)sharedCoordinator;
- (BOOL)hasActiveSession;
- (BOOL)canAdvanceAutomatically;
- (void)publishPlaybackFinishedForEpisodeIdentifier:(NSString*)hash;
@end
@implementation ICSharePlayCoordinator
+ (instancetype)sharedCoordinator {static id x;if(!x)x=[self new];return x;}
- (BOOL)hasActiveSession{return self.active;}
- (BOOL)canAdvanceAutomatically{return self.owner;}
- (void)publishPlaybackFinishedForEpisodeIdentifier:(NSString*)hash{}
@end
@interface AudioSession:NSObject
@property CDEpisode* next;
@property int removed;
@property int advanced;
@property BOOL autoStopDisabled;
+ (instancetype)sharedAudioSession;
- (void)eraseEpisodesFromUpNext:(NSArray*)episodes;
- (CDEpisode*)nextPlayableEpisode;
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(double)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve;
@end
@implementation AudioSession
+ (instancetype)sharedAudioSession{static id x;if(!x)x=[self new];return x;}
- (void)eraseEpisodesFromUpNext:(NSArray*)episodes{self.removed++;}
- (CDEpisode*)nextPlayableEpisode{return self.next;}
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(double)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve{self.advanced++;}
@end
@interface PlaybackManager:NSObject {BOOL _changingPosition;}
@property Player* player;
@property CDEpisode* playingEpisode;
@property double initialPlaybackTime;
@property BOOL inTransitionToNextTrack;
@property int closed;
@property BOOL isAutoSkipping;
@end
@implementation PlaybackManager
- (void)_logPlaybackAutoSkipEvent:(NSString*)message episode:(CDEpisode*)episode currentTime:(double)time duration:(double)duration metadata:(NSDictionary*)metadata{}
- (void)_logPlaybackFinishEvent:(NSString*)message episode:(CDEpisode*)episode currentTime:(double)time duration:(double)duration metadata:(NSDictionary*)metadata{}
- (double)time{return CMTimeGetSeconds(self.player.seekTime);}
- (double)duration{return CMTimeGetSeconds(self.player.currentItem.asset.duration);}
- (void)closeAndSaveCurrentPosition:(BOOL)save{self.closed++;}
- (void) _removeTemporarySavePosition REMOVE_BODY
- (void)_finishEpisodeDueToSkip: SKIP_BODY
- (void) playerItemDidPlayToEndTimeNotification: FINISH_BODY
- (void)applyStart { START_BLOCK }
- (void)tick:(CMTime)time {PlaybackManager* weakSelf=self;CDEpisode* episode=self.playingEpisode; END_BLOCK }
@end
static int failures;
#define CHECK(c,msg) do{if(!(c)){fprintf(stderr,"FAIL: %s\n",msg);failures++;}}while(0)
int main(){@autoreleasepool{
 NSString* suite=[@"ReplaySkip." stringByAppendingString:NSUUID.UUID.UUIDString];defaults=[[NSUserDefaults alloc]initWithSuiteName:suite];
 for(int played=0;played<=1;played++)for(int feed=0;feed<=1;feed++)for(int next=0;next<=1;next++){
  [defaults removePersistentDomainForName:suite];database=[Database new];
  PlaybackManager* p=[PlaybackManager new];CDEpisode* e=[CDEpisode new];e.objectHash=@"episode";e.feed=[CDFeed new];e.feed.uid=@"feed";e.feed.values=[NSMutableDictionary new];e.consumed=played;e.duration=9619;e.position=played?9619:0;p.playingEpisode=e;
  p.player=[Player new];p.player.currentItem=[AVPlayerItem new];p.player.currentItem.asset=[Asset new];p.player.currentItem.asset.duration=CMTimeMakeWithSeconds(9619,1000);
  [defaults setDouble:70 forKey:PlayerAutoSkipEndPeriod];[defaults setDouble:30 forKey:PlayerAutoSkipStartPeriod];
  if(feed){e.feed.values[@"feed_auto_skip_end_period"]=@43;e.feed.values[@"feed_auto_skip_start_period"]=@60;}
  [p applyStart];CHECK(p.initialPlaybackTime==(feed?60:30),"Start skip must apply on replay and first play");
  AudioSession* session=[AudioSession sharedAudioSession];session.next=next?[CDEpisode new]:nil;session.advanced=0;session.removed=0;
  ICSharePlayCoordinator* coordinator=[ICSharePlayCoordinator sharedCoordinator];coordinator.active=NO;
  double trigger=9619-(feed?43:70);
  [defaults setObject:@{e.objectHash:@(trigger-1)} forKey:kDefaultTemporaryPlaybackPositions];
  double positionBefore=e.position;
  [p tick:CMTimeMakeWithSeconds(trigger-1,1000)];CHECK(p.player.seeks==0 && database.saves==0,"Do not seek or finish before skip boundary");
  coordinator.active=YES;coordinator.owner=NO;[p tick:CMTimeMakeWithSeconds(trigger,1000)];CHECK(p.player.seeks==0 && database.saves==0,"SharePlay non-owner cannot seek or advance");coordinator.active=NO;
  [p tick:CMTimeMakeWithSeconds(trigger,1000)];
  CHECK(p.player.seeks==1 && CMTimeGetSeconds(p.player.seekTime)==9619,"End skip must seek to the actual media end on first play and replay");
  CHECK(e.position==positionBefore && database.saves==0 && session.advanced==0 && p.closed==0,"Wait for real media completion before changing episode state or advancing");
  [p tick:CMTimeMakeWithSeconds(trigger,1000)];CHECK(p.player.seeks==1,"Do not issue overlapping end seeks");
  if(p.player.seekCompletion)p.player.seekCompletion(YES);
  [p playerItemDidPlayToEndTimeNotification:nil];
  CHECK(database.saves==1,"Normal completion persists the cleared position");
  CHECK(e.consumed && e.position==0,"Normal completion marks heard and clears the persistent position");
  CHECK(![defaults dictionaryForKey:kDefaultTemporaryPlaybackPositions][e.objectHash],"Normal completion clears temporary resume");
  CHECK(session.removed==1,"End skip removes finished episode from Up Next");
  CHECK(session.advanced==next && p.closed==!next,"End skip advances or closes on replay too");
  CHECK([defaults integerForKey:@"TotalEpisodesPlayedCount"]==(played?0:1),"Replay must not double-count already played episode");
 }
 [defaults removePersistentDomainForName:suite];
 if(!failures)puts("First-play/replay start and end skip runtime checks passed");return failures?1:0;
}}
'''
with tempfile.TemporaryDirectory(prefix='instacast-replay-skip-') as d:
 p=Path(d);(p/'test.m').write_text(fixture.replace('START_BLOCK',start).replace('END_BLOCK',end).replace('REMOVE_BODY',remove).replace('SKIP_BODY',skip).replace('FINISH_BODY',finish))
 subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreMedia',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
