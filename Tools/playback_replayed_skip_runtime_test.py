#!/usr/bin/env python3
"""Execute production start/end skip blocks for first play and replay."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Classes/PlaybackManager.m').read_text()
end=s.split('// Handle auto skip end',1)[1].split('\n        \n        if (weakSelf.player.rate > 0)',1)[0]
start=s.split('- (void) _continueOpeningAsset:',1)[1].split('    AVPlayerItem* playerItem =',1)[0].split('{',1)[1]
fixture=r'''
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
NSString* PlayerAutoSkipEndPeriod=@"end";
NSString* PlayerAutoSkipStartPeriod=@"start";
NSString* kDefaultTemporaryPlaybackPositions=@"positions";
static NSUserDefaults* defaults;
#define USER_DEFAULTS defaults
@interface CDFeed:NSObject
@property NSString* uid;
@property NSMutableDictionary* values;
- (double)doubleForKey:(NSString*)key;
@end
@implementation CDFeed
- (double)doubleForKey:(NSString*)key{return [self.values[key] doubleValue];}
@end
@interface CDEpisode:NSObject
@property CDFeed* feed;
@property NSString* objectHash;
@property BOOL consumed;
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
@end
@implementation Player @end
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
@end
@implementation PlaybackManager
- (void)_logPlaybackAutoSkipEvent:(NSString*)message episode:(CDEpisode*)episode currentTime:(double)time duration:(double)duration metadata:(NSDictionary*)metadata{}
- (void)closeAndSaveCurrentPosition:(BOOL)save{self.closed++;}
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
  [p tick:CMTimeMakeWithSeconds(trigger-1,1000)];CHECK(database.saves==0,"Do not finish before skip boundary");
  coordinator.active=YES;coordinator.owner=NO;[p tick:CMTimeMakeWithSeconds(trigger,1000)];CHECK(database.saves==0,"SharePlay non-owner cannot advance");coordinator.active=NO;
  [p tick:CMTimeMakeWithSeconds(trigger,1000)];
  CHECK(database.saves==1,played?"Played episode must execute end skip":"Unplayed episode must execute end skip");
  CHECK(e.consumed && e.position==9619,"End skip persists completion position");
  CHECK(session.removed==1,"End skip removes finished episode from Up Next");
  CHECK(session.advanced==next && p.closed==!next,"End skip advances or closes on replay too");
  CHECK([defaults integerForKey:@"TotalEpisodesPlayedCount"]==(played?0:1),"Replay must not double-count already played episode");
 }
 [defaults removePersistentDomainForName:suite];
 if(!failures)puts("First-play/replay start and end skip runtime checks passed");return failures?1:0;
}}
'''
with tempfile.TemporaryDirectory(prefix='instacast-replay-skip-') as d:
 p=Path(d);(p/'test.m').write_text(fixture.replace('START_BLOCK',start).replace('END_BLOCK',end))
 subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-framework','CoreMedia',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
