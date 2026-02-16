//
//  PlayInfoViewController2.m
//  Instacast
//
//  Created by Martin Hering on 02.08.14.
//
//

#import <objc/runtime.h>

#import "PlayerInfoViewController_v5.h"
#import "ChaptersTableViewCell.h"
#import "PlayerInfoHeaderFooterView.h"
#import "PlayerBookmarksTableViewCell.h"
#import "UIViewController+ShowNotes.h"
#import "EpisodesTableViewCell.h"
#import "PlayerVideoViewController.h"
#import "PlayerView.h"
#import "PlaybackViewController.h"
#import "AudioSession.h"
#import "CacheManager.h"
#import "ChapterImageCell.h"
#import "UIImage+Utils.h"
#import "ICMetadata.h"
#import "InstacastAppDelegate.h"
#import "NSString+ICParser.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString* kChapterCell = @"ChapterCell";
static NSString* kBookmarkCell = @"BookmarkCell";
static NSString* kUpNextCell = @"UpNextCell";
static NSString* kHeaderView = @"HeaderView";
static NSString* kFeedPropertyPreferredTranscriptLanguage = @"preferredTranscriptLanguage";
static NSString* kFeedPropertyPreferredTranscriptURL = @"preferredTranscriptURL";
static NSString* kTranscriptCacheFolderName = @"TranscriptCache";

static NSDictionary* ICTranscriptCueMake(NSTimeInterval start, NSTimeInterval end, NSString* text)
{
    if (text.length == 0 || start < 0) {
        return nil;
    }
    return @{ @"start": @(start), @"end": @(end), @"text": text };
}

static NSTimeInterval ICTranscriptParseTimecode(NSString* value)
{
    if (![value isKindOfClass:[NSString class]]) {
        return -1;
    }

    NSString* trimmed = [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (trimmed.length == 0) {
        return -1;
    }

    if ([trimmed hasSuffix:@"ms"]) {
        return [[trimmed substringToIndex:trimmed.length - 2] doubleValue] / 1000.0;
    }
    if ([trimmed hasSuffix:@"s"] && ![trimmed containsString:@":"]) {
        return [[trimmed substringToIndex:trimmed.length - 1] doubleValue];
    }
    if ([trimmed hasSuffix:@"m"] && ![trimmed containsString:@":"]) {
        return [[trimmed substringToIndex:trimmed.length - 1] doubleValue] * 60.0;
    }
    if ([trimmed hasSuffix:@"h"] && ![trimmed containsString:@":"]) {
        return [[trimmed substringToIndex:trimmed.length - 1] doubleValue] * 3600.0;
    }

    NSString* normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray* parts = [normalized componentsSeparatedByString:@":"];
    if (parts.count == 1) {
        return [parts[0] doubleValue];
    }

    double seconds = 0;
    NSInteger factor = 1;
    for (NSInteger idx = (NSInteger)parts.count - 1; idx >= 0; idx--) {
        seconds += [parts[idx] doubleValue] * factor;
        factor *= 60;
    }
    return seconds;
}

static NSString* ICTranscriptDecodedString(NSData* data)
{
    if (data.length == 0) {
        return nil;
    }

    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length > 0) {
        return text;
    }
    text = [[NSString alloc] initWithData:data encoding:NSUnicodeStringEncoding];
    if (text.length > 0) {
        return text;
    }
    text = [[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    if (text.length > 0) {
        return text;
    }
    text = [[NSString alloc] initWithData:data encoding:NSUTF16BigEndianStringEncoding];
    if (text.length > 0) {
        return text;
    }
    text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text;
}

static NSArray<NSDictionary*>* ICTranscriptNormalizeCues(NSArray<NSDictionary*>* cues)
{
    if (cues.count == 0) {
        return @[];
    }

    NSArray* sorted = [cues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* cue1, NSDictionary* cue2) {
        double s1 = [cue1[@"start"] doubleValue];
        double s2 = [cue2[@"start"] doubleValue];
        if (s1 < s2) {
            return NSOrderedAscending;
        }
        if (s1 > s2) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSMutableArray* normalized = [NSMutableArray arrayWithCapacity:sorted.count];
    for (NSInteger i = 0; i < (NSInteger)sorted.count; i++) {
        NSDictionary* cue = sorted[i];
        double start = [cue[@"start"] doubleValue];
        double end = [cue[@"end"] doubleValue];
        NSString* text = [cue[@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0 || start < 0) {
            continue;
        }

        if (!(end > start)) {
            if (i + 1 < (NSInteger)sorted.count) {
                double nextStart = [sorted[i + 1][@"start"] doubleValue];
                if (nextStart > start) {
                    end = nextStart;
                } else {
                    end = start + 2;
                }
            } else {
                end = start + 2;
            }
        }

        NSDictionary* normalizedCue = ICTranscriptCueMake(start, end, text);
        if (normalizedCue) {
            [normalized addObject:normalizedCue];
        }
    }

    return normalized;
}

static NSArray<NSDictionary*>* ICTranscriptParseArrowTimedText(NSString* text)
{
    if (text.length == 0) {
        return @[];
    }

    NSCharacterSet* ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray* rawLines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray* cues = [NSMutableArray array];
    NSInteger idx = 0;

    while (idx < (NSInteger)rawLines.count) {
        NSString* line = [rawLines[idx] stringByTrimmingCharactersInSet:ws];
        if (line.length == 0 || [line hasPrefix:@"WEBVTT"] || [line hasPrefix:@"NOTE"]) {
            idx++;
            continue;
        }

        if ([line rangeOfString:@"-->"].location == NSNotFound) {
            if (idx + 1 < (NSInteger)rawLines.count) {
                NSString* maybeTimeLine = [rawLines[idx + 1] stringByTrimmingCharactersInSet:ws];
                if ([maybeTimeLine rangeOfString:@"-->"].location != NSNotFound) {
                    line = maybeTimeLine;
                    idx++;
                } else {
                    idx++;
                    continue;
                }
            } else {
                break;
            }
        }

        NSArray* components = [line componentsSeparatedByString:@"-->"];
        if (components.count < 2) {
            idx++;
            continue;
        }

        NSString* startString = [components[0] stringByTrimmingCharactersInSet:ws];
        NSString* endSection = [components[1] stringByTrimmingCharactersInSet:ws];
        NSString* endString = [[endSection componentsSeparatedByCharactersInSet:ws] firstObject];

        NSTimeInterval start = ICTranscriptParseTimecode(startString);
        NSTimeInterval end = ICTranscriptParseTimecode(endString);
        idx++;

        NSMutableArray* lineParts = [NSMutableArray array];
        while (idx < (NSInteger)rawLines.count) {
            NSString* cueLine = rawLines[idx];
            NSString* trimmedCueLine = [cueLine stringByTrimmingCharactersInSet:ws];
            if (trimmedCueLine.length == 0) {
                idx++;
                break;
            }
            [lineParts addObject:trimmedCueLine];
            idx++;
        }

        NSString* cueText = [[lineParts componentsJoinedByString:@"\n"] stringByStrippingHTML];
        NSDictionary* cue = ICTranscriptCueMake(start, end, cueText);
        if (cue) {
            [cues addObject:cue];
        }
    }

    return ICTranscriptNormalizeCues(cues);
}

static NSArray<NSDictionary*>* ICTranscriptParseLRC(NSString* text)
{
    if (text.length == 0) {
        return @[];
    }

    NSRegularExpression* timeTagRegex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}:\\d{2}(?:[\\.:]\\d{1,3})?)\\]"
                                                                                   options:0
                                                                                     error:nil];
    NSArray* lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray* cues = [NSMutableArray array];
    NSCharacterSet* ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString* line in lines) {
        NSArray<NSTextCheckingResult*>* matches = [timeTagRegex matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (matches.count == 0) {
            continue;
        }

        NSString* cueText = [timeTagRegex stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        cueText = [[cueText stringByTrimmingCharactersInSet:ws] stringByStrippingHTML];
        if (cueText.length == 0) {
            continue;
        }

        for (NSTextCheckingResult* match in matches) {
            NSString* timeString = [line substringWithRange:[match rangeAtIndex:1]];
            NSDictionary* cue = ICTranscriptCueMake(ICTranscriptParseTimecode(timeString), 0, cueText);
            if (cue) {
                [cues addObject:cue];
            }
        }
    }

    return ICTranscriptNormalizeCues(cues);
}

static NSString* ICTranscriptXMLAttribute(NSString* attributes, NSString* key)
{
    if (attributes.length == 0 || key.length == 0) {
        return nil;
    }

    NSString* pattern = [NSString stringWithFormat:@"%@\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]", key];
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
    NSTextCheckingResult* match = [regex firstMatchInString:attributes options:0 range:NSMakeRange(0, attributes.length)];
    if (!match || [match numberOfRanges] < 2) {
        return nil;
    }
    return [attributes substringWithRange:[match rangeAtIndex:1]];
}

static NSArray<NSDictionary*>* ICTranscriptParseTTML(NSString* text)
{
    if (text.length == 0) {
        return @[];
    }

    NSRegularExpression* pTagRegex = [NSRegularExpression regularExpressionWithPattern:@"<p\\b([^>]*)>(.*?)</p>"
                                                                                options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                  error:nil];
    NSMutableArray* cues = [NSMutableArray array];
    NSArray<NSTextCheckingResult*>* matches = [pTagRegex matchesInString:text options:0 range:NSMakeRange(0, text.length)];

    for (NSTextCheckingResult* match in matches) {
        if ([match numberOfRanges] < 3) {
            continue;
        }
        NSString* attrs = [text substringWithRange:[match rangeAtIndex:1]];
        NSString* inner = [text substringWithRange:[match rangeAtIndex:2]];
        NSString* startString = ICTranscriptXMLAttribute(attrs, @"begin");
        NSString* endString = ICTranscriptXMLAttribute(attrs, @"end");
        NSString* durString = ICTranscriptXMLAttribute(attrs, @"dur");
        NSTimeInterval start = ICTranscriptParseTimecode(startString);
        NSTimeInterval end = ICTranscriptParseTimecode(endString);
        if (!(end > start) && durString.length > 0) {
            NSTimeInterval duration = ICTranscriptParseTimecode(durString);
            if (duration > 0) {
                end = start + duration;
            }
        }

        NSString* cueText = [inner stringByReplacingOccurrencesOfString:@"<br/>" withString:@"\n"];
        cueText = [cueText stringByReplacingOccurrencesOfString:@"<br />" withString:@"\n"];
        cueText = [cueText stringByStrippingHTML];
        NSDictionary* cue = ICTranscriptCueMake(start, end, cueText);
        if (cue) {
            [cues addObject:cue];
        }
    }

    return ICTranscriptNormalizeCues(cues);
}

static NSTimeInterval ICTranscriptTimeFromJSONValue(id value)
{
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value doubleValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return ICTranscriptParseTimecode((NSString*)value);
    }
    return -1;
}

static NSString* ICTranscriptStringFromJSONDictionary(NSDictionary* dict)
{
    NSArray* keys = @[ @"text", @"value", @"line", @"cue", @"utterance", @"transcript" ];
    for (NSString* key in keys) {
        id value = dict[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString*)value length] > 0) {
            return (NSString*)value;
        }
    }
    return nil;
}

