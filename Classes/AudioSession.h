//
//  AudioSession.h
//  Instacast
//
//  Created by Martin Hering on 19.07.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <stdint.h>
#import "PlaybackDefines.h"

extern NSString* AudioSessionAudioRouteDidChangeNotification;
extern NSString* AudioSessionDidRestorePlaybackNotification;

@class CDEpisode;
@class CDFeed;

@interface AudioSession : NSObject {
@protected
}

+ (AudioSession*) sharedAudioSession;
+ (uint64_t)playbackIntentRevision;

- (void) resetSession;

- (void) playEpisode:(CDEpisode*)anEpisode;
- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent;
- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart;
- (void) restorePlaybackEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart;
- (void) clear;
- (void) stop;
- (void) togglePlay;

- (CDEpisode*) nextPlayableEpisode;
- (void) disableContinuousPlaybackForCurrentEpisode;

// Episode list (CDEpisodeList uid) the current playback belongs to. When that list has
// continuousPlayback enabled, the end-of-episode flow plays the next episode of the
// list — the play-next queue itself stays untouched. Managed by playEpisode: — list
// screens arm it via notePlaybackSourceEpisodeList: BEFORE starting playback; it stays
// set while the playing episode is a member of the list and clears otherwise.
@property (nonatomic, copy, readonly) NSString* sourceEpisodeListUID;
- (void) notePlaybackSourceEpisodeList:(CDEpisodeList*)list;

@property (nonatomic, readonly, strong) CDEpisode* episode;

- (BOOL) canRestorePlaybackState;
- (void) restorePlaybackStateWithEpisodeHash:(NSString*)episodeHash playlistHashes:(NSArray*)playlistHashes time:(NSTimeInterval)time;
@property (nonatomic, readonly, getter = isAirPlayActive) BOOL airPlayActive;
@property (nonatomic, readonly, getter = isHeadphonesAttached) BOOL headphonesAttached;

@property (nonatomic, readonly) NSTimeInterval timerRemainingTime;
@property (nonatomic, assign) PlaybackStopTimeValue timerValue;
@property (nonatomic, readonly, strong) NSDate *stopDate;
- (void)setTimerWithDuration:(NSTimeInterval)seconds; // arbitrary seconds, bypasses preset enum

@end
