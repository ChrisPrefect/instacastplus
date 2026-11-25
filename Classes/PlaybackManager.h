/*
 *
 
 Manager.h
 *  Instacast
 *
 *  Created by Martin Hering on 01.07.11.
 *  Copyright 2011 Vemedio. All rights reserved.
 *
 */

#import <Foundation/Foundation.h>
#import "PlaybackDefines.h"

#if TARGET_OS_IPHONE
#define IC_IMAGE UIImage
#else
#define IC_IMAGE NSImage
#endif

@class CDEpisode;
@class PlayerView;
@class ICAudioEndpoint;
@class ICMetadataChapter;
@class CDFeed;

@interface PlaybackManager : NSObject {
@protected
	
}

+ (PlaybackManager*) playbackManager NS_SWIFT_NAME(shared());

@property (nonatomic, readonly, strong) CDEpisode* playingEpisode;
@property (nonatomic, readonly, getter=isReady) BOOL ready;
@property (nonatomic, readonly) BOOL failed;
@property (nonatomic, readonly, strong) NSError* playbackError;
@property (nonatomic, readonly, getter=hasMovingVideo) BOOL movingVideo;
@property (nonatomic, readonly) CGSize viewImageSize;
@property (nonatomic, readonly, getter=isAirPlayVideoActive) BOOL airPlayVideoActive;
@property (nonatomic) PlaybackSpeedControl speedControl;
@property (nonatomic) float playbackRate; // arbitrary rate (0.5-3.0), set by MQTT; overrides speedControl
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
@property (nonatomic, assign, getter=isSeeking) BOOL seeking;
@property (nonatomic, readonly, getter=isWaitingForLoad) BOOL waitingForLoad;
@property (nonatomic) BOOL hasBeenPlayingWhenInterrupted;

@property (readonly, strong) PlayerView* playerView;
- (void) restart;

- (void) openWithEpisode:(CDEpisode*)episode at:(NSTimeInterval)time autostart:(BOOL)autostart;
- (void) close;
- (void) closeAfterFinishedPlayback;
- (void) discardPlaybackPositionsForEpisodeHashes:(NSArray<NSString*>*)episodeHashes;
- (void) play;
- (void) pause;
- (void) playPause;
- (BOOL) isPodcastPlaying;

@property (nonatomic) float volume;

@property (nonatomic, readonly) NSTimeInterval time;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSTimeInterval playableDuration;
@property (nonatomic, readonly) BOOL streamingCacheActive;
@property (nonatomic, readonly) double streamingCacheProgress;
@property (nonatomic, readonly) BOOL streamingCacheComplete;

- (void) useCachedFileIfAvailableAfterStreamingDownload;
- (BOOL) cancelStreamingCacheForEpisode:(CDEpisode*)episode;

@property (nonatomic) double position;
@property (nonatomic, readonly) double playablePosition;

- (void) seekToTime:(NSTimeInterval)time;
- (void) seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance;
- (void) seekToChapter:(ICMetadataChapter*)chapter;
- (NSTimeInterval)timeForChapterSelectionAtIndex:(NSUInteger)index chapterTimes:(NSArray<NSNumber*>*)chapterTimes episode:(CDEpisode*)episode;

- (void) beginSeekingBackward;
- (void) beginSeekingForward;
- (void) endSeeking;

- (void) seekForward;
- (void) seekBackward;

// YES while the playhead is inside the configured near-chapter-end window,
// i.e. seekForward will jump to the next chapter instead of skipping the interval.
- (BOOL) forwardSkipJumpsToNextChapter;

- (void) rewind30Seconds;

- (void) nextChapter;
- (void) previousChapter;

// Uses the same effective chapter-keyword list as playback marker generation.
- (BOOL)autoSkipsChapterTitle:(NSString*)title forFeed:(CDFeed*)feed;
- (BOOL)autoSkipsChapterTitle:(NSString*)title atTime:(NSTimeInterval)time inEpisode:(CDEpisode*)episode;
- (void)setChapterSkipped:(BOOL)skipped title:(NSString*)title atTime:(NSTimeInterval)time inEpisode:(CDEpisode*)episode;
- (void)addSkipRuleForChapterTitle:(NSString*)title inEpisode:(CDEpisode*)episode atTime:(NSTimeInterval)time;

- (void) nextTrack;
- (void) previousTrack;
- (void) _findAndSetCurrentArtwork;

@property (readonly, strong) NSArray* chapters;
@property (nonatomic, readonly) BOOL automaticChapterSkippingAudioUnverified;
@property (nonatomic, readonly) BOOL generatedChapterTimelineUnverified;
@property (nonatomic, readonly) BOOL generatedAudioVerificationCompleted;
@property (nonatomic, readonly) BOOL transcriptAudioVerified;
@property (nonatomic, readonly, copy) NSString *verifiedTranscriptSnapshot;
@property (nonatomic, readonly, copy) NSString *chapterTimelineIdentifier;
- (BOOL)generatedArtifactTimingIsCurrent;
@property (assign) NSInteger currentChapter;

@property (readonly, strong) NSArray* artworks;
@property (assign) NSInteger currentArtwork; /* observable */

- (void) updateNowPlayingInfo;

// Pause shortening. The level is 0 (off) unless the feature is enabled in the playback settings;
// otherwise it is the podcast's own value or the global default (PlayerSilenceTrimLevel).
- (NSInteger) silenceTrimLevelForEpisode:(CDEpisode*)episode;
// Applies a changed enable switch or level to the playing episode (switches engines if needed).
- (void) silenceTrimSettingsDidChange;
@property (nonatomic, readonly, getter=isSilenceTrimActive) BOOL silenceTrimActive;
@property (nonatomic, readonly) NSTimeInterval silenceTrimSavedTime;
// Short status for the speed menu: time saved, or why shortening is not running right now.
- (NSString*) silenceTrimStatusText;
+ (NSString*) titleForSilenceTrimLevel:(NSInteger)level;
// How pauses are found (PlayerSilenceTrimDetection): 0 level threshold, 1 speech detection.
+ (NSString*) titleForSilenceTrimDetection:(NSInteger)detection;
+ (BOOL) silenceTrimUsesSpeechDetection;
// Stores a level chosen in the player: for the podcast when it has its own value, else globally.
+ (void) storeSilenceTrimLevel:(NSInteger)level forFeed:(CDFeed*)feed;

@property (nonatomic, strong) ICAudioEndpoint* audioEndpoint;


#if !TARGET_OS_IPHONE
- (void) updateForSpeedControlSettingsChanged;
#endif
@end