static void ICTranscriptCollectJSONCues(id object, NSMutableArray<NSDictionary*>* cues)
{
    if ([object isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray*)object) {
            ICTranscriptCollectJSONCues(entry, cues);
        }
        return;
    }

    if (![object isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary* dict = (NSDictionary*)object;
    NSArray* startKeys = @[ @"start", @"startTime", @"start_time", @"begin", @"from", @"t" ];
    NSArray* endKeys = @[ @"end", @"endTime", @"end_time", @"to", @"until" ];
    NSArray* durationKeys = @[ @"duration", @"dur", @"d" ];

    NSTimeInterval start = -1;
    NSTimeInterval end = -1;
    NSTimeInterval duration = -1;

    for (NSString* key in startKeys) {
        start = ICTranscriptTimeFromJSONValue(dict[key]);
        if (start >= 0) {
            break;
        }
    }
    for (NSString* key in endKeys) {
        end = ICTranscriptTimeFromJSONValue(dict[key]);
        if (end >= 0) {
            break;
        }
    }
    for (NSString* key in durationKeys) {
        duration = ICTranscriptTimeFromJSONValue(dict[key]);
        if (duration >= 0) {
            break;
        }
    }

    if (start >= 0 && !(end > start) && duration > 0) {
        end = start + duration;
    }

    NSString* cueText = ICTranscriptStringFromJSONDictionary(dict);
    NSDictionary* cue = ICTranscriptCueMake(start, end, [cueText stringByStrippingHTML]);
    if (cue) {
        [cues addObject:cue];
    }

    for (id value in dict.allValues) {
        ICTranscriptCollectJSONCues(value, cues);
    }
}

static NSArray<NSDictionary*>* ICTranscriptParseJSON(NSData* data)
{
    if (data.length == 0) {
        return @[];
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!json) {
        return @[];
    }

    NSMutableArray* cues = [NSMutableArray array];
    ICTranscriptCollectJSONCues(json, cues);
    return ICTranscriptNormalizeCues(cues);
}

static NSArray<NSDictionary*>* ICTranscriptParsePlainText(NSString* text)
{
    if (text.length == 0) {
        return @[];
    }

    NSString* normalized = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    normalized = [[normalized stringByStrippingHTML] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (normalized.length == 0) {
        return @[];
    }

    // Static transcript fallback: no timing metadata available.
    NSDictionary* cue = ICTranscriptCueMake(0, 3153600000.0, normalized);
    return cue ? @[cue] : @[];
}

static BOOL ICTranscriptTypeContains(NSString* value, NSString* token)
{
    if (value.length == 0 || token.length == 0) {
        return NO;
    }
    return ([[value lowercaseString] rangeOfString:[token lowercaseString]].location != NSNotFound);
}

enum {
    kChaptersSection = 0,
    kBookmarksSection,
    kUpNextSection,
    kNumberOfSections
};



@interface PlayerInfoViewController_v5 () <UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate>
@property (nonatomic, strong, readwrite) UIImageView* imageView;

@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong) NSArray* chapters;
@property (nonatomic) NSInteger	currentChapterIndex;
@property (nonatomic, strong) NSArray* bookmarks;
@property (nonatomic, strong) NSMutableDictionary<NSValue*, UIColor*>* averageColorCache;
@property (nonatomic, readwrite) BOOL transcriptVisible;
@property (nonatomic) BOOL transcriptAvailable;
@property (nonatomic, strong) UIView* transcriptContainerView;

@property (nonatomic, strong) UITextView* transcriptTextView;
@property (nonatomic, strong) UIButton* transcriptPickerButton;
@property (nonatomic, strong) NSArray<NSValue*>* transcriptCueRanges;
@property (nonatomic, strong) NSArray<NSDictionary*>* transcriptSources;
@property (nonatomic, strong) NSArray<NSDictionary*>* transcriptCues;
@property (nonatomic, strong) NSDictionary* selectedTranscriptDescriptor;
@property (nonatomic) NSInteger activeTranscriptCueIndex;
@property (nonatomic, strong) NSURLSessionDataTask* transcriptTask;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSURLSessionDataTask*>* transcriptPrefetchTasks;
@property (nonatomic, strong) NSTimer* transcriptFollowResumeTimer;
@property (nonatomic, strong) NSTimer* transcriptSyncTimer;
@property (nonatomic) BOOL transcriptAutoFollowSuspended;
@property (nonatomic) BOOL transcriptWasPaused;
@property (nonatomic) BOOL pendingTranscriptShowAfterScrollToTop;
@property (nonatomic, copy) NSString* transcriptDataEpisodeHash;
@property (nonatomic, copy) NSString* transcriptLoadedEpisodeHash;

- (NSInteger)_transcriptUtilityRankForDescriptor:(NSDictionary*)descriptor;
- (void)_updateTranscriptSyncTimerState;
- (void)_removeTranscriptCacheForEpisode:(CDEpisode*)episode;
- (void)_appendTranscriptURLAttemptForRawValue:(NSString*)rawValue
                                       episode:(CDEpisode*)episode
                                      attempts:(NSMutableOrderedSet<NSString*>*)attempts;
@end


// Static in-memory cache for parsed transcript cues — survives across player open/close cycles
static NSString* s_transcriptCachedEpisodeHash;
static NSArray<NSDictionary*>* s_transcriptCachedCues;
static NSDictionary* s_transcriptCachedDescriptor;
static NSArray<NSDictionary*>* s_transcriptCachedSources;
static NSAttributedString* s_transcriptCachedAttrString;
static NSArray<NSValue*>* s_transcriptCachedRanges;

@implementation PlayerInfoViewController_v5 {
    BOOL _observing;
    CGPoint _oldContentOffset;
    CGPoint _oldScrollVelocity;
    BOOL _dismissEnded;
    CGFloat _startY;
    BOOL _didWillAppear;
    NSString* _transcriptLoadingURL;
    NSInteger _previousTranscriptCueIndex;
    CGSize _lastTranscriptBoundsSize;
}

+ (instancetype) viewController {
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void) dealloc
{
    [self.transcriptTask cancel];
    for (NSURLSessionDataTask* task in self.transcriptPrefetchTasks.allValues) {
        [task cancel];
    }
    [self.transcriptPrefetchTasks removeAllObjects];
    [self.transcriptFollowResumeTimer invalidate];
    [self.transcriptSyncTimer invalidate];
    [self _setObserving:NO];
}

- (void) _setObserving:(BOOL)observing
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    
    if (observing && !_observing)
    {
        __weak PlayerInfoViewController_v5* weakSelf = self;
        
        [pman addTaskObserver:self forKeyPath:@"playingEpisode.duration" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.duration = pman.playingEpisode.duration;
        }];
        
        [pman addTaskObserver:self forKeyPath:@"playingEpisode.chapters" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.chapters = [pman.playingEpisode sortedChapters];
            weakSelf.duration = pman.duration;
        }];

        [pman addTaskObserver:self forKeyPath:@"artworks" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            if ([pman.artworks count] > 0) {
                self->chapterImagesArray = pman.artworks;
                // +1 for episode artwork at index 0
                [self.chapterImagesCollection reloadData];
                // Stay on episode artwork (index 0) until currentArtwork changes
            }
        }];

        [pman addTaskObserver:self forKeyPath:@"currentArtwork" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            if (self->chapterImagesArray.count > 0) {
                // currentArtwork -1 = no chapter image active, show episode artwork (index 0)
                // currentArtwork 0+ maps to collection index 1+
                NSUInteger collectionIndex = (pman.currentArtwork >= 0) ? pman.currentArtwork + 1 : 0;
                [weakSelf changeChapterImageIndex:collectionIndex];
            }
        }];
        
        [pman addTaskObserver:self forKeyPath:@"time" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateVisibleCells];
        }];
        
        [pman addTaskObserver:self forKeyPath:@"currentChapter" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.currentChapterIndex = pman.currentChapter;
        }];

        [pman addTaskObserver:self forKeyPath:@"playingEpisode.consumed" task:^(id obj, NSDictionary *change) {
            (void)obj;
            (void)change;
            PlaybackManager* pman = [PlaybackManager playbackManager];
            CDEpisode* episode = pman.playingEpisode ?: [AudioSession sharedAudioSession].episode;
            if (episode.consumed) {
                [weakSelf _removeTranscriptCacheForEpisode:episode];
            }
        }];
        
        [nc addObserver:self selector:@selector(databaseManagerDidAddBookmarkNotification:) name:DatabaseManagerDidAddBookmarkNotification object:nil];
        [nc addObserver:self selector:@selector(playbackManagerDidChangeEpisodeNotification:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(audioSessionDidRestorePlaybackNotification:) name:AudioSessionDidRestorePlaybackNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidClearCacheNotification:) name:CacheManagerDidClearCacheNotification object:nil];
        [nc addObserver:self selector:@selector(_playbackDidUpdateForTranscriptFollow:) name:PlaybackManagerDidUpdateNotification object:nil];

        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [pman removeTaskObserver:self forKeyPath:@"playingEpisode.duration"];
        [pman removeTaskObserver:self forKeyPath:@"playingEpisode.chapters"];
        [pman removeTaskObserver:self forKeyPath:@"artworks"];
        [pman removeTaskObserver:self forKeyPath:@"currentArtwork"];
        [pman removeTaskObserver:self forKeyPath:@"time"];
        [pman removeTaskObserver:self forKeyPath:@"currentChapter"];
        [pman removeTaskObserver:self forKeyPath:@"playingEpisode.consumed"];

        [nc removeObserver:self];

        _observing = NO;
    }
}

- (void) databaseManagerDidAddBookmarkNotification:(NSNotification*)notification
{
    (void)notification;
    [self reloadBookmarks];
    if (!self.isViewLoaded || self.view.window == nil) {
        return;
    }
    [self layoutHeaderView];
    [self.tableView reloadData];
}

- (void) playbackManagerDidChangeEpisodeNotification:(NSNotification*)notification
{
    (void)notification;
    PlaybackManager* pman = [PlaybackManager playbackManager];
    chapterImagesArray = pman.artworks ?: @[];
    [self reloadData];
    if (!self.isViewLoaded || self.view.window == nil) {
        return;
    }
    [self layoutHeaderView];
    [self.tableView reloadData];
}

- (void) audioSessionDidRestorePlaybackNotification:(NSNotification*)notification
{
    (void)notification;
    if (!self.isViewLoaded || self.view.window == nil) {
        DebugLog(@"[TranscriptData] restore playback ignored (view not visible)");
        return;
    }

    PlaybackManager* pman = [PlaybackManager playbackManager];
    CDEpisode* episode = pman.playingEpisode ?: [AudioSession sharedAudioSession].episode;
    NSString* currentEpisodeHash = episode.objectHash;
    BOOL episodeChanged = (currentEpisodeHash.length > 0 && ![currentEpisodeHash isEqualToString:self.transcriptDataEpisodeHash]);
    DebugLog(@"[TranscriptData] restore playback episode=%@ tracked=%@ changed=%@ available=%@",
             currentEpisodeHash ?: @"(nil)",
             self.transcriptDataEpisodeHash ?: @"(nil)",
             episodeChanged ? @"YES" : @"NO",
             self.transcriptAvailable ? @"YES" : @"NO");
    if (episodeChanged) {
        [self reloadData];
    } else if (self.transcriptAvailable) {
        [self _updateTranscriptCueForPlaybackTime:pman.time animated:NO];
    }
    [self layoutHeaderView];
    [self.tableView reloadData];
}

- (void)cacheManagerDidClearCacheNotification:(NSNotification*)notification
{
    CDEpisode* clearedEpisode = [notification.userInfo[@"episode"] isKindOfClass:[CDEpisode class]] ? notification.userInfo[@"episode"] : nil;
    if (clearedEpisode) {
        [self _removeTranscriptCacheForEpisode:clearedEpisode];
    } else {
        [self _clearAllTranscriptCache];
    }
}

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    self.bottomScrollInset = self.navigationController.toolbarHidden?0:44;
    
    self.tableView.separatorInset = UIEdgeInsetsZero;
    self.tableView.allowsSelectionDuringEditing = YES;
    if (@available(iOS 11.0, *)) {
        self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.tableView registerClass:[ChaptersTableViewCell class] forCellReuseIdentifier:kChapterCell];
    [self.tableView registerClass:[PlayerBookmarksTableViewCell class] forCellReuseIdentifier:kBookmarkCell];
    [self.tableView registerClass:[EpisodesTableViewCell class] forCellReuseIdentifier:kUpNextCell];
    [self.tableView registerClass:[PlayerInfoHeaderFooterView class] forHeaderFooterViewReuseIdentifier:kHeaderView];
    
    UIImage* placeholder = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? [UIImage imageNamed:@"Podcast Placeholder 580"] : [UIImage imageNamed:@"Podcast Placeholder 320"];
    self.imageView = [[UIImageView alloc] initWithImage:(self.image) ? self.image : placeholder];
    self.chapterView = [[UIView alloc] init];
    self.chapterView.backgroundColor = [UIColor clearColor];
    
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
    layout.itemSize = CGSizeMake(MAX(self.view.bounds.size.width, 1), MAX(self.view.bounds.size.width, 1));
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    [layout setMinimumInteritemSpacing:0.0f];
    [layout setMinimumLineSpacing:0.0f];
    self.chapterImagesCollection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    [self.chapterImagesCollection registerClass:[ChapterImageCell class] forCellWithReuseIdentifier: @"chapter_cell"];
    [self.chapterImagesCollection registerNib:[UINib nibWithNibName:@"ChapterImageCell" bundle:nil]  forCellWithReuseIdentifier:@"chapter_cell"];
    self.chapterImagesCollection.backgroundColor = [UIColor clearColor];
    self.chapterImagesCollection.showsHorizontalScrollIndicator = NO;
    self.chapterImagesCollection.showsVerticalScrollIndicator = NO;
    [self.chapterImagesCollection setPagingEnabled:YES];

    self.transcriptContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.transcriptContainerView.backgroundColor = [UIColor clearColor];
    self.transcriptContainerView.hidden = YES;

    self.transcriptTextView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.transcriptTextView.editable = NO;
    self.transcriptTextView.selectable = NO;
    self.transcriptTextView.scrollEnabled = YES; // lazy text layout — only visible text is rendered
    self.transcriptTextView.backgroundColor = [UIColor clearColor];
    self.transcriptTextView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.transcriptTextView.textContainer.lineFragmentPadding = 0;
    self.transcriptTextView.alwaysBounceVertical = YES;
    self.transcriptTextView.showsVerticalScrollIndicator = YES;
    self.transcriptTextView.delegate = self;
    self.transcriptTextView.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer* transcriptTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_transcriptTextViewTapped:)];
    [self.transcriptTextView addGestureRecognizer:transcriptTap];
    [self.transcriptContainerView addSubview:self.transcriptTextView];

    [NSLayoutConstraint activateConstraints:@[
        [self.transcriptTextView.topAnchor constraintEqualToAnchor:self.transcriptContainerView.topAnchor],
        [self.transcriptTextView.leadingAnchor constraintEqualToAnchor:self.transcriptContainerView.leadingAnchor],
        [self.transcriptTextView.trailingAnchor constraintEqualToAnchor:self.transcriptContainerView.trailingAnchor],
        [self.transcriptTextView.bottomAnchor constraintEqualToAnchor:self.transcriptContainerView.bottomAnchor]
    ]];

    UIButton* pickerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    pickerButton.backgroundColor = [UIColor clearColor];
    pickerButton.layer.cornerRadius = 0;
    pickerButton.layer.masksToBounds = NO;
    pickerButton.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 0);
    pickerButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [pickerButton setTitleColor:ICMutedTextColor forState:UIControlStateNormal];
    UIImageSymbolConfiguration* chevronConfig = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    UIImage* pickerChevronImage = [[UIImage systemImageNamed:@"chevron.down" withConfiguration:chevronConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [pickerButton setImage:pickerChevronImage forState:UIControlStateNormal];
    pickerButton.tintColor = ICMutedTextColor;
    pickerButton.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    pickerButton.imageEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
    pickerButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    [pickerButton setTitle:@"Transcript".ls forState:UIControlStateNormal];
    [pickerButton addTarget:self action:@selector(showTranscriptPicker:) forControlEvents:UIControlEventTouchUpInside];
    pickerButton.hidden = YES;
    [self.transcriptContainerView addSubview:pickerButton];
    self.transcriptPickerButton = pickerButton;

    self.transcriptCueRanges = @[];
    self.transcriptCues = @[];
    self.transcriptSources = @[];
    self.transcriptPrefetchTasks = [NSMutableDictionary dictionary];
    self.activeTranscriptCueIndex = NSNotFound;
    _previousTranscriptCueIndex = NSNotFound;
    self.transcriptVisible = NO;

    // Chevron indicator below chapter image
    CGFloat chevronWidth = 22.0f;
    CGFloat chevronHeight = 8.0f;
    CGFloat strokeWidth = 2.0f;
    CGFloat padding = ceilf(strokeWidth / 2.0f);
    CGSize imageSize = CGSizeMake(chevronWidth + padding * 2, chevronHeight + padding * 2);
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 0);
    UIBezierPath* chevronPath = [UIBezierPath bezierPath];
    [chevronPath moveToPoint:CGPointMake(padding, padding)];
    [chevronPath addLineToPoint:CGPointMake(padding + chevronWidth / 2.0f, padding + chevronHeight)];
    [chevronPath addLineToPoint:CGPointMake(padding + chevronWidth, padding)];
    chevronPath.lineWidth = strokeWidth;
    chevronPath.lineCapStyle = kCGLineCapRound;
    chevronPath.lineJoinStyle = kCGLineJoinRound;
    [[UIColor whiteColor] setStroke];
    [chevronPath stroke];
    UIImage* chevronImage = [UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsEndImageContext();

    chevronIndicatorView = [[UIImageView alloc] initWithImage:chevronImage];
    chevronIndicatorView.tintColor = ICMutedTextColor;
    chevronIndicatorView.contentMode = UIViewContentModeCenter;
    [self.chapterView addSubview:chevronIndicatorView];

    [self reloadData];

    [self _setObserving:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationDidChange) name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self layoutHeaderView];
    } completion:nil];
}

- (void)_setTranscriptAvailableState:(BOOL)available
{
    if (_transcriptAvailable == available) {
        return;
    }

    _transcriptAvailable = available;
    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    DebugLog(@"[TranscriptData] available state changed: %@ episode=%@ sources=%ld cues=%ld visible=%@",
             available ? @"YES" : @"NO",
             episode.objectHash ?: @"(nil)",
             (long)self.transcriptSources.count,
             (long)self.transcriptCues.count,
             self.transcriptVisible ? @"YES" : @"NO");
    if (!available) {
        self.pendingTranscriptShowAfterScrollToTop = NO;
        self.transcriptVisible = NO;
        [self _applyTranscriptVisibility];
        [self _updateTranscriptSyncTimerState];
    }
    if (self.transcriptAvailabilityDidChange) {
        self.transcriptAvailabilityDidChange(available);
    }
}

- (void)_applyTranscriptVisibility
{
    self.transcriptContainerView.hidden = !self.transcriptVisible;
    self.chapterImagesCollection.hidden = self.transcriptVisible;
    chevronIndicatorView.hidden = ![self _hasContentBelowImage];
    DebugLog(@"[TranscriptUI] apply visibility visible=%@ containerHidden=%@ chapterHidden=%@",
             self.transcriptVisible ? @"YES" : @"NO",
             self.transcriptContainerView.hidden ? @"YES" : @"NO",
             self.chapterImagesCollection.hidden ? @"YES" : @"NO");
    [self _updateTranscriptSyncTimerState];
}

- (NSArray<NSDictionary*>*)_normalizedTranscriptSourcesForEpisode:(CDEpisode*)episode
{
    NSMutableArray* sources = [NSMutableArray array];
    NSArray* rawSources = [episode.transcripts isKindOfClass:[NSArray class]] ? episode.transcripts : @[];
    DebugLog(@"[TranscriptData] normalize sources episode=%@ rawCount=%ld",
             episode.objectHash ?: @"(nil)",
             (long)rawSources.count);
    for (id item in rawSources) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary* source = (NSDictionary*)item;
        NSString* url = [source[@"url"] isKindOfClass:[NSString class]] ? source[@"url"] : nil;
        if (url.length == 0) {
            continue;
        }
        NSMutableDictionary* normalized = [NSMutableDictionary dictionaryWithObject:url forKey:@"url"];
        NSString* type = [source[@"type"] isKindOfClass:[NSString class]] ? [source[@"type"] lowercaseString] : nil;
        NSString* language = [source[@"language"] isKindOfClass:[NSString class]] ? [source[@"language"] lowercaseString] : nil;
        NSString* rel = [source[@"rel"] isKindOfClass:[NSString class]] ? [source[@"rel"] lowercaseString] : nil;
        NSString* title = [source[@"title"] isKindOfClass:[NSString class]] ? source[@"title"] : nil;
        NSString* fallbackURL = [source[@"fallbackURL"] isKindOfClass:[NSString class]] ? source[@"fallbackURL"] : nil;
        NSString* href = [source[@"href"] isKindOfClass:[NSString class]] ? source[@"href"] : nil;
        if (type.length > 0) normalized[@"type"] = type;
        if (language.length > 0) normalized[@"language"] = language;
        if (rel.length > 0) normalized[@"rel"] = rel;
        if (title.length > 0) normalized[@"title"] = title;
        if (fallbackURL.length > 0) normalized[@"fallbackURL"] = fallbackURL;
        if (href.length > 0) normalized[@"href"] = href;
        [sources addObject:normalized];
    }
    [sources sortUsingComparator:^NSComparisonResult(NSDictionary* source1, NSDictionary* source2) {
        NSInteger rank1 = [self _transcriptUtilityRankForDescriptor:source1];
        NSInteger rank2 = [self _transcriptUtilityRankForDescriptor:source2];
        if (rank1 < rank2) return NSOrderedAscending;
        if (rank1 > rank2) return NSOrderedDescending;

        NSString* language1 = [source1[@"language"] isKindOfClass:[NSString class]] ? source1[@"language"] : @"";
        NSString* language2 = [source2[@"language"] isKindOfClass:[NSString class]] ? source2[@"language"] : @"";
        NSComparisonResult languageResult = [language1 localizedCaseInsensitiveCompare:language2];
        if (languageResult != NSOrderedSame) {
            return languageResult;
        }

        NSString* title1 = [source1[@"title"] isKindOfClass:[NSString class]] ? source1[@"title"] : @"";
        NSString* title2 = [source2[@"title"] isKindOfClass:[NSString class]] ? source2[@"title"] : @"";
        return [title1 localizedCaseInsensitiveCompare:title2];
    }];
    for (NSDictionary* source in sources) {
        DebugLog(@"[TranscriptData] source url=%@ type=%@ lang=%@ rel=%@ title=%@ fallback=%@ href=%@",
                 source[@"url"] ?: @"",
                 source[@"type"] ?: @"",
                 source[@"language"] ?: @"",
                 source[@"rel"] ?: @"",
                 source[@"title"] ?: @"",
                 source[@"fallbackURL"] ?: @"",
                 source[@"href"] ?: @"");
    }
    return sources;
}

- (NSInteger)_languageMatchScoreForPreferredLanguage:(NSString*)preferred candidate:(NSString*)candidate
{
    if (preferred.length == 0 || candidate.length == 0) {
        return 0;
    }

    NSString* preferredLower = [preferred lowercaseString];
    NSString* candidateLower = [candidate lowercaseString];
    if ([preferredLower isEqualToString:candidateLower]) {
        return 3;
    }

    NSArray* preferredParts = [preferredLower componentsSeparatedByString:@"-"];
    NSString* preferredBase = preferredParts.firstObject;
    NSArray* candidateParts = [candidateLower componentsSeparatedByString:@"-"];
    NSString* candidateBase = candidateParts.firstObject;
    if (preferredBase.length > 0 && [preferredBase isEqualToString:candidateBase]) {
        return 2;
    }

    if ([preferredLower hasPrefix:candidateLower] || [candidateLower hasPrefix:preferredLower]) {
        return 1;
    }
    return 0;
}

- (NSDictionary*)_preferredTranscriptDescriptorFromSources:(NSArray<NSDictionary*>*)sources
{
    if (sources.count == 0) {
        return nil;
    }

    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    CDFeed* feed = episode.feed;

    NSString* preferredURL = [feed stringForKey:kFeedPropertyPreferredTranscriptURL];
    if (preferredURL.length > 0) {
        for (NSDictionary* source in sources) {
            if ([source[@"url"] isEqualToString:preferredURL]) {
                return source;
            }
        }
    }

    NSString* preferredLanguage = [feed stringForKey:kFeedPropertyPreferredTranscriptLanguage];
    if (preferredLanguage.length > 0) {
        NSInteger bestScore = 0;
        NSDictionary* bestSource = nil;
        for (NSDictionary* source in sources) {
            NSInteger score = [self _languageMatchScoreForPreferredLanguage:preferredLanguage candidate:source[@"language"]];
            if (score > bestScore) {
                bestScore = score;
                bestSource = source;
            }
        }
        if (bestSource) {
            return bestSource;
        }
    }

    for (NSString* preferredDeviceLanguage in [NSLocale preferredLanguages]) {
        NSInteger bestScore = 0;
        NSDictionary* bestSource = nil;
        for (NSDictionary* source in sources) {
            NSInteger score = [self _languageMatchScoreForPreferredLanguage:preferredDeviceLanguage candidate:source[@"language"]];
            if (score > bestScore) {
                bestScore = score;
                bestSource = source;
            }
        }
        if (bestSource) {
            return bestSource;
        }
    }

    return sources.firstObject;
}

- (NSArray<NSDictionary*>*)_orderedTranscriptCandidatesFromSources:(NSArray<NSDictionary*>*)sources preferred:(NSDictionary*)preferred
{
    if (sources.count == 0) {
        return @[];
    }
    if (!preferred) {
        return sources;
    }

    NSMutableArray* ordered = [NSMutableArray arrayWithObject:preferred];
    for (NSDictionary* source in sources) {
        if (![source[@"url"] isEqualToString:preferred[@"url"]]) {
            [ordered addObject:source];
        }
    }
    return ordered;
}

- (NSString*)_transcriptFormatNameForDescriptor:(NSDictionary*)descriptor
{
    NSString* type = [descriptor[@"type"] lowercaseString];
    NSString* urlString = descriptor[@"url"];
    NSString* ext = [[NSURL URLWithString:urlString].pathExtension lowercaseString];
    NSString* token = (type.length > 0) ? type : ext;

    if (ICTranscriptTypeContains(token, @"vtt")) return @"VTT";
    if (ICTranscriptTypeContains(token, @"subrip") || [ext isEqualToString:@"srt"]) return @"SRT";
    if ([ext isEqualToString:@"lrc"]) return @"LRC";
    if (ICTranscriptTypeContains(token, @"ttml") || [ext isEqualToString:@"ttml"] || [ext isEqualToString:@"dfxp"] || ICTranscriptTypeContains(token, @"xml")) return @"TTML";
    if (ICTranscriptTypeContains(token, @"json") || [ext isEqualToString:@"json"]) return @"JSON";
    if (ICTranscriptTypeContains(token, @"plain") || [ext isEqualToString:@"txt"]) return @"TXT";
    return @"";
}

- (NSInteger)_transcriptUtilityRankForDescriptor:(NSDictionary*)descriptor
{
    NSString* format = [self _transcriptFormatNameForDescriptor:descriptor];
    if ([format isEqualToString:@"SRT"]) return 0;
    if ([format isEqualToString:@"VTT"]) return 1;
    if ([format isEqualToString:@"JSON"]) return 2;
    if ([format isEqualToString:@"TXT"]) return 3;
    return 4;
}

- (NSString*)_transcriptDisplayNameForDescriptor:(NSDictionary*)descriptor
{
    NSString* title = descriptor[@"title"];
    NSString* language = descriptor[@"language"];
    NSString* format = [self _transcriptFormatNameForDescriptor:descriptor];

    NSString* name = nil;
    if (title.length > 0) {
        name = title;
    } else if (language.length > 0) {
        NSString* localizedLanguage = [[NSLocale currentLocale] displayNameForKey:NSLocaleIdentifier value:language];
        name = localizedLanguage.length > 0 ? localizedLanguage : language.uppercaseString;
    } else {
        name = @"Transcript".ls;
    }

    if (format.length > 0) {
        return [NSString stringWithFormat:@"%@ (%@)", name, format];
    }
    return name;
}

- (void)_updateTranscriptPickerButton
{
    NSString* title = (self.selectedTranscriptDescriptor != nil) ? [self _transcriptDisplayNameForDescriptor:self.selectedTranscriptDescriptor] : @"Transcript".ls;
    [self.transcriptPickerButton setTitle:title forState:UIControlStateNormal];
    self.transcriptPickerButton.hidden = YES;
    DebugLog(@"[TranscriptUI] picker title='%@' hidden=%@ sources=%ld selected=%@",
             title,
             self.transcriptPickerButton.hidden ? @"YES" : @"NO",
             (long)self.transcriptSources.count,
             self.selectedTranscriptDescriptor[@"url"] ?: @"");
}

- (NSURL*)_transcriptCacheDirectoryURLCreate:(BOOL)create
{
    NSURL* appSupportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    if (!appSupportURL) {
        return nil;
    }

    NSURL* directoryURL = [appSupportURL URLByAppendingPathComponent:kTranscriptCacheFolderName isDirectory:YES];
    if (create) {
        [[NSFileManager defaultManager] createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
        [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    return directoryURL;
}

- (NSURL*)_transcriptCacheFileURLForEpisodeHash:(NSString*)episodeHash resolvedURL:(NSString*)resolvedURL createDirectory:(BOOL)createDirectory
{
    if (episodeHash.length == 0 || resolvedURL.length == 0) {
        return nil;
    }

    NSURL* directoryURL = [self _transcriptCacheDirectoryURLCreate:createDirectory];
    if (!directoryURL) {
        return nil;
    }

    NSString* fileName = [NSString stringWithFormat:@"%@_%@.trcache", episodeHash, [resolvedURL MD5Hash]];
    return [directoryURL URLByAppendingPathComponent:fileName];
}

- (NSData*)_cachedTranscriptDataForEpisodeHash:(NSString*)episodeHash resolvedURL:(NSString*)resolvedURL
{
    NSURL* cacheFileURL = [self _transcriptCacheFileURLForEpisodeHash:episodeHash resolvedURL:resolvedURL createDirectory:NO];
    if (!cacheFileURL) {
        return nil;
    }
    return [NSData dataWithContentsOfURL:cacheFileURL];
}

- (void)_storeTranscriptData:(NSData*)data forEpisodeHash:(NSString*)episodeHash resolvedURL:(NSString*)resolvedURL
{
    if (data.length == 0 || episodeHash.length == 0 || resolvedURL.length == 0) {
        return;
    }

    NSURL* cacheFileURL = [self _transcriptCacheFileURLForEpisodeHash:episodeHash resolvedURL:resolvedURL createDirectory:YES];
    if (!cacheFileURL) {
        return;
    }

    [data writeToURL:cacheFileURL atomically:YES];
}

- (void)_removeTranscriptCacheForEpisodeHash:(NSString*)episodeHash resolvedURL:(NSString*)resolvedURL
{
    NSURL* cacheFileURL = [self _transcriptCacheFileURLForEpisodeHash:episodeHash resolvedURL:resolvedURL createDirectory:NO];
    if (!cacheFileURL) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtURL:cacheFileURL error:nil];
}

- (void)_removeTranscriptCacheForEpisode:(CDEpisode*)episode
{
    NSString* episodeHash = episode.objectHash;
    if (episodeHash.length == 0) {
        return;
    }

    // Clear static in-memory cache if it matches
    if ([episodeHash isEqualToString:s_transcriptCachedEpisodeHash]) {
        s_transcriptCachedEpisodeHash = nil;
        s_transcriptCachedCues = nil;
        s_transcriptCachedDescriptor = nil;
        s_transcriptCachedSources = nil;
        s_transcriptCachedAttrString = nil;
        s_transcriptCachedRanges = nil;
    }

    NSURL* directoryURL = [self _transcriptCacheDirectoryURLCreate:NO];
    if (!directoryURL) {
        return;
    }

    NSArray<NSURL*>* fileURLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directoryURL
                                                               includingPropertiesForKeys:nil
                                                                                  options:0
                                                                                    error:nil];
    NSString* prefix = [NSString stringWithFormat:@"%@_", episodeHash];
    for (NSURL* fileURL in fileURLs) {
        NSString* fileName = fileURL.lastPathComponent;
        if ([fileName hasPrefix:prefix]) {
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
        }
    }
}

- (void)_clearAllTranscriptCache
{
    // Clear static in-memory cache
    s_transcriptCachedEpisodeHash = nil;
    s_transcriptCachedCues = nil;
    s_transcriptCachedDescriptor = nil;
    s_transcriptCachedSources = nil;
    s_transcriptCachedAttrString = nil;
    s_transcriptCachedRanges = nil;

    NSURL* directoryURL = [self _transcriptCacheDirectoryURLCreate:NO];
    if (!directoryURL) {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtURL:directoryURL error:nil];
}

- (void)_clearTranscriptCacheIfNeededForEpisode:(CDEpisode*)episode
{
    if (episode.consumed) {
        [self _removeTranscriptCacheForEpisode:episode];
    }
}

- (NSString*)_transcriptPrefetchTaskKeyForEpisodeHash:(NSString*)episodeHash resolvedURL:(NSString*)resolvedURL
{
    if (episodeHash.length == 0 || resolvedURL.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@|%@", episodeHash, resolvedURL];
}

- (void)_cancelTranscriptPrefetchTasks
{
    for (NSURLSessionDataTask* task in self.transcriptPrefetchTasks.allValues) {
        [task cancel];
    }
    [self.transcriptPrefetchTasks removeAllObjects];
}

- (void)_prefetchTranscriptDescriptor:(NSDictionary*)descriptor
                              episode:(CDEpisode*)episode
                             attempts:(NSArray<NSString*>*)attempts
                             urlIndex:(NSInteger)urlIndex
{
    if (!episode || episode.consumed || urlIndex >= (NSInteger)attempts.count) {
        return;
    }

    NSString* episodeHash = episode.objectHash;
    NSString* urlString = attempts[urlIndex];
    if (episodeHash.length == 0 || urlString.length == 0) {
        [self _prefetchTranscriptDescriptor:descriptor episode:episode attempts:attempts urlIndex:urlIndex + 1];
        return;
    }
    if ([_transcriptLoadingURL isEqualToString:urlString]) {
        return;
    }
    NSString* selectedResolvedURL = [self.selectedTranscriptDescriptor[@"resolvedURL"] isKindOfClass:[NSString class]] ? self.selectedTranscriptDescriptor[@"resolvedURL"] : nil;
    if ([selectedResolvedURL isEqualToString:urlString]) {
        return;
    }

    if ([self _cachedTranscriptDataForEpisodeHash:episodeHash resolvedURL:urlString].length > 0) {
        return;
    }

    NSString* taskKey = [self _transcriptPrefetchTaskKeyForEpisodeHash:episodeHash resolvedURL:urlString];
    if (taskKey.length == 0 || self.transcriptPrefetchTasks[taskKey] != nil) {
        return;
    }

    NSURL* url = [NSURL URLWithInsecureString:urlString];
    if (!url) {
        [self _prefetchTranscriptDescriptor:descriptor episode:episode attempts:attempts urlIndex:urlIndex + 1];
        return;
    }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    [request setValue:@"text/vtt,application/x-subrip,text/plain,application/json,application/ttml+xml,text/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    NSString* username = episode.feed.username;
    NSString* password = episode.feed.password;
    if (username.length > 0 && password.length > 0) {
        NSString* credentials = [NSString stringWithFormat:@"%@:%@", username, password];
        NSData* credentialsData = [credentials dataUsingEncoding:NSUTF8StringEncoding];
        NSString* authHeader = [NSString stringWithFormat:@"Basic %@", [credentialsData base64EncodedStringWithOptions:0]];
        [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }

        NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
        NSInteger statusCode = httpResponse.statusCode;
        BOOL statusIsSuccess = (httpResponse == nil || (statusCode >= 200 && statusCode < 300));

        NSMutableDictionary* descriptorForParsing = [descriptor mutableCopy];
        descriptorForParsing[@"resolvedURL"] = urlString;
        NSArray<NSDictionary*>* cues = @[];
        if (!error && statusIsSuccess && data.length > 0) {
            cues = [self _parseTranscriptData:data descriptor:descriptorForParsing response:response];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.transcriptPrefetchTasks removeObjectForKey:taskKey];

            if (cues.count > 0) {
                [self _storeTranscriptData:data forEpisodeHash:episodeHash resolvedURL:urlString];
                [self _prefetchTranscriptSourcesForEpisode:episode];
                return;
            }

            [self _prefetchTranscriptDescriptor:descriptor episode:episode attempts:attempts urlIndex:urlIndex + 1];
            [self _prefetchTranscriptSourcesForEpisode:episode];
        });
    }];

    self.transcriptPrefetchTasks[taskKey] = task;
    [task resume];
}

- (void)_prefetchTranscriptSourcesForEpisode:(CDEpisode*)episode
{
    if (!episode || episode.consumed || self.transcriptSources.count == 0) {
        return;
    }
    if (self.transcriptPrefetchTasks.count > 0) {
        return;
    }

    NSString* selectedResolvedURL = [self.selectedTranscriptDescriptor[@"resolvedURL"] isKindOfClass:[NSString class]] ? self.selectedTranscriptDescriptor[@"resolvedURL"] : nil;

    for (NSDictionary* descriptor in self.transcriptSources) {
        NSArray<NSString*>* attempts = [self _transcriptURLAttemptsForDescriptor:descriptor episode:episode];
        if (attempts.count == 0) {
            continue;
        }

        NSInteger urlIndexToPrefetch = NSNotFound;
        for (NSInteger idx = 0; idx < (NSInteger)attempts.count; idx++) {
            NSString* urlString = attempts[idx];
            if (urlString.length == 0) {
                continue;
            }
            if ([_transcriptLoadingURL isEqualToString:urlString]) {
                continue;
            }
            if ([selectedResolvedURL isEqualToString:urlString]) {
                continue;
            }
            if ([self _cachedTranscriptDataForEpisodeHash:episode.objectHash resolvedURL:urlString].length > 0) {
                continue;
            }

            NSString* taskKey = [self _transcriptPrefetchTaskKeyForEpisodeHash:episode.objectHash resolvedURL:urlString];
            if (taskKey.length == 0 || self.transcriptPrefetchTasks[taskKey] != nil) {
                continue;
            }

            urlIndexToPrefetch = idx;
            break;
        }

        if (urlIndexToPrefetch != NSNotFound) {
            [self _prefetchTranscriptDescriptor:descriptor episode:episode attempts:attempts urlIndex:urlIndexToPrefetch];
            return;
        }
    }
}

- (void)_applyLoadedTranscriptCues:(NSArray<NSDictionary*>*)cues descriptor:(NSDictionary*)descriptor resolvedURL:(NSString*)resolvedURL
{
    if (cues.count == 0 || resolvedURL.length == 0) {
        return;
    }

    DebugLog(@"[TranscriptData] transcript loaded url=%@ cues=%ld", resolvedURL, (long)cues.count);

    CDEpisode* loadedEpisode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    self.transcriptLoadedEpisodeHash = loadedEpisode.objectHash;

    NSMutableDictionary* resolvedDescriptor = [descriptor mutableCopy];
    resolvedDescriptor[@"resolvedURL"] = resolvedURL;
    self.selectedTranscriptDescriptor = resolvedDescriptor;
    self.transcriptCues = cues;

    // Save to static in-memory cache for instant restore on player reopen
    s_transcriptCachedEpisodeHash = loadedEpisode.objectHash;
    s_transcriptCachedCues = cues;
    s_transcriptCachedDescriptor = [resolvedDescriptor copy];
    s_transcriptCachedSources = [self.transcriptSources copy];
    DebugLog(@"[TranscriptData] saved to in-memory cache episode=%@ cues=%ld", s_transcriptCachedEpisodeHash, (long)cues.count);

    [self _rebuildTranscriptLines];
    [self _updateTranscriptPickerButton];

    // Restore transcript visibility if user had it visible before (BEFORE availability callback)
    BOOL shouldRestoreVisible = [USER_DEFAULTS boolForKey:@"TranscriptVisiblePreference"];
    if (shouldRestoreVisible && !self.transcriptVisible) {
        self.transcriptVisible = YES;
        DebugLog(@"[TranscriptUI] restored transcript visibility from preference");
    }

    // Fire availability callback AFTER visibility is restored so controls pick up correct state
    [self _setTranscriptAvailableState:YES];

    PlaybackManager* pman = [PlaybackManager playbackManager];
    [self _updateTranscriptCueForPlaybackTime:pman.time animated:NO];
    [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
    [self _applyTranscriptVisibility];
    [self _updateTranscriptSyncTimerState];

    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    [self _prefetchTranscriptSourcesForEpisode:episode];
}

- (void)_updateTranscriptSyncTimerState
{
    BOOL shouldRun = (self.isViewLoaded && self.view.window != nil && self.transcriptVisible && self.transcriptCues.count > 0);
    if (shouldRun && !self.transcriptSyncTimer) {
        DebugLog(@"[TranscriptSync] start timer cues=%ld", (long)self.transcriptCues.count);
        self.transcriptSyncTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                     target:self
                                                                   selector:@selector(_transcriptSyncTimerFired:)
                                                                   userInfo:nil
                                                                    repeats:YES];
    } else if (!shouldRun && self.transcriptSyncTimer) {
        DebugLog(@"[TranscriptSync] stop timer visible=%@ window=%@ cues=%ld",
                 self.transcriptVisible ? @"YES" : @"NO",
                 self.view.window ? @"YES" : @"NO",
                 (long)self.transcriptCues.count);
        [self.transcriptSyncTimer invalidate];
        self.transcriptSyncTimer = nil;
    }
}

- (void)_transcriptSyncTimerFired:(NSTimer*)timer
{
    if (timer != self.transcriptSyncTimer || self.transcriptCues.count == 0) {
        return;
    }

    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSTimeInterval currentTime = pman.time;
    NSInteger cueIndex = [self _activeTranscriptCueIndexForPlaybackTime:currentTime];
    if (cueIndex == NSNotFound) {
        return;
    }

    BOOL cueChanged = (cueIndex != self.activeTranscriptCueIndex);
    if (cueChanged) {
        // Detect seek: cue jumped by more than 1 position
        BOOL seekDetected = (self.activeTranscriptCueIndex != NSNotFound &&
                             labs(cueIndex - self.activeTranscriptCueIndex) > 1);

        self.activeTranscriptCueIndex = cueIndex;
        [self _updateTranscriptLabelAppearance];

        // Seek overrides manual scroll suspension
        if (seekDetected && self.transcriptAutoFollowSuspended) {
            self.transcriptAutoFollowSuspended = NO;
            [self.transcriptFollowResumeTimer invalidate];
            self.transcriptFollowResumeTimer = nil;
        }

    }

    if (self.transcriptVisible && !self.transcriptAutoFollowSuspended && cueChanged) {
        [self _focusTranscriptCueAtIndex:cueIndex animated:YES];
    }
}

- (void)_clearTranscriptLines
{
    self.transcriptTextView.attributedText = nil;
    self.transcriptCueRanges = @[];
    self.activeTranscriptCueIndex = NSNotFound;
}

- (void)_updateTranscriptLabelAppearance
{
    NSTextStorage* textStorage = self.transcriptTextView.textStorage;
    if (!textStorage || self.transcriptCueRanges.count == 0) return;

    UIColor* normalColor = ICMutedTextColor;
    UIFont* normalFont = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    UIColor* activeColor = self.view.tintColor ?: ICTintColor;
    UIFont* activeFont = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];

    [textStorage beginEditing];

    // Un-highlight previous active cue (tracked via _previousTranscriptCueIndex)
    if (_previousTranscriptCueIndex != NSNotFound &&
        _previousTranscriptCueIndex >= 0 &&
        _previousTranscriptCueIndex < (NSInteger)self.transcriptCueRanges.count) {
        NSRange oldRange = [self.transcriptCueRanges[_previousTranscriptCueIndex] rangeValue];
        [textStorage addAttribute:NSForegroundColorAttributeName value:normalColor range:oldRange];
        [textStorage addAttribute:NSFontAttributeName value:normalFont range:oldRange];
    }

    // Highlight new active cue
    if (self.activeTranscriptCueIndex != NSNotFound &&
        self.activeTranscriptCueIndex >= 0 &&
        self.activeTranscriptCueIndex < (NSInteger)self.transcriptCueRanges.count) {
        NSRange newRange = [self.transcriptCueRanges[self.activeTranscriptCueIndex] rangeValue];
        [textStorage addAttribute:NSForegroundColorAttributeName value:activeColor range:newRange];
        [textStorage addAttribute:NSFontAttributeName value:activeFont range:newRange];
    }

    [textStorage endEditing];
    _previousTranscriptCueIndex = self.activeTranscriptCueIndex;
}

- (void)_rebuildTranscriptLines
{
    [self _clearTranscriptLines];
    _previousTranscriptCueIndex = NSNotFound;
    if (self.transcriptCues.count == 0) {
        return;
    }

    NSDictionary* normalAttrs = @{
        NSForegroundColorAttributeName: ICMutedTextColor,
        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightRegular]
    };
    NSAttributedString* separator = [[NSAttributedString alloc] initWithString:@"\n\n" attributes:normalAttrs];

    NSMutableAttributedString* attrString = [[NSMutableAttributedString alloc] init];
    NSMutableArray<NSValue*>* ranges = [NSMutableArray arrayWithCapacity:self.transcriptCues.count];

    for (NSInteger i = 0; i < (NSInteger)self.transcriptCues.count; i++) {
        NSString* text = self.transcriptCues[i][@"text"] ?: @"";
        NSUInteger rangeStart = attrString.length;
        [attrString appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:normalAttrs]];
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(rangeStart, text.length)]];
        if (i < (NSInteger)self.transcriptCues.count - 1) {
            [attrString appendAttributedString:separator];
        }
    }

    self.transcriptTextView.attributedText = attrString;
    self.transcriptCueRanges = ranges;

    // Cache the built attributed string + ranges for instant restore
    s_transcriptCachedAttrString = [attrString copy];
    s_transcriptCachedRanges = [ranges copy];
}

- (NSInteger)_activeTranscriptCueIndexForPlaybackTime:(NSTimeInterval)time
{
    if (self.transcriptCues.count == 0) {
        return NSNotFound;
    }

    NSInteger bestIndex = 0;
    for (NSInteger idx = 0; idx < (NSInteger)self.transcriptCues.count; idx++) {
        NSDictionary* cue = self.transcriptCues[idx];
        double start = [cue[@"start"] doubleValue];
        double end = [cue[@"end"] doubleValue];
        if (time < start) {
            return MAX(bestIndex, 0);
        }
        bestIndex = idx;
        if (time >= start && time < end) {
            return idx;
        }
    }
    return bestIndex;
}

- (void)_focusTranscriptCueAtIndex:(NSInteger)index animated:(BOOL)animated
{
    if (index == NSNotFound || index < 0 || index >= (NSInteger)self.transcriptCueRanges.count) {
        return;
    }

    NSRange cueRange = [self.transcriptCueRanges[index] rangeValue];
    NSLayoutManager* layoutManager = self.transcriptTextView.layoutManager;
    NSTextContainer* textContainer = self.transcriptTextView.textContainer;

    // Ensure layout for the ENTIRE text, not just up to the cue.
    // When _updateTranscriptLabelAppearance changes fonts at old and new cue positions,
    // textStorage endEditing invalidates layout for the union of both ranges.
    // If we only ensureLayout up to the new cue (smaller range for backward seeks),
    // the gap between new and old cue reverts to estimated line heights.
    // UITextView then re-layouts visible content, contentSize changes, and UITextView
    // auto-adjusts contentOffset to compensate — destroying our scroll position.
    [layoutManager ensureLayoutForCharacterRange:NSMakeRange(0, layoutManager.textStorage.length)];
    NSRange glyphRange = [layoutManager glyphRangeForCharacterRange:cueRange actualCharacterRange:NULL];
    CGRect glyphRect = [layoutManager boundingRectForGlyphRange:glyphRange inTextContainer:textContainer];

    // Adjust for text container inset
    glyphRect.origin.y += self.transcriptTextView.textContainerInset.top;

    CGFloat viewHeight = CGRectGetHeight(self.transcriptTextView.bounds);
    CGFloat targetOffsetY = CGRectGetMidY(glyphRect) - viewHeight * 0.5f;
    CGFloat minOffsetY = -self.transcriptTextView.contentInset.top;
    CGFloat maxOffsetY = self.transcriptTextView.contentSize.height - viewHeight + self.transcriptTextView.contentInset.bottom;
    if (maxOffsetY < minOffsetY) {
        maxOffsetY = minOffsetY;
    }
    targetOffsetY = MAX(minOffsetY, MIN(targetOffsetY, maxOffsetY));

    [self.transcriptTextView setContentOffset:CGPointMake(0, targetOffsetY) animated:animated];
}

- (void)_resumeTranscriptAutoFollow
{
    self.transcriptAutoFollowSuspended = NO;
    [self.transcriptFollowResumeTimer invalidate];
    self.transcriptFollowResumeTimer = nil;
    if (self.transcriptVisible) {
        [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:YES];
    }
}

- (void)_transcriptTextViewTapped:(UITapGestureRecognizer*)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded || self.transcriptCueRanges.count == 0) {
        return;
    }

    CGPoint point = [gesture locationInView:self.transcriptTextView];
    point.x -= self.transcriptTextView.textContainerInset.left;
    point.y -= self.transcriptTextView.textContainerInset.top;

    NSLayoutManager* layoutManager = self.transcriptTextView.layoutManager;
    NSTextContainer* textContainer = self.transcriptTextView.textContainer;
    NSUInteger charIndex = [layoutManager characterIndexForPoint:point
                                                inTextContainer:textContainer
                       fractionOfDistanceBetweenInsertionPoints:NULL];
    if (charIndex == NSNotFound) {
        return;
    }

    // Find which cue contains this character index
    for (NSInteger i = 0; i < (NSInteger)self.transcriptCueRanges.count; i++) {
        NSRange cueRange = [self.transcriptCueRanges[i] rangeValue];
        if (charIndex >= cueRange.location && charIndex < NSMaxRange(cueRange)) {
            NSDictionary* cue = self.transcriptCues[i];
            NSTimeInterval startTime = [cue[@"start"] doubleValue];

            PlaybackManager* pman = [PlaybackManager playbackManager];
            [pman seekToTime:startTime];
            if (!pman.isPodcastPlaying) {
                [pman play];
            }

            // Reset auto-follow and update immediately
            self.transcriptAutoFollowSuspended = NO;
            [self.transcriptFollowResumeTimer invalidate];
            self.transcriptFollowResumeTimer = nil;
            self.activeTranscriptCueIndex = i;
            [self _updateTranscriptLabelAppearance];
            [self _focusTranscriptCueAtIndex:i animated:YES];
            return;
        }
    }
}

- (void)_playbackDidUpdateForTranscriptFollow:(NSNotification*)notification
{
    (void)notification;
    PlaybackManager* pman = [PlaybackManager playbackManager];
    BOOL isPlaying = pman.isPodcastPlaying;
    if (self.transcriptWasPaused && isPlaying && self.transcriptAutoFollowSuspended && self.transcriptVisible) {
        [self _resumeTranscriptAutoFollow];
    }
    self.transcriptWasPaused = !isPlaying;
}

- (void)_scheduleTranscriptAutoFollowResume
{
    [self.transcriptFollowResumeTimer invalidate];
    self.transcriptFollowResumeTimer = [NSTimer scheduledTimerWithTimeInterval:6.0
                                                                         target:self
                                                                       selector:@selector(_resumeTranscriptAutoFollow)
                                                                       userInfo:nil
                                                                        repeats:NO];
}

- (void)_updateTranscriptCueForPlaybackTime:(NSTimeInterval)time animated:(BOOL)animated
{
    if (self.transcriptCues.count == 0) {
        return;
    }

    NSInteger cueIndex = [self _activeTranscriptCueIndexForPlaybackTime:time];
    if (cueIndex == NSNotFound) {
        return;
    }

    BOOL cueChanged = (cueIndex != self.activeTranscriptCueIndex);
    if (cueChanged) {
        self.activeTranscriptCueIndex = cueIndex;
        [self _updateTranscriptLabelAppearance];
    }

    if (self.transcriptVisible && !self.transcriptAutoFollowSuspended && cueChanged) {
        [self _focusTranscriptCueAtIndex:cueIndex animated:animated];
    }
}

- (NSArray<NSDictionary*>*)_parseTranscriptData:(NSData*)data descriptor:(NSDictionary*)descriptor response:(NSURLResponse*)response
{
    NSString* descriptorType = [descriptor[@"type"] lowercaseString];
    NSString* mimeType = [[response MIMEType] lowercaseString];
    NSString* extensionURLString = [descriptor[@"resolvedURL"] isKindOfClass:[NSString class]] ? descriptor[@"resolvedURL"] : descriptor[@"url"];
    NSString* urlExtension = [[NSURL URLWithString:extensionURLString].pathExtension lowercaseString];
    DebugLog(@"[TranscriptData] parse start url=%@ type=%@ mime=%@ ext=%@ bytes=%lu",
             extensionURLString ?: @"",
             descriptorType ?: @"",
             mimeType ?: @"",
             urlExtension ?: @"",
             (unsigned long)data.length);

    BOOL maybeJSON = ICTranscriptTypeContains(descriptorType, @"json") || ICTranscriptTypeContains(mimeType, @"json") || [urlExtension isEqualToString:@"json"];
    if (maybeJSON) {
        NSArray* jsonCues = ICTranscriptParseJSON(data);
        if (jsonCues.count > 0) {
            DebugLog(@"[TranscriptData] parse success JSON cues=%ld", (long)jsonCues.count);
            return jsonCues;
        }
    }

    NSString* text = ICTranscriptDecodedString(data);
    if (text.length == 0) {
        DebugLog(@"[TranscriptData] parse failed: decoded text empty");
        return @[];
    }

    BOOL maybeTTML = ICTranscriptTypeContains(descriptorType, @"ttml") || ICTranscriptTypeContains(mimeType, @"ttml") || [urlExtension isEqualToString:@"ttml"] || [urlExtension isEqualToString:@"dfxp"] || ICTranscriptTypeContains(descriptorType, @"xml");
    if (maybeTTML || [text rangeOfString:@"<tt" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSArray* ttmlCues = ICTranscriptParseTTML(text);
        if (ttmlCues.count > 0) {
            DebugLog(@"[TranscriptData] parse success TTML cues=%ld", (long)ttmlCues.count);
            return ttmlCues;
        }
    }

    BOOL maybeLRC = [urlExtension isEqualToString:@"lrc"];
    if (maybeLRC) {
        NSArray* lrcCues = ICTranscriptParseLRC(text);
        if (lrcCues.count > 0) {
            DebugLog(@"[TranscriptData] parse success LRC(ext) cues=%ld", (long)lrcCues.count);
            return lrcCues;
        }
    }

    NSArray* timedTextCues = ICTranscriptParseArrowTimedText(text);
    if (timedTextCues.count > 0) {
        DebugLog(@"[TranscriptData] parse success timed-text cues=%ld", (long)timedTextCues.count);
        return timedTextCues;
    }

    NSArray* lrcCues = ICTranscriptParseLRC(text);
    if (lrcCues.count > 0) {
        DebugLog(@"[TranscriptData] parse success LRC(fallback) cues=%ld", (long)lrcCues.count);
        return lrcCues;
    }

    NSArray* jsonCues = ICTranscriptParseJSON(data);
    if (jsonCues.count > 0) {
        DebugLog(@"[TranscriptData] parse success JSON(fallback) cues=%ld", (long)jsonCues.count);
        return jsonCues;
    }

    BOOL maybePlain = ICTranscriptTypeContains(descriptorType, @"plain") ||
                      ICTranscriptTypeContains(mimeType, @"plain") ||
                      [urlExtension isEqualToString:@"txt"];
    NSArray* plainTextCues = ICTranscriptParsePlainText(text);
    if (maybePlain && plainTextCues.count > 0) {
        DebugLog(@"[TranscriptData] parse success plain(ext/type) cues=%ld", (long)plainTextCues.count);
        return plainTextCues;
    }

    if (plainTextCues.count > 0) {
        DebugLog(@"[TranscriptData] parse success plain(fallback) cues=%ld", (long)plainTextCues.count);
        return plainTextCues;
    }

    DebugLog(@"[TranscriptData] parse failed: no parser produced cues");
    return @[];
}

- (void)_appendTranscriptURLAttemptForRawValue:(NSString*)rawValue
                                       episode:(CDEpisode*)episode
                                      attempts:(NSMutableOrderedSet<NSString*>*)attempts
{
    if (rawValue.length == 0 || attempts == nil) {
        return;
    }

    NSString* trimmed = [rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return;
    }

    if ([trimmed hasPrefix:@"//"]) {
        NSMutableOrderedSet<NSString*>* schemes = [NSMutableOrderedSet orderedSet];
        NSString* sourceScheme = episode.feed.sourceURL.scheme;
        NSString* linkScheme = episode.feed.linkURL.scheme;
        if (sourceScheme.length > 0) {
            [schemes addObject:sourceScheme];
        }
        if (linkScheme.length > 0) {
            [schemes addObject:linkScheme];
        }
        if (schemes.count == 0) {
            [schemes addObject:@"https"];
        }
        if (![schemes containsObject:@"https"]) {
            [schemes addObject:@"https"];
        }
        if (![schemes containsObject:@"http"]) {
            [schemes addObject:@"http"];
        }

        for (NSString* scheme in schemes) {
            NSString* candidate = [NSString stringWithFormat:@"%@:%@", scheme, trimmed];
            [attempts addObject:candidate];
            DebugLog(@"[TranscriptData] URL attempt(protocol-relative): %@", candidate);
        }
        return;
    }

    NSURL* directURL = [NSURL URLWithInsecureString:trimmed];
    if (directURL.scheme.length > 0) {
        NSString* absolute = directURL.absoluteString ?: trimmed;
        if (absolute.length > 0) {
            [attempts addObject:absolute];
            DebugLog(@"[TranscriptData] URL attempt(absolute): %@", absolute);
        }
        return;
    }

    BOOL addedResolvedURL = NO;
    NSURL* sourceURL = episode.feed.sourceURL;
    if (sourceURL) {
        NSURL* resolved = [NSURL URLWithInsecureString:trimmed relativeToURL:sourceURL];
        if (resolved.absoluteString.length > 0) {
            [attempts addObject:resolved.absoluteString];
            addedResolvedURL = YES;
            DebugLog(@"[TranscriptData] URL attempt(source relative): %@", resolved.absoluteString);
        }
    }

    NSURL* linkURL = episode.feed.linkURL;
    if (linkURL) {
        NSURL* resolved = [NSURL URLWithInsecureString:trimmed relativeToURL:linkURL];
        if (resolved.absoluteString.length > 0) {
            [attempts addObject:resolved.absoluteString];
            addedResolvedURL = YES;
            DebugLog(@"[TranscriptData] URL attempt(link relative): %@", resolved.absoluteString);
        }
    }

    if (!addedResolvedURL) {
        [attempts addObject:trimmed];
        DebugLog(@"[TranscriptData] URL attempt(raw fallback): %@", trimmed);
    }
}

- (NSArray<NSString*>*)_transcriptURLAttemptsForDescriptor:(NSDictionary*)descriptor episode:(CDEpisode*)episode
{
    NSMutableOrderedSet<NSString*>* attempts = [NSMutableOrderedSet orderedSet];

    NSString* primaryURL = [descriptor[@"url"] isKindOfClass:[NSString class]] ? descriptor[@"url"] : nil;
    NSString* fallbackURL = [descriptor[@"fallbackURL"] isKindOfClass:[NSString class]] ? descriptor[@"fallbackURL"] : nil;
    NSString* href = [descriptor[@"href"] isKindOfClass:[NSString class]] ? descriptor[@"href"] : nil;

    [self _appendTranscriptURLAttemptForRawValue:primaryURL episode:episode attempts:attempts];
    [self _appendTranscriptURLAttemptForRawValue:fallbackURL episode:episode attempts:attempts];
    [self _appendTranscriptURLAttemptForRawValue:href episode:episode attempts:attempts];
    DebugLog(@"[TranscriptData] attempts built for descriptor url=%@ attempts=%@",
             descriptor[@"url"] ?: @"",
             attempts.array);

    return attempts.array;
}

- (void)_loadTranscriptDescriptor:(NSDictionary*)descriptor
                        candidates:(NSArray<NSDictionary*>*)candidates
                    candidateIndex:(NSInteger)candidateIndex
                          attempts:(NSArray<NSString*>*)attempts
                          urlIndex:(NSInteger)urlIndex
{
    DebugLog(@"[TranscriptData] load descriptor candidateIndex=%ld/%ld urlIndex=%ld/%ld descriptorURL=%@",
             (long)candidateIndex,
             (long)candidates.count,
             (long)urlIndex,
             (long)attempts.count,
             descriptor[@"url"] ?: @"");
    if (urlIndex >= (NSInteger)attempts.count) {
        DebugLog(@"[TranscriptData] descriptor exhausted, moving to next candidate");
        [self _loadTranscriptCandidates:candidates index:candidateIndex + 1];
        return;
    }

    NSString* urlString = attempts[urlIndex];
    NSURL* url = [NSURL URLWithInsecureString:urlString];
    if (!url) {
        [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex + 1];
        return;
    }

    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    NSString* episodeHash = episode.objectHash;

    // Move cache file I/O and parsing entirely off the main thread
    _transcriptLoadingURL = urlString;
    NSMutableDictionary* descriptorForParsing = [descriptor mutableCopy];
    descriptorForParsing[@"resolvedURL"] = urlString;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSData* cachedData = [strongSelf _cachedTranscriptDataForEpisodeHash:episodeHash resolvedURL:urlString];
        NSArray<NSDictionary*>* cachedCues = nil;
        if (cachedData.length > 0) {
            cachedCues = [strongSelf _parseTranscriptData:cachedData descriptor:descriptorForParsing response:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (![_transcriptLoadingURL isEqualToString:urlString]) return;

            if (cachedCues.count > 0) {
                DebugLog(@"[TranscriptData] cache hit+parse success episode=%@ url=%@ cues=%ld", episodeHash ?: @"(nil)", urlString, (long)cachedCues.count);
                [self _applyLoadedTranscriptCues:cachedCues descriptor:descriptor resolvedURL:urlString];
                return;
            }

            if (cachedData.length > 0) {
                DebugLog(@"[TranscriptData] cache parse failed, removing cached entry url=%@", urlString);
                [self _removeTranscriptCacheForEpisodeHash:episodeHash resolvedURL:urlString];
            } else {
                DebugLog(@"[TranscriptData] cache miss episode=%@ url=%@", episodeHash ?: @"(nil)", urlString);
            }

            // No cache or cache invalid — start network load
            [self _loadTranscriptDescriptorFromNetwork:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex episodeHash:episodeHash];
        });
    });
}

- (void)_loadTranscriptDescriptorFromNetwork:(NSDictionary*)descriptor
                                   candidates:(NSArray<NSDictionary*>*)candidates
                               candidateIndex:(NSInteger)candidateIndex
                                     attempts:(NSArray<NSString*>*)attempts
                                     urlIndex:(NSInteger)urlIndex
                                  episodeHash:(NSString*)episodeHash
{
    NSString* urlString = attempts[urlIndex];
    NSURL* url = [NSURL URLWithInsecureString:urlString];
    if (!url) {
        [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex + 1];
        return;
    }

    [self.transcriptTask cancel];
    _transcriptLoadingURL = urlString;
    DebugLog(@"[TranscriptData] starting network transcript load url=%@", urlString);

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    [request setValue:@"text/vtt,application/x-subrip,text/plain,application/json,application/ttml+xml,text/xml;q=0.9,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    CDFeed* feed = episode.feed;
    if (feed.username.length > 0 && feed.password.length > 0) {
        NSString* credentials = [NSString stringWithFormat:@"%@:%@", feed.username, feed.password];
        NSData* credentialsData = [credentials dataUsingEncoding:NSUTF8StringEncoding];
        NSString* authHeader = [NSString stringWithFormat:@"Basic %@", [credentialsData base64EncodedStringWithOptions:0]];
        [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
    }

    __weak typeof(self) weakSelf = self;
    __block NSURLSessionDataTask* task = nil;
    task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        // Completion handler runs on background thread — do parsing here, not on main thread
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSHTTPURLResponse* httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)response : nil;
        NSInteger statusCode = httpResponse.statusCode;
        BOOL statusFailed = (httpResponse && (statusCode < 200 || statusCode >= 300));
        BOOL hasError = (error != nil || data.length == 0);

        // Parse on background thread
        NSArray<NSDictionary*>* cues = nil;
        if (!statusFailed && !hasError && data.length > 0) {
            NSMutableDictionary* descriptorForParsing = [descriptor mutableCopy];
            descriptorForParsing[@"resolvedURL"] = urlString;
            cues = [strongSelf _parseTranscriptData:data descriptor:descriptorForParsing response:response];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (self.transcriptTask != task) return;
            if (![_transcriptLoadingURL isEqualToString:urlString]) return;

            if (statusFailed) {
                DebugLog(@"[TranscriptData] transcript request failed (%ld) url=%@", (long)statusCode, urlString);
                [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex + 1];
                return;
            }

            if (hasError) {
                DebugLog(@"[TranscriptData] transcript request error url=%@ error=%@", urlString, error.localizedDescription ?: @"no data");
                [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex + 1];
                return;
            }

            if (cues.count == 0) {
                DebugLog(@"[TranscriptData] transcript parse returned no cues url=%@", urlString);
                [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:candidateIndex attempts:attempts urlIndex:urlIndex + 1];
                return;
            }

            [self _storeTranscriptData:data forEpisodeHash:episodeHash resolvedURL:urlString];
            [self _applyLoadedTranscriptCues:cues descriptor:descriptor resolvedURL:urlString];
        });
    }];
    self.transcriptTask = task;
    [task resume];
}

- (void)_loadTranscriptCandidates:(NSArray<NSDictionary*>*)candidates index:(NSInteger)index
{
    DebugLog(@"[TranscriptData] load candidates index=%ld total=%ld", (long)index, (long)candidates.count);
    if (index >= (NSInteger)candidates.count) {
        self.transcriptCues = @[];
        [self _clearTranscriptLines];
        [self _setTranscriptAvailableState:NO];
        [self _updateTranscriptPickerButton];
        [self _applyTranscriptVisibility];
        [self _updateTranscriptSyncTimerState];
        DebugLog(@"[TranscriptData] no candidate produced transcript -> available=NO");
        return;
    }

    NSDictionary* descriptor = candidates[index];
    DebugLog(@"[TranscriptData] trying candidate index=%ld url=%@ type=%@ lang=%@",
             (long)index,
             descriptor[@"url"] ?: @"",
             descriptor[@"type"] ?: @"",
             descriptor[@"language"] ?: @"");
    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    NSArray<NSString*>* attempts = [self _transcriptURLAttemptsForDescriptor:descriptor episode:episode];
    if (attempts.count == 0) {
        DebugLog(@"[TranscriptData] candidate has no URL attempts -> next candidate");
        [self _loadTranscriptCandidates:candidates index:index + 1];
        return;
    }
    [self _loadTranscriptDescriptor:descriptor candidates:candidates candidateIndex:index attempts:attempts urlIndex:0];
}

- (void)_refreshTranscriptState
{
    DebugLog(@"[TranscriptData] refresh start");

    CDEpisode* currentEpisode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;

    // 1) Same VC instance already has cues for this episode
    if (self.transcriptCues.count > 0 &&
        self.transcriptLoadedEpisodeHash.length > 0 &&
        [currentEpisode.objectHash isEqualToString:self.transcriptLoadedEpisodeHash]) {
        DebugLog(@"[TranscriptData] refresh skipped: same episode already loaded (%ld cues)", (long)self.transcriptCues.count);
        [self _updateTranscriptSyncTimerState];
        return;
    }

    // 2) Static in-memory cache has cues for this episode — set state flags only, defer all UITextView work
    if (s_transcriptCachedCues.count > 0 &&
        s_transcriptCachedEpisodeHash.length > 0 &&
        [currentEpisode.objectHash isEqualToString:s_transcriptCachedEpisodeHash]) {
        DebugLog(@"[TranscriptData] instant restore from in-memory cache episode=%@ cues=%ld",
                 s_transcriptCachedEpisodeHash, (long)s_transcriptCachedCues.count);

        // Restore everything synchronously — with scrollEnabled=YES, attributedText is instant (lazy layout)
        self.transcriptLoadedEpisodeHash = s_transcriptCachedEpisodeHash;
        self.transcriptSources = s_transcriptCachedSources ?: @[];
        self.selectedTranscriptDescriptor = s_transcriptCachedDescriptor;
        self.transcriptCues = s_transcriptCachedCues;
        _previousTranscriptCueIndex = NSNotFound;

        if (s_transcriptCachedAttrString && s_transcriptCachedRanges.count > 0) {
            self.transcriptTextView.attributedText = s_transcriptCachedAttrString;
            self.transcriptCueRanges = s_transcriptCachedRanges;
        } else {
            [self _rebuildTranscriptLines];
        }
        [self _updateTranscriptPickerButton];

        BOOL shouldRestoreVisible = [USER_DEFAULTS boolForKey:@"TranscriptVisiblePreference"];
        if (shouldRestoreVisible) {
            self.transcriptVisible = YES;
        }
        [self _setTranscriptAvailableState:YES];

        PlaybackManager* pman = [PlaybackManager playbackManager];
        [self _updateTranscriptCueForPlaybackTime:pman.time animated:NO];
        [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
        [self _applyTranscriptVisibility];
        [self _updateTranscriptSyncTimerState];
        return;
    }

    // 3) Full reset + async load
    [self.transcriptTask cancel];
    [self _cancelTranscriptPrefetchTasks];
    _transcriptLoadingURL = nil;
    [self.transcriptFollowResumeTimer invalidate];
    self.transcriptFollowResumeTimer = nil;
    [self.transcriptSyncTimer invalidate];
    self.transcriptSyncTimer = nil;
    self.transcriptAutoFollowSuspended = NO;
    self.pendingTranscriptShowAfterScrollToTop = NO;
    self.transcriptVisible = NO;
    self.transcriptLoadedEpisodeHash = nil;

    CDEpisode* episode = currentEpisode;
    BOOL isCached = [[CacheManager sharedCacheManager] episodeIsCached:episode];
    DebugLog(@"[TranscriptData] refresh episode=%@ title='%@' cached=%@ consumed=%@",
             episode.objectHash ?: @"(nil)",
             episode.title ?: @"",
             isCached ? @"YES" : @"NO",
             episode.consumed ? @"YES" : @"NO");
    [self _clearTranscriptCacheIfNeededForEpisode:episode];
    self.transcriptSources = [self _normalizedTranscriptSourcesForEpisode:episode];
    self.selectedTranscriptDescriptor = nil;
    self.transcriptCues = @[];
    [self _clearTranscriptLines];
    [self _setTranscriptAvailableState:NO];
    [self _updateTranscriptPickerButton];
    [self _applyTranscriptVisibility];
    [self _updateTranscriptSyncTimerState];

    NSDictionary* preferred = [self _preferredTranscriptDescriptorFromSources:self.transcriptSources];
    NSArray* candidates = [self _orderedTranscriptCandidatesFromSources:self.transcriptSources preferred:preferred];
    DebugLog(@"[TranscriptData] refresh sources=%ld preferred=%@ candidates=%ld",
             (long)self.transcriptSources.count,
             preferred[@"url"] ?: @"(nil)",
             (long)candidates.count);
    if (candidates.count > 0) {
        [self _loadTranscriptCandidates:candidates index:0];
    } else {
        DebugLog(@"[TranscriptData] refresh ended: no transcript candidates");
    }
}

- (void)_rememberTranscriptPreference:(NSDictionary*)descriptor
{
    if (!descriptor) {
        return;
    }
    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    CDFeed* feed = episode.feed;
    if (!feed) {
        return;
    }

    NSString* language = descriptor[@"language"];
    NSString* url = descriptor[@"url"];
    if (language.length > 0) {
        [feed setString:language forKey:kFeedPropertyPreferredTranscriptLanguage];
    }
    if (url.length > 0) {
        [feed setString:url forKey:kFeedPropertyPreferredTranscriptURL];
    }
    [DMANAGER save];
}

- (void)showTranscriptPicker:(UIButton*)sender
{
    if (self.transcriptSources.count <= 1) {
        return;
    }

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Transcript".ls
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary* descriptor in self.transcriptSources) {
        BOOL selected = [descriptor[@"url"] isEqualToString:self.selectedTranscriptDescriptor[@"url"]];
        NSString* title = [self _transcriptDisplayNameForDescriptor:descriptor];
        if (selected) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }

        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self _rememberTranscriptPreference:descriptor];
            NSArray* candidates = [self _orderedTranscriptCandidatesFromSources:self.transcriptSources preferred:descriptor];
            [self _loadTranscriptCandidates:candidates index:0];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
    alert.modalPresentationStyle = UIModalPresentationPopover;
    UIPopoverPresentationController* popover = [alert popoverPresentationController];
    popover.sourceView = sender;
    popover.sourceRect = sender.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionDown;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setTranscriptVisibleFromControl:(BOOL)visible
{
    DebugLog(@"[TranscriptUI] set visible from control requested=%@ available=%@ currentlyVisible=%@",
             visible ? @"YES" : @"NO",
             self.transcriptAvailable ? @"YES" : @"NO",
             self.transcriptVisible ? @"YES" : @"NO");
    if (visible && !self.transcriptAvailable) {
        DebugLog(@"[TranscriptUI] reject show: transcript not available");
        return;
    }

    if (!visible) {
        self.pendingTranscriptShowAfterScrollToTop = NO;
        self.transcriptVisible = NO;
        [self _applyTranscriptVisibility];
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptVisiblePreference"];
        DebugLog(@"[TranscriptUI] transcript hidden via control");
        return;
    }

    CGFloat topOffsetY = -self.tableView.contentInset.top;
    if (self.tableView.contentOffset.y > topOffsetY + 1.0) {
        self.pendingTranscriptShowAfterScrollToTop = YES;
        DebugLog(@"[TranscriptUI] delaying show until table scrolled to top currentOffset=%.2f target=%.2f",
                 self.tableView.contentOffset.y,
                 topOffsetY);
        [self.tableView setContentOffset:CGPointMake(0, topOffsetY) animated:YES];
        return;
    }

    self.pendingTranscriptShowAfterScrollToTop = NO;
    self.transcriptVisible = YES;
    [self _applyTranscriptVisibility];
    [USER_DEFAULTS setBool:YES forKey:@"TranscriptVisiblePreference"];
    PlaybackManager* pman = [PlaybackManager playbackManager];
    [self _updateTranscriptCueForPlaybackTime:pman.time animated:NO];
    [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
    DebugLog(@"[TranscriptUI] transcript shown immediately cueIndex=%ld",
             (long)self.activeTranscriptCueIndex);
}


- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    _didWillAppear = YES;

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    [self.transcriptPickerButton setTitleColor:ICMutedTextColor forState:UIControlStateNormal];
    self.transcriptPickerButton.tintColor = ICMutedTextColor;

    // Refresh chapter images from PlaybackManager before layout
    PlaybackManager* pman = [PlaybackManager playbackManager];
    if ([pman.artworks count] > 0) {
        self->chapterImagesArray = pman.artworks;
    }

    [self layoutHeaderView];
    if (self.view.window != nil) {
        [self.tableView reloadData];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.view.window != nil) {
                [self.tableView reloadData];
            }
        });
    }
    [self _applyTranscriptVisibility];
    [self _updateTranscriptLabelAppearance];

    // Scroll to current artwork after layout settles
    dispatch_async(dispatch_get_main_queue(), ^{
        PlaybackManager* pman = [PlaybackManager playbackManager];
        if (self->chapterImagesArray.count > 0 && pman.currentArtwork >= 0) {
            NSUInteger collectionIndex = pman.currentArtwork + 1;
            NSUInteger totalItems = self->chapterImagesArray.count + 1;
            if (totalItems > collectionIndex && CGRectGetWidth(self.chapterImagesCollection.bounds) > 0) {
                [self.chapterImagesCollection scrollToItemAtIndexPath:[NSIndexPath indexPathForRow:collectionIndex inSection:0] atScrollPosition:UICollectionViewScrollPositionCenteredHorizontally animated:NO];
            }
        }
    });
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    _didWillAppear = NO;
    [self _updateTranscriptSyncTimerState];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    if (_didWillAppear) {
        if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"11.0.0")) {

            // xxx: hard coded content Insets, because of rotation issues
            UIEdgeInsets edgeInsets = UIEdgeInsetsMake(20+44, 0, self.bottomScrollInset, 0);

            self.tableView.contentInset = edgeInsets;
            self.tableView.scrollIndicatorInsets = edgeInsets;
            if (CGPointEqualToPoint(self.tableView.contentOffset, CGPointZero)) {
                self.tableView.contentOffset = CGPointMake(0,-edgeInsets.top);
            }
        }
        else
        {
            UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20+44, 0, 0, 0);
            if (@available(iOS 11.0, *)) {
                safeAreaInsets = self.view.safeAreaInsets;
            }

            UIEdgeInsets edgeInsets = UIEdgeInsetsMake(safeAreaInsets.top, 0, self.bottomScrollInset, 0);

            self.tableView.contentInset = edgeInsets;
            self.tableView.scrollIndicatorInsets = edgeInsets;
            self.tableView.contentOffset = CGPointMake(0, -safeAreaInsets.top);
        }
    }

    if (self.transcriptVisible) {
        CGSize currentSize = self.transcriptTextView.bounds.size;
        if (!CGSizeEqualToSize(currentSize, _lastTranscriptBoundsSize)) {
            _lastTranscriptBoundsSize = currentSize;
            [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
        }
    }
}

- (void) layoutHeaderView
{
    CGRect b = self.view.bounds;
    self.rectCollection = self.view.bounds;
    
    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        self.rectCollection = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetHeight(b));
    }
    else
    {
        self.rectCollection = CGRectMake(0, 0, CGRectGetHeight(b), CGRectGetWidth(b));
    }
    
    if (self.videoViewController)
    {
        UIView* playerView = self.videoViewController.view;
        CGSize videoSize = self.videoViewController.videoSize;

        CGFloat aspectRatio = videoSize.width / videoSize.height;
        CGFloat viewAspectRatio = CGRectGetWidth(b) / CGRectGetHeight(b);

        // Extra height for top margin (30px) and fullscreen button (44px)
        CGFloat topMargin = 30.0;
        CGFloat buttonHeight = 44.0;
        CGFloat extraHeight = topMargin + buttonHeight;

        // xxx: landscape hack for iOS 8
        if (viewAspectRatio > 1) {
            CGFloat videoHeight = floorf(CGRectGetHeight(b)/aspectRatio);
            playerView.frame = CGRectMake(0, 0, CGRectGetHeight(b), videoHeight + extraHeight);
        } else {
            CGFloat videoHeight = floorf(CGRectGetWidth(b)/aspectRatio);
            playerView.frame = CGRectMake(0, 0, CGRectGetWidth(b), videoHeight + extraHeight);
        }

        self.tableView.tableHeaderView = playerView;
    } else {
        
        CGRect newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));
        
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
        layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
        [layout setMinimumInteritemSpacing:0.0f];
        [layout setMinimumLineSpacing:0.0f];
        
        if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
        {
            CGFloat size = MAX(CGRectGetWidth(b), 1);
            newFrameTemp = CGRectMake(0, 0, size, size);
            layout.itemSize = CGSizeMake(MAX(self.view.bounds.size.width, 1), MAX(self.view.bounds.size.width, 1));
        }
        else
        {
            CGRect wb = [[self getKeyWindow] bounds];
            CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
            CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
            if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
                controllerHeight -= 60;
            }

            CGFloat width = MAX(CGRectGetHeight(self.rectCollection), 1);
            CGFloat height = MAX(CGRectGetWidth(self.rectCollection) - controllerHeight, 1);
            newFrameTemp = CGRectMake(0, 0, width, height);
            layout.itemSize = CGSizeMake(MAX(self.view.bounds.size.height, 1), MAX(self.view.bounds.size.width - controllerHeight, 1));
        }

        self.chapterImagesCollection.collectionViewLayout = layout;
        self.imageView.frame = newFrameTemp;
        self.chapterImagesCollection.frame = newFrameTemp;
        self.transcriptContainerView.frame = newFrameTemp;
        [self.transcriptContainerView layoutIfNeeded];
        CGFloat pickerMaxWidth = MIN(280.0, MAX(CGRectGetWidth(newFrameTemp) - 12.0, 80.0));
        CGSize pickerSize = [self.transcriptPickerButton sizeThatFits:CGSizeMake(pickerMaxWidth, 24.0)];
        pickerSize.width = MIN(MAX(pickerSize.width + 4.0, 56.0), pickerMaxWidth);
        pickerSize.height = 22.0;
        self.transcriptPickerButton.frame = CGRectMake(CGRectGetMaxX(newFrameTemp) - pickerSize.width - 6.0,
                                                       CGRectGetMaxY(newFrameTemp) - pickerSize.height - 1.0,
                                                       pickerSize.width,
                                                       pickerSize.height);
        CGFloat verticalInset = MAX((CGRectGetHeight(self.transcriptTextView.bounds) * 0.5f) - 36.0f, 0);
        self.transcriptTextView.contentInset = UIEdgeInsetsMake(verticalInset, 0, verticalInset, 0);

        BOOL hasContent = [self _hasContentBelowImage];
        CGFloat chevronAreaHeight = hasContent ? 25.0f : 0.0f;
        CGRect chapterViewFrame = newFrameTemp;
        chapterViewFrame.size.height += chevronAreaHeight;
        self.chapterView.frame = chapterViewFrame;

        chevronIndicatorView.hidden = !hasContent;
        chevronIndicatorView.frame = CGRectMake(0, CGRectGetHeight(newFrameTemp) + 4, CGRectGetWidth(newFrameTemp), 20);
        chevronIndicatorView.tintColor = ICMutedTextColor;

        if (self.chapterImagesCollection.superview != self.chapterView) {
            [self.chapterView addSubview:self.chapterImagesCollection];
        }
        if (self.transcriptContainerView.superview != self.chapterView) {
            [self.chapterView addSubview:self.transcriptContainerView];
        }
        self.chapterImagesCollection.delegate = self;
        self.chapterImagesCollection.dataSource = self;
        [self.chapterImagesCollection reloadData];
        [self updateCollectionsImage:0];
        [self _applyTranscriptVisibility];
        [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];

        self.tableView.tableHeaderView = self.chapterView;
    }
}

- (void)orientationDidChange
{
    CGRect b = self.rectCollection;

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    [layout setMinimumInteritemSpacing:0.0f];
    [layout setMinimumLineSpacing:0.0f];

    CGRect newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));

    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        CGFloat size = MAX(CGRectGetWidth(b), 1);
        newFrameTemp = CGRectMake(0, 0, size, size);
        layout.itemSize = CGSizeMake(MAX(self.view.bounds.size.width, 1), MAX(self.view.bounds.size.width, 1));
    }
    else
    {
        CGRect wb = [[self getKeyWindow] bounds];
        CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
        CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            controllerHeight -= 60;
        }

        CGFloat width = MAX(CGRectGetHeight(b), 1);
        CGFloat height = MAX(CGRectGetWidth(b) - controllerHeight, 1);
        newFrameTemp = CGRectMake(0, 0, width, height);
        layout.itemSize = CGSizeMake(MAX(self.view.bounds.size.height, 1), MAX(self.view.bounds.size.width - controllerHeight, 1));
    }

    self.chapterImagesCollection.collectionViewLayout = layout;
    self.imageView.frame = newFrameTemp;
    self.chapterImagesCollection.frame = newFrameTemp;
    self.transcriptContainerView.frame = newFrameTemp;
    [self.transcriptContainerView layoutIfNeeded];
    CGFloat pickerMaxWidth = MIN(280.0, MAX(CGRectGetWidth(newFrameTemp) - 12.0, 80.0));
    CGSize pickerSize = [self.transcriptPickerButton sizeThatFits:CGSizeMake(pickerMaxWidth, 24.0)];
    pickerSize.width = MIN(MAX(pickerSize.width + 4.0, 56.0), pickerMaxWidth);
    pickerSize.height = 22.0;
    self.transcriptPickerButton.frame = CGRectMake(CGRectGetMaxX(newFrameTemp) - pickerSize.width - 6.0,
                                                   CGRectGetMaxY(newFrameTemp) - pickerSize.height - 1.0,
                                                   pickerSize.width,
                                                   pickerSize.height);
    CGFloat verticalInset = MAX((CGRectGetHeight(self.transcriptTextView.bounds) * 0.5f) - 36.0f, 0);
    self.transcriptTextView.contentInset = UIEdgeInsetsMake(verticalInset, 0, verticalInset, 0);

    BOOL hasContent = [self _hasContentBelowImage];
    CGFloat chevronAreaHeight = hasContent ? 25.0f : 0.0f;
    CGRect chapterViewFrame = newFrameTemp;
    chapterViewFrame.size.height += chevronAreaHeight;
    self.chapterView.frame = chapterViewFrame;

    chevronIndicatorView.hidden = !hasContent;
    chevronIndicatorView.frame = CGRectMake(0, CGRectGetHeight(newFrameTemp) + 4, CGRectGetWidth(newFrameTemp), 20);

    [self.chapterImagesCollection reloadData];
    [self _applyTranscriptVisibility];
    [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
}

-(UIInterfaceOrientation)getDeviceOrientation
{
    UIWindowScene* windowScene = [self _activeWindowScene];
    if (windowScene) {
        return windowScene.interfaceOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

-(UIWindow *)getKeyWindow {
    // Use the scene-aware helper from Application class
    return App.ic_keyWindow;
}

- (CGRect)getStatusBarFrame {
    UIWindowScene* windowScene = [self _activeWindowScene];
    if (windowScene.statusBarManager) {
        return windowScene.statusBarManager.statusBarFrame;
    }
    return CGRectZero;
}

- (UIWindowScene*)_activeWindowScene
{
    if (@available(iOS 13.0, *)) {
        UIWindow* keyWindow = [self getKeyWindow];
        if ([keyWindow.windowScene isKindOfClass:[UIWindowScene class]]) {
            return keyWindow.windowScene;
        }

        for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene* windowScene = (UIWindowScene*)scene;
            if (windowScene.activationState == UISceneActivationStateForegroundActive ||
                windowScene.activationState == UISceneActivationStateForegroundInactive) {
                return windowScene;
            }
        }
    }
    return nil;
}

- (void) viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    _oldContentOffset = self.tableView.contentOffset;
    [self.transcriptFollowResumeTimer invalidate];
    self.transcriptFollowResumeTimer = nil;
    self.transcriptAutoFollowSuspended = NO;
    [self.transcriptSyncTimer invalidate];
    self.transcriptSyncTimer = nil;
}

- (void) reloadData
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    CDEpisode* episode = pman.playingEpisode ?: [AudioSession sharedAudioSession].episode;
    BOOL isCached = [[CacheManager sharedCacheManager] episodeIsCached:episode];
    DebugLog(@"[TranscriptData] reloadData episode=%@ title='%@' cached=%@ ready=%@ movingVideo=%@",
             episode.objectHash ?: @"(nil)",
             episode.title ?: @"",
             isCached ? @"YES" : @"NO",
             pman.ready ? @"YES" : @"NO",
             pman.movingVideo ? @"YES" : @"NO");
    self.transcriptDataEpisodeHash = episode.objectHash;
    self.chapters = (episode != nil) ? [episode sortedChapters] : @[];
    self.currentChapterIndex = pman.currentChapter;
    self.duration = episode.duration;
    
    [self reloadBookmarks];
    [self _refreshTranscriptState];
}

- (void) reload
{
    [self reloadData];
    [self.tableView reloadData];
    
    PlaybackManager* pman = [PlaybackManager playbackManager];
    BOOL movingVideo = pman.movingVideo;
    
    PlayerView* playerView = pman.playerView;
    
    if (playerView && movingVideo)
    {
        playerView.transform = CGAffineTransformIdentity;
        
        PlayerVideoViewController* videoViewController = self.videoViewController;
        
        if (!videoViewController) {
            videoViewController = [PlayerVideoViewController viewController];
        }
        
        videoViewController.playerView = playerView;
        videoViewController.videoSize = pman.viewImageSize;
        
        if (!self.videoViewController) {
            self.videoViewController = videoViewController;
        }
    }
    else if (self.videoViewController)
    {
        self.videoViewController = nil;
    }
    [self updateCollectionsImage:0];
    if (self.isViewLoaded && self.view.window != nil) {
        [self.tableView scrollRectToVisible:CGRectMake(0, 0, 10, 10) animated:YES];
    }
}

- (void) tintColorDidChange
{
    if (self.view.window != nil) {
        [self.tableView reloadData];
    }
    [self _updateTranscriptLabelAppearance];
    [self.transcriptPickerButton setTitleColor:ICMutedTextColor forState:UIControlStateNormal];
    self.transcriptPickerButton.tintColor = ICMutedTextColor;
}

- (void) reloadBookmarks
{
    CDEpisode* episode = [PlaybackManager playbackManager].playingEpisode ?: [AudioSession sharedAudioSession].episode;
    if (!episode.objectHash) {
        self.bookmarks = @[];
        return;
    }
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Bookmark" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@", episode.objectHash];
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"position" ascending:YES] ];
    
    self.bookmarks = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:nil];
}


- (void) setChapters:(NSArray *)chapters
{
    if (_chapters != chapters) {
        _chapters = chapters ?: @[];
        if (self.isViewLoaded && self.view.window != nil) {
            [self layoutHeaderView];
            [self.tableView reloadData];
        }
    }
}

- (void) setVideoViewController:(PlayerVideoViewController *)videoViewController
{
    if (_videoViewController != videoViewController)
    {
        PlayerVideoViewController* oldController = _videoViewController;
        
        _videoViewController = videoViewController;
        
        if (videoViewController) {
            [self addChildViewController:videoViewController];
            [self layoutHeaderView];
            [videoViewController didMoveToParentViewController:self];
        }
        else
        {
            [oldController willMoveToParentViewController:nil];
            [self layoutHeaderView];
            [oldController removeFromParentViewController];
        }
    }
}


#pragma mark -

- (void) setImage:(UIImage *)image {
    if (_image != image) {
        _image = image;
        self.imageView.image = image;
        [self updateCollectionsImage:0];
    }
}

#pragma mark -

- (void) _updateVisibleCells
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    for(NSIndexPath* indexPath in self.tableView.indexPathsForVisibleRows)
    {
        ChaptersTableViewCell* cell = (ChaptersTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:[ChaptersTableViewCell class]])
        {
            if (indexPath.row == pman.currentChapter) {
                cell.textLabel.textColor = self.view.tintColor;
                cell.numLabel.textColor = self.view.tintColor;
                cell.timeLabel.textColor = self.view.tintColor;
            }
            else
            {
                cell.textLabel.textColor = (indexPath.row <= pman.currentChapter) ? ICMutedTextColor : ICTextColor;
                cell.numLabel.textColor = ICMutedTextColor;
                cell.timeLabel.textColor = ICMutedTextColor;
            }
            
            BOOL hidden = (pman.currentChapter != indexPath.row);
            BOOL changed = (cell.progressView.hidden != hidden);
            cell.progressView.hidden = hidden;
            [cell.progressView setProgress:((pman.time - cell.objectValue.timecode) / cell.objectValue.duration) animated:(!hidden && !changed)];
        }
    }

}

- (BOOL) _hasChapters {
    return ([self.chapters count] > 0);
}

- (BOOL) _hasBookmarks {
    return ([self.bookmarks count] > 0);
}

- (BOOL) _hasUpNext {
    return ([[AudioSession sharedAudioSession].playlist count] > 0);
}

- (BOOL) _hasContentBelowImage {
    return [self _hasChapters] || [self _hasBookmarks] || [self _hasUpNext];
}

- (NSInteger) _chaptersSection {
    return 0;
}

- (NSInteger) _bookmarksSection {
    return 1;
}

- (NSInteger) _upNextSection {
    return 2;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

#pragma mark -

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self _hasChapters] && section == [self _chaptersSection]) {
        return [self.chapters count];
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection]) {
        return [self.bookmarks count];
    }
    else if ([self _hasUpNext] && section == [self _upNextSection]) {
        return [[AudioSession sharedAudioSession].playlist count];
    }
    return 0;
}


// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        ChaptersTableViewCell* cell = (ChaptersTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kChapterCell forIndexPath:indexPath];
        cell.backgroundColor = self.tableView.backgroundColor;
        
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        cell.objectValue = chapter;
        
        
        if (indexPath.row == pman.currentChapter) {
            cell.textLabel.textColor = self.view.tintColor;
            cell.numLabel.textColor = self.view.tintColor;
            cell.timeLabel.textColor = self.view.tintColor;
        }
        else {
            cell.textLabel.textColor = (indexPath.row <= pman.currentChapter) ? ICMutedTextColor : ICTextColor;
            cell.numLabel.textColor = ICMutedTextColor;
            cell.timeLabel.textColor = ICMutedTextColor;
        }
        
        // Strikethrough for auto-skipped chapters
        BOOL shouldStrike = NO;
        CDEpisode *episode = pman.playingEpisode;
        if (episode.feed) {
            NSString *skipKey = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", episode.feed.uid];
            NSString *chaptersName = [episode.feed stringForKey:skipKey];
            if (chaptersName.length > 0) {
                NSArray *skipNames = [chaptersName componentsSeparatedByString:@".  "];
                NSString *lowerTitle = chapter.title.lowercaseString;
                for (NSString *name in skipNames) {
                    if (name.length > 0 && [lowerTitle containsString:name.lowercaseString]) {
                        shouldStrike = YES;
                        break;
                    }
                }
            }
        }
        NSDictionary *attrs;
        if (shouldStrike) {
            attrs = @{
                NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle),
                NSForegroundColorAttributeName: cell.textLabel.textColor,
                NSFontAttributeName: cell.textLabel.font
            };
        } else {
            attrs = @{
                NSStrikethroughStyleAttributeName: @(NSUnderlineStyleNone),
                NSForegroundColorAttributeName: cell.textLabel.textColor,
                NSFontAttributeName: cell.textLabel.font
            };
        }
        cell.textLabel.attributedText = [[NSAttributedString alloc] initWithString:chapter.title attributes:attrs];

        cell.progressView.hidden = (pman.currentChapter != indexPath.row);
        cell.progressView.progress = 0;
        cell.progressView.tintColor = self.view.tintColor;
        cell.progressView.progress = (pman.time - chapter.timecode) / chapter.duration;
        
//        CGFloat progressY = CGRectGetHeight(cell.bounds) - 2; // Ensures 1pt height
//        cell.progressView.frame = CGRectMake(-1, progressY, CGRectGetWidth(cell.bounds) + 2, 2);
//        cell.progressView.layer.masksToBounds = YES;
        
        NSArray* actions = [cell.linkButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
        for(NSString* action in actions) {
            [cell.linkButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
        }
        
        [cell.linkButton setAssociatedObject:chapter forKey:@"__chapter"];
        [cell.linkButton addTarget:self action:@selector(handleChapterLinkButton:) forControlEvents:UIControlEventTouchUpInside];
        return cell;
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        PlayerBookmarksTableViewCell* cell = (PlayerBookmarksTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kBookmarkCell forIndexPath:indexPath];
        cell.backgroundColor = self.tableView.backgroundColor;
        
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        
        cell.textLabel.text = bookmark.title;
        
        NSInteger time = bookmark.position;
        cell.timeLabel.text = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(time/3600)%60, (long)(time/60%60), (long)time%60];
        
        return cell;
    }
    
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kUpNextCell forIndexPath:indexPath];

        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];

        // Highlight currently playing episode
        BOOL isPlaying = [episode isEqual:[AudioSession sharedAudioSession].episode];
        cell.backgroundColor = isPlaying ? ICTableSelectedBackgroundColor : self.tableView.backgroundColor;

        cell.embedded = YES;
        cell.panRecognizer.enabled = NO;
        cell.objectValue = episode;

        return cell;
    }
    
    return nil;
}

- (void) handleChapterLinkButton:(UIButton*)sender
{
    CDChapter* chapter = [sender associatedObjectForKey:@"__chapter"];
    [self handleShowNotesURL:chapter.linkURL];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection]) {
        return YES;
    }
    
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection]) {
        return YES;
    }
    
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
    {
        if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
        {
            CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
            
            NSMutableArray* newBookmarks = [self.bookmarks mutableCopy];
            [newBookmarks removeObject:bookmark];
            self.bookmarks = newBookmarks;
            
            [DMANAGER removeBookmark:bookmark];
            
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
        }
        
        else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
        {
            CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
            
            [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        return YES;
    }
    
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    [[AudioSession sharedAudioSession] reorderUpNextEpisodeFromIndex:fromIndexPath.row toIndex:toIndexPath.row];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        return [ChaptersTableViewCell proposedHeightWithTitle:chapter.title tableBounds:self.tableView.bounds];
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        return [PlayerBookmarksTableViewCell proposedHeightWithTitle:bookmark.title tableBounds:self.tableView.bounds];
    }
    else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
        return [EpisodesTableViewCell proposedHeightWithObjectValue:episode tableSize:self.tableView.bounds.size imageSize:CGSizeZero embedded:YES editing:self.editing];
    }
    return 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    PlayerInfoHeaderFooterView* headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:kHeaderView];
    
    headerView.editButton.tintColor = self.view.tintColor;
    headerView.doneButton.tintColor = self.view.tintColor;
    
    NSArray* actions = [headerView.editButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
    for(NSString* action in actions) {
        [headerView.editButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
    }
    
    actions = [headerView.doneButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
    for(NSString* action in actions) {
        [headerView.doneButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
    }
    
    if ([self _hasChapters] && section == [self _chaptersSection])
    {
        headerView.textLabel.text = @"Chapters".ls;
        headerView.canEdit = NO;
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection])
    {
        headerView.textLabel.text = @"Bookmarks".ls;
        headerView.canEdit = YES;
    }
    else if ([self _hasUpNext] && section == [self _upNextSection])
    {
        headerView.textLabel.text = @"Up Next".ls;
        headerView.canEdit = YES;
    }
    
    if (headerView.canEdit)
    {
        [headerView.editButton setAssociatedObject:headerView forKey:@"__headerView"];
        [headerView.editButton addTarget:self action:@selector(handleHeaderViewEditButton:) forControlEvents:UIControlEventTouchUpInside];
        
        [headerView.doneButton setAssociatedObject:headerView forKey:@"__headerView"];
        [headerView.doneButton addTarget:self action:@selector(handleHeaderViewDoneButton:) forControlEvents:UIControlEventTouchUpInside];
    }
    
    return headerView;
}

- (void) handleHeaderViewEditButton:(UIButton*)button
{
    PlayerInfoHeaderFooterView* headerView = [button associatedObjectForKey:@"__headerView"];
    [headerView setEditing:YES animated:YES];
    [self setEditing:YES animated:YES];
}

- (void) handleHeaderViewDoneButton:(UIButton*)button
{
    PlayerInfoHeaderFooterView* headerView = [button associatedObjectForKey:@"__headerView"];
    [headerView setEditing:NO animated:YES];
    [self setEditing:NO animated:YES];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self _hasChapters] && section == [self _chaptersSection]) {
        return 44;
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection]) {
        return 44;
    }
    else if ([self _hasUpNext] && section == [self _upNextSection]) {
        return 44;
    }
    
    return 0;
}


- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        
        NSArray* playbackChapters = pman.chapters;
        ICMetadataChapter* playbackChapter = playbackChapters[chapter.index];
        [pman seekToChapter:playbackChapter];
        [pman play];
        
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        
        if (self.editing)
        {
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Edit Bookmark".ls
                                                                           message:bookmark.title
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"Bookmark title".ls;
                textField.text = bookmark.title;
            }];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Save".ls
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                STRONG_SELF
                
                NSString* text = self.alertController.textFields.firstObject.text;
                
                [self perform:^(id sender) {
                    
                    bookmark.title = text;
                    [DMANAGER save];
                    
                    [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
                    
                } afterDelay:0.3];
                self.alertController = nil;
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction * action) {
                STRONG_SELF
                self.alertController = nil;
            }]];
            [alert setModalPresentationStyle:UIModalPresentationPopover];
            UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
            UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
            popPresenter.sourceView = [rootViewController view];
            popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
            popPresenter.permittedArrowDirections = 0;
            if ([ICAppearanceManager sharedManager].nightSettingMode)
            {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            }
            else
            {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            }
            self.alertController = alert;
            [self presentAlertControllerAnimated:YES completion:NULL];
        }
        else
        {
            NSTimeInterval time = bookmark.position;
            [pman seekToTime:time];
            [pman play];
            
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    }
    
    else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
        
        AudioSession* audioSession = [AudioSession sharedAudioSession];
        [audioSession playEpisode:episode];
    }
}

#pragma mark -

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (scrollView != self.tableView) {
        return;
    }

    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"11.0.0")) {
        return;
    }
    
    CGFloat topOffset = scrollView.contentInset.top;
    CGFloat yOffset = scrollView.contentOffset.y + topOffset;
    UIPanGestureRecognizer* recognizer = scrollView.panGestureRecognizer;
    CGPoint translation = [recognizer translationInView:scrollView];
    CGPoint velocity = [recognizer velocityInView:scrollView];
    
    PlaybackViewController* navigationController = (PlaybackViewController*)self.navigationController;
    
    if (yOffset <= 0 && [recognizer state] == UIGestureRecognizerStateChanged)
    {
        if (!navigationController.interactive) {
            [navigationController beginInteractiveDismissing];
            scrollView.showsVerticalScrollIndicator = NO;
            _dismissEnded = NO;
            _startY = translation.y;
        }
        
        translation.y -= _startY;
        [navigationController.dismissalAnimator _driveTransitionWithTranslation:translation velocity:velocity recognizerState:recognizer.state];
        
        scrollView.transform = CGAffineTransformMakeTranslation(0, yOffset);
        _oldScrollVelocity = velocity;
    }
    else
    {
        if (navigationController.interactive) {
            [navigationController.dismissalAnimator _driveTransitionWithTranslation:translation velocity:_oldScrollVelocity recognizerState:UIGestureRecognizerStateEnded];
            
            scrollView.showsVerticalScrollIndicator = YES;
            _dismissEnded = YES;
            _startY = 0;
        }
        
        if (_dismissEnded)
        {
            if (yOffset < 0) {
                scrollView.transform = CGAffineTransformMakeTranslation(0, yOffset);
                scrollView.bounces = NO;
            }
            else {
                scrollView.transform = CGAffineTransformIdentity;
                scrollView.bounces = YES;
                _dismissEnded = NO;
            }
        }
    }
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    if (self->chapterImagesArray.count <= 0)
    {
        return 1;
    }
    // Episode artwork at index 0, chapter images at indices 1...N
    return self->chapterImagesArray.count + 1;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGRect b = self.rectCollection;
    CGRect wb = [[self getKeyWindow] bounds];
    CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
    CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        controllerHeight -= 60;
    }

    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        CGFloat size = MAX(CGRectGetWidth(b), 1);
        return CGSizeMake(size, size);
    }
    else
    {
        CGFloat width = MAX(CGRectGetHeight(b), 1);
        CGFloat height = MAX(CGRectGetWidth(b) - controllerHeight, 1);
        return CGSizeMake(width, height);
    }
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ChapterImageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chapter_cell" forIndexPath:indexPath];
    cell.chapterImageView.contentMode = UIViewContentModeScaleAspectFit;

    // Index 0 is always episode/feed artwork, indices 1...N are chapter images
    if (self->chapterImagesArray.count <= 0 || indexPath.item == 0)
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].episode;
        CDFeed* feed = episode.feed;
        NSURL* imageURL = (episode.imageURL) ? episode.imageURL : feed.imageURL;
        UIImage* cachedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:imageURL size:320 grayscale:NO];

        if (cachedImage) {
            cell.chapterImageView.image = cachedImage;
            UIColor *averageColor = [self averageColorFromImage:cachedImage];
            cell.contentView.backgroundColor = averageColor;
        }
        else {
            cell.chapterImageView.image = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? [UIImage imageNamed:@"Podcast Placeholder 580"] : [UIImage imageNamed:@"Podcast Placeholder 320"];
            cell.contentView.backgroundColor = [UIColor clearColor];
        }
    }
    else
    {
        // Chapter images are at indices 1...N, so subtract 1 to get array index
        NSInteger chapterIndex = indexPath.item - 1;
        if (chapterIndex < self->chapterImagesArray.count && [self->chapterImagesArray objectAtIndex:chapterIndex] != nil)
        {
            ICMetadataImage* artwork = self->chapterImagesArray[chapterIndex];
            [artwork loadPlatformImageScaleToWidth:CGRectGetWidth(self.view.bounds)*[ImageCacheManager scalingFactor] completion:^(id platformImage) {
                if (platformImage) {
                    cell.chapterImageView.image = platformImage;
                    UIColor *averageColor = [self averageColorFromImage:platformImage];
                    cell.contentView.backgroundColor = averageColor;
                } else {
                    // Fallback to episode/feed artwork when chapter image fails
                    CDEpisode* episode = [AudioSession sharedAudioSession].episode;
                    CDFeed* feed = episode.feed;
                    NSURL* imageURL = (episode.imageURL) ? episode.imageURL : feed.imageURL;
                    UIImage* cachedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:imageURL size:320 grayscale:NO];
                    if (cachedImage) {
                        cell.chapterImageView.image = cachedImage;
                        UIColor *averageColor = [self averageColorFromImage:cachedImage];
                        cell.contentView.backgroundColor = averageColor;
                    } else {
                        cell.chapterImageView.image = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? [UIImage imageNamed:@"Podcast Placeholder 580"] : [UIImage imageNamed:@"Podcast Placeholder 320"];
                        cell.contentView.backgroundColor = [UIColor clearColor];
                    }
                }
            }];
        }
    }
    return cell;
}

- (UIColor *)averageColorFromImage:(UIImage *)image {
    if (!image) return [UIColor clearColor];

    // Cache lookup by image pointer identity
    NSValue *key = [NSValue valueWithNonretainedObject:image];
    if (!self.averageColorCache) {
        self.averageColorCache = [NSMutableDictionary dictionary];
    }
    UIColor *cached = self.averageColorCache[key];
    if (cached) return cached;

    // Resize the image to a 1x1 pixel to get the average color
    unsigned char pixel[4] = {0};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);

    UIColor *color = [UIColor colorWithRed:pixel[0] / 255.0
                                     green:pixel[1] / 255.0
                                      blue:pixel[2] / 255.0
                                     alpha:1.0];
    self.averageColorCache[key] = color;
    return color;
}


- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if (scrollView == self.transcriptTextView) {
        self.transcriptAutoFollowSuspended = YES;
        [self _scheduleTranscriptAutoFollowResume];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (scrollView == self.transcriptTextView) {
        self.transcriptAutoFollowSuspended = YES;
        if (!decelerate) {
            [self _scheduleTranscriptAutoFollowResume];
        }
    }
}

-(void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    if (scrollView == self.transcriptTextView) {
        self.transcriptAutoFollowSuspended = YES;
        [self _scheduleTranscriptAutoFollowResume];
        return;
    }

    if (scrollView == self.chapterImagesCollection) {
        [currentImageTimer invalidate];
        currentImageTimer = nil;
        currentImageTimer = [NSTimer scheduledTimerWithTimeInterval: 30 target: self selector: @selector(afterTimerSetCurrentImg:) userInfo: nil repeats: NO];
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    if (scrollView == self.tableView && self.pendingTranscriptShowAfterScrollToTop) {
        self.pendingTranscriptShowAfterScrollToTop = NO;
        self.transcriptVisible = YES;
        [self _applyTranscriptVisibility];
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptVisiblePreference"];
        PlaybackManager* pman = [PlaybackManager playbackManager];
        [self _updateTranscriptCueForPlaybackTime:pman.time animated:NO];
        [self _focusTranscriptCueAtIndex:self.activeTranscriptCueIndex animated:NO];
    }
}

-(void)afterTimerSetCurrentImg:(NSTimer *)timer {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    // currentArtwork 0 maps to collection index 1
    NSInteger collectionIndex = (pman.currentArtwork >= 0) ? pman.currentArtwork + 1 : 0;
    [self changeChapterImageIndex:collectionIndex];
    [currentImageTimer invalidate];
    currentImageTimer = nil;
}

- (void)changeChapterImageIndex:(NSUInteger)indexNumber
{
    if (self->chapterImagesArray.count <= 0)
    {
        PlaybackManager* pman = [PlaybackManager playbackManager];
        if (!pman.movingVideo && [pman.artworks count] > 0)
        {
            self->chapterImagesArray = pman.artworks;
        }
    }
    [self.chapterImagesCollection reloadData];
    // Total items = chapterImagesArray.count + 1 (episode artwork at index 0)
    NSUInteger totalItems = self->chapterImagesArray.count + 1;
    if (totalItems > indexNumber)
    {
        if (CGRectGetWidth(self.chapterImagesCollection.bounds) != 0)
        {
            [self.chapterImagesCollection scrollToItemAtIndexPath:[NSIndexPath indexPathForRow:indexNumber inSection:0] atScrollPosition:UICollectionViewScrollPositionCenteredHorizontally animated:false];
        }
    }
}

- (void)updateCollectionsImage:(NSUInteger)indexNumber {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    if (!pman.movingVideo && [pman.artworks count] > 0)
    {
        self->chapterImagesArray = pman.artworks;
    }
    [self.chapterImagesCollection reloadData];
}

- (void)updateCollectionsImage:(NSArray *)images atIndex:(NSUInteger)indexNumber {
}

@end
