//
//  AppleWatchSyncManager.m
//  Instacast
//

#import "AppleWatchSyncManager.h"
#import "CDModel.h"
#import "DatabaseManager.h"
#import "PlaybackManager.h"
#import "AudioSession.h"
#import "ICAppearanceManager.h"

#import <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
@import WatchConnectivity;
#define IC_WATCH_CONNECTIVITY_ENABLED 1
#else
#define IC_WATCH_CONNECTIVITY_ENABLED 0
#endif

NSString* const ICAppleWatchSyncManagerStateDidChangeNotification = @"ICAppleWatchSyncManagerStateDidChangeNotification";
NSString* const ICAppleWatchEpisodeStatesDidChangeNotification = @"ICAppleWatchEpisodeStatesDidChangeNotification";

static NSString* const ICAppleWatchMessageTypeKey = @"type";
static NSString* const ICAppleWatchManifestReplace = @"manifest.replace";
static NSString* const ICAppleWatchManifestRemoveEpisodes = @"manifest.removeEpisodes";
static NSString* const ICAppleWatchDownloadPrioritize = @"download.prioritize";
static NSString* const ICAppleWatchPlaybackPhoneState = @"playback.phoneState";
static NSString* const ICAppleWatchSuppressedAutomaticEpisodeHashesKey = @"ICAppleWatchSuppressedAutomaticEpisodeHashes";

@interface AppleWatchSyncManager ()
#if IC_WATCH_CONNECTIVITY_ENABLED
<WCSessionDelegate>
#endif

@property (nonatomic, readwrite) BOOL supported;
@property (nonatomic, readwrite) BOOL paired;
@property (nonatomic, readwrite) BOOL watchAppInstalled;
@property (nonatomic, readwrite) BOOL reachable;
@property (nonatomic, strong, readwrite) NSDate* lastSyncDate;
@property (nonatomic, strong, readwrite) NSDate* lastWatchStatusDate;
@property (nonatomic, readwrite) int64_t watchFreeBytes;
@property (nonatomic, readwrite) int64_t watchUsedBytes;
@property (nonatomic, readwrite) int64_t watchTotalBytes;
@property (nonatomic, readwrite) int64_t watchDownloadBytes;
@property (nonatomic, copy, readwrite) NSString* currentWatchDownloadTitle;
@property (nonatomic, copy) NSString* currentWatchDownloadHash;
@property (nonatomic, readwrite) int64_t currentWatchDownloadedBytes;
@property (nonatomic, readwrite) int64_t currentWatchExpectedBytes;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL needsManifestSyncAfterActivation;

- (void)_sendCurrentManifestAndNotify;

@end

@implementation AppleWatchSyncManager

+ (instancetype)sharedManager
{
    static AppleWatchSyncManager* manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
#if IC_WATCH_CONNECTIVITY_ENABLED
        _supported = [WCSession isSupported];
#else
        _supported = NO;
#endif
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)start
{
    if (self.started) {
        return;
    }
    self.started = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerDidEndNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerEpisodeDidFinishNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_appearanceDidUpdate:)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

#if IC_WATCH_CONNECTIVITY_ENABLED
    if ([WCSession isSupported]) {
        WCSession* session = WCSession.defaultSession;
        session.delegate = self;
        [session activateSession];
        [self _refreshSessionStateAndNotify:YES];
    }
#endif
}

- (NSArray<AppleWatchEpisodeState*>*)allEpisodeStates
{
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.sortDescriptors = @[
        [[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"episodeHash" ascending:YES],
    ];
    NSArray* results = [DMANAGER.objectContext executeFetchRequest:request error:nil];
    return results ?: @[];
}

- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates
{
    NSArray<AppleWatchEpisodeState*>* states = [self allEpisodeStates];
    states = [states filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject, NSDictionary<NSString*, id>* bindings) {
        (void)bindings;
        AppleWatchEpisodeState* state = evaluatedObject;
        return !state.removingFromWatch;
    }]];
    return [states sortedArrayUsingComparator:^NSComparisonResult(AppleWatchEpisodeState* first, AppleWatchEpisodeState* second) {
        CDEpisode* firstEpisode = [DMANAGER episodeWithObjectHash:first.episodeHash];
        CDEpisode* secondEpisode = [DMANAGER episodeWithObjectHash:second.episodeHash];

        NSDate* firstDate = [self _sortDateForState:first episode:firstEpisode];
        NSDate* secondDate = [self _sortDateForState:second episode:secondEpisode];
        return [secondDate compare:firstDate];
    }];
}

- (AppleWatchEpisodeState*)stateForEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return nil;
    }

    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.fetchLimit = 1;
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@", episodeHash];
    return [[DMANAGER.objectContext executeFetchRequest:request error:nil] firstObject];
}

- (AppleWatchEpisodeState*)_stateForEpisode:(CDEpisode*)episode createIfNeeded:(BOOL)createIfNeeded
{
    if (episode.objectHash.length == 0) {
        return nil;
    }

    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    if (!state && createIfNeeded) {
        state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState" inManagedObjectContext:DMANAGER.objectContext];
        state.episodeHash = episode.objectHash;
        state.feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
        state.watchAddedDate = [NSDate date];
        state.watchStatus = ICAppleWatchStatusSelected;
        state.lastPhonePosition = episode.position;
        state.lastPhonePositionDate = [NSDate date];
    }

    return state;
}

- (BOOL)isEpisodeSelectedForWatch:(CDEpisode*)episode
{
    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    return state && !state.removingFromWatch;
}

- (BOOL)isEpisodeDownloadedOnWatch:(CDEpisode*)episode
{
    return [[self stateForEpisodeHash:episode.objectHash] downloadedOnWatch];
}

- (BOOL)canSendEpisodeToWatch:(CDEpisode*)episode
{
    if (!episode || episode.video || episode.archived) {
        return NO;
    }
    return ([self _mediaURLStringForEpisode:episode].length > 0);
}

- (void)sendEpisodeToWatch:(CDEpisode*)episode
{
    if (![self canSendEpisodeToWatch:episode]) {
        return;
    }

    AppleWatchEpisodeState* state = [self _stateForEpisode:episode createIfNeeded:YES];
    state.selectionSource = ICAppleWatchSelectionSourceManual;
    state.watchStatus = ICAppleWatchStatusSelected;
    state.watchAddedDate = state.watchAddedDate ?: [NSDate date];
    state.watchLastError = nil;
    state.feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
    state.lastPhonePosition = episode.position;
    state.lastPhonePositionDate = [NSDate date];
    [self _unsuppressAutomaticEpisodeHash:episode.objectHash];

    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self syncNow];
}

- (void)removeEpisodeFromWatch:(CDEpisode*)episode
{
    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    if (!state) {
        return;
    }

    state.watchStatus = ICAppleWatchStatusRemoving;
    state.watchLastError = nil;
    if ([state.selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
        [self _suppressAutomaticEpisodeHash:episode.objectHash];
    }
    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self _sendCommand:@{ ICAppleWatchMessageTypeKey: ICAppleWatchManifestRemoveEpisodes,
                          @"episodeHashes": @[episode.objectHash ?: @""] }];
}

- (void)prioritizeEpisodeOnWatch:(CDEpisode*)episode
{
    if (![self isEpisodeSelectedForWatch:episode] || [self isEpisodeDownloadedOnWatch:episode]) {
        return;
    }

    [self _sendCommand:@{ ICAppleWatchMessageTypeKey: ICAppleWatchDownloadPrioritize,
                          @"episodeHash": episode.objectHash ?: @"" }];
}

- (void)moveEpisodeAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex
{
    NSMutableArray<AppleWatchEpisodeState*>* states = [[self visibleEpisodeStates] mutableCopy];
    if (fromIndex >= states.count || toIndex >= states.count || fromIndex == toIndex) {
        return;
    }

    AppleWatchEpisodeState* state = states[fromIndex];
    [states removeObjectAtIndex:fromIndex];
    [states insertObject:state atIndex:toIndex];
    [self _assignWatchOrderDatesForStates:states];
    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self syncNow];
}

- (void)rebuildAutomaticSelectionsAndSync
{
    [self _rebuildAutomaticSelections];
    [self syncNow];
}

- (void)syncNow
{
    [self _rebuildAutomaticSelections];
    [self _sendCurrentManifestAndNotify];
}

- (void)syncCurrentSelectionsNow
{
    [self _sendCurrentManifestAndNotify];
}

- (void)_sendCurrentManifestAndNotify
{
    NSArray<NSDictionary*>* entries = [self _manifestEntries];
    NSDictionary* payload = @{
        ICAppleWatchMessageTypeKey: ICAppleWatchManifestReplace,
        @"createdAt": [self _stringFromDate:[NSDate date]],
        @"accentColorHex": [self _currentAccentColorHex],
        @"episodes": entries,
    };

    BOOL didSend = [self _sendManifestPayload:payload];
    if (didSend) {
        for (AppleWatchEpisodeState* state in [self allEpisodeStates]) {
            if (state.removingFromWatch || state.downloadedOnWatch || [state.watchStatus isEqualToString:ICAppleWatchStatusDownloading]) {
                continue;
            }
            state.watchStatus = ICAppleWatchStatusManifestSent;
        }
        self.lastSyncDate = [NSDate date];
    }
    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
}

- (void)_rebuildAutomaticSelections
{
    NSMutableSet<NSString*>* desiredAutomaticHashes = [NSMutableSet set];
    NSSet<NSString*>* suppressedAutomaticHashes = [self _suppressedAutomaticEpisodeHashes];

    for (CDFeed* feed in DMANAGER.feeds) {
        NSInteger latestCount = [feed integerForKey:AppleWatchSendLatestCount];
        if (latestCount <= 0) {
            continue;
        }

        NSArray<CDEpisode*>* sortedEpisodes = [feed.episodes sortedArrayUsingDescriptors:@[
            [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO],
        ]];
        BOOL onlyUnplayed = [feed boolForKey:AppleWatchOnlyUnplayed];
        NSInteger addedCount = 0;

        for (CDEpisode* episode in sortedEpisodes) {
            if (addedCount >= latestCount) {
                break;
            }
            if (![self canSendEpisodeToWatch:episode]) {
                continue;
            }
            if ([suppressedAutomaticHashes containsObject:episode.objectHash ?: @""]) {
                continue;
            }
            if (onlyUnplayed && episode.consumed) {
                continue;
            }

            [desiredAutomaticHashes addObject:episode.objectHash];
            AppleWatchEpisodeState* state = [self _stateForEpisode:episode createIfNeeded:YES];
            if (!state.manuallySelected) {
                state.selectionSource = ICAppleWatchSelectionSourceLatestRule;
                if (state.watchStatus.length == 0 || [state.watchStatus isEqualToString:ICAppleWatchStatusRemoving]) {
                    state.watchStatus = ICAppleWatchStatusSelected;
                }
                state.watchAddedDate = episode.pubDate ?: state.watchAddedDate ?: [NSDate date];
                state.feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
            }
            addedCount += 1;
        }
    }

    for (AppleWatchEpisodeState* state in [self allEpisodeStates]) {
        if (state.manuallySelected) {
            continue;
        }
        if (![desiredAutomaticHashes containsObject:state.episodeHash ?: @""]) {
            state.watchStatus = ICAppleWatchStatusRemoving;
        }
    }

    [DMANAGER save];
}

- (NSArray<NSDictionary*>*)_manifestEntries
{
    NSMutableArray<NSDictionary*>* entries = [NSMutableArray array];
    NSUInteger playbackOrder = 0;

    for (AppleWatchEpisodeState* state in [self visibleEpisodeStates]) {
        if (state.removingFromWatch) {
            continue;
        }

        CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
        NSMutableDictionary* entry = [[self _manifestEntryForEpisode:episode state:state] mutableCopy];
        if (entry) {
            entry[@"playbackOrder"] = @(playbackOrder);
            [entries addObject:entry];
            playbackOrder += 1;
        }
    }

    return entries;
}

- (NSDictionary*)_manifestEntryForEpisode:(CDEpisode*)episode state:(AppleWatchEpisodeState*)state
{
    if (![self canSendEpisodeToWatch:episode]) {
        return nil;
    }

    NSString* mediaURL = [self _mediaURLStringForEpisode:episode];
    NSString* feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
    NSDate* pubDate = episode.pubDate ?: [NSDate dateWithTimeIntervalSince1970:0];
    NSDate* addedDate = state.watchAddedDate ?: [NSDate date];
    NSInteger skipForwardSeconds = [self _skipSecondsForEpisode:episode key:PlayerSkipForwardPeriod fallback:30];
    NSInteger skipBackwardSeconds = [self _skipSecondsForEpisode:episode key:PlayerSkipBackPeriod fallback:30];

    return @{
        @"episodeHash": episode.objectHash ?: @"",
        @"feedIdentifier": feedIdentifier ?: @"",
        @"title": episode.title ?: @"",
        @"podcastTitle": episode.feed.displayTitle ?: episode.feed.title ?: @"",
        @"subtitle": episode.subtitle ?: episode.summary ?: @"",
        @"imageURL": episode.imageURL.absoluteString ?: episode.feed.imageURL.absoluteString ?: @"",
        @"pubDate": [self _stringFromDate:pubDate],
        @"durationHint": @(MAX(0, episode.duration)),
        @"position": @(MAX(0, episode.position)),
        @"consumed": @(episode.consumed),
        @"mediaURL": mediaURL ?: @"",
        @"expectedFileSize": @(MAX((int64_t)0, episode.preferedMedium.byteSize)),
        @"selectionSource": state.selectionSource ?: ICAppleWatchSelectionSourceManual,
        @"watchAddedDate": [self _stringFromDate:addedDate],
        @"skipForwardSeconds": @(skipForwardSeconds),
        @"skipBackwardSeconds": @(skipBackwardSeconds),
    };
}

- (NSInteger)_skipSecondsForEpisode:(CDEpisode*)episode key:(NSString*)key fallback:(NSInteger)fallback
{
    NSInteger seconds = [episode.feed integerForKey:key];
    if (seconds <= 0) {
        seconds = [USER_DEFAULTS integerForKey:key];
    }
    return seconds > 0 ? seconds : fallback;
}

- (NSString*)_mediaURLStringForEpisode:(CDEpisode*)episode
{
    NSURL* url = episode.preferedMedium.fileURL;
    NSString* value = url.absoluteString;
    return (value.length > 0) ? value : nil;
}

- (NSString*)_feedIdentifierForFeed:(CDFeed*)feed
{
    NSString* source = feed.sourceURL.absoluteString;
    if (source.length > 0) {
        return source;
    }
    return feed.uid ?: @"";
}

- (NSDate*)_sortDateForState:(AppleWatchEpisodeState*)state episode:(CDEpisode*)episode
{
    if ([state.selectionSource isEqualToString:ICAppleWatchSelectionSourceManual]) {
        return state.watchAddedDate ?: episode.pubDate ?: [NSDate distantPast];
    }
    return episode.pubDate ?: state.watchAddedDate ?: [NSDate distantPast];
}

- (void)_assignWatchOrderDatesForStates:(NSArray<AppleWatchEpisodeState*>*)states
{
    NSDate* baseDate = [NSDate date];
    [states enumerateObjectsUsingBlock:^(AppleWatchEpisodeState* state, NSUInteger index, BOOL* stop) {
        (void)stop;
        state.watchAddedDate = [baseDate dateByAddingTimeInterval:-(NSTimeInterval)index];
    }];
}

- (NSSet<NSString*>*)_suppressedAutomaticEpisodeHashes
{
    NSArray* storedHashes = [[NSUserDefaults standardUserDefaults] arrayForKey:ICAppleWatchSuppressedAutomaticEpisodeHashesKey];
    return [NSSet setWithArray:storedHashes ?: @[]];
}

- (void)_setSuppressedAutomaticEpisodeHashes:(NSSet<NSString*>*)hashes
{
    NSArray* sortedHashes = [[hashes allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [[NSUserDefaults standardUserDefaults] setObject:sortedHashes forKey:ICAppleWatchSuppressedAutomaticEpisodeHashesKey];
}

- (void)_suppressAutomaticEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return;
    }

    NSMutableSet* hashes = [[self _suppressedAutomaticEpisodeHashes] mutableCopy];
    [hashes addObject:episodeHash];
    [self _setSuppressedAutomaticEpisodeHashes:hashes];
}

- (void)_unsuppressAutomaticEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return;
    }

    NSMutableSet* hashes = [[self _suppressedAutomaticEpisodeHashes] mutableCopy];
    if (![hashes containsObject:episodeHash]) {
        return;
    }
    [hashes removeObject:episodeHash];
    [self _setSuppressedAutomaticEpisodeHashes:hashes];
}

- (NSString*)_currentAccentColorHex
{
    UIColor* color = ICTintColor ?: [UIColor colorWithRed:1.f green:83/255.f blue:0.f alpha:1.f];
    UIColor* resolvedColor = [color resolvedColorWithTraitCollection:UIScreen.mainScreen.traitCollection] ?: color;
    CGFloat red = 1.f;
    CGFloat green = 83/255.f;
    CGFloat blue = 0.f;
    CGFloat alpha = 1.f;
    if (![resolvedColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.f;
        if ([resolvedColor getWhite:&white alpha:&alpha]) {
            red = white;
            green = white;
            blue = white;
        }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lrint(MAX(0.f, MIN(1.f, red)) * 255.f),
            (int)lrint(MAX(0.f, MIN(1.f, green)) * 255.f),
            (int)lrint(MAX(0.f, MIN(1.f, blue)) * 255.f)];
}

- (void)_playbackDidUpdate:(NSNotification*)notification
{
    CDEpisode* episode = [AudioSession sharedAudioSession].episode ?: [PlaybackManager playbackManager].playingEpisode;
    if (![self isEpisodeSelectedForWatch:episode]) {
        return;
    }

    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    NSDate* now = [NSDate date];
    state.lastPhonePosition = episode.position;
    state.lastPhonePositionDate = now;
    if (episode.consumed) {
        state.watchConsumed = YES;
        state.watchConsumedDate = now;
    }
    [DMANAGER save];

    NSDictionary* payload = @{
        ICAppleWatchMessageTypeKey: ICAppleWatchPlaybackPhoneState,
        @"episodeHash": episode.objectHash ?: @"",
        @"position": @(MAX(0, episode.position)),
        @"consumed": @(episode.consumed),
        @"timestamp": [self _stringFromDate:now],
    };
    [self _sendCurrentStateMessage:payload];
}

- (void)_appearanceDidUpdate:(NSNotification*)notification
{
    (void)notification;
    if ([self allEpisodeStates].count > 0) {
        [self syncNow];
    }
}

- (void)_sendCommand:(NSDictionary*)command
{
    [self _sendLiveOrQueuedMessage:command];
    [self _refreshSessionStateAndNotify:YES];
}

- (void)_sendLiveOrQueuedMessage:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    WCSession* session = WCSession.defaultSession;
    if (![WCSession isSupported] || session.activationState != WCSessionActivationStateActivated) {
        return;
    }
    if (session.reachable) {
        [session sendMessage:payload replyHandler:nil errorHandler:^(__unused NSError* error) {
            [self _transferUserInfo:payload];
        }];
    }
    else {
        [self _transferUserInfo:payload];
    }
#endif
}

- (void)_sendCurrentStateMessage:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    WCSession* session = WCSession.defaultSession;
    if (![WCSession isSupported] || session.activationState != WCSessionActivationStateActivated) {
        return;
    }

    [session updateApplicationContext:payload error:nil];
    if (session.reachable) {
        [session sendMessage:payload replyHandler:nil errorHandler:nil];
    }
#endif
}

- (BOOL)_sendManifestPayload:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    if (![WCSession isSupported]) {
        return NO;
    }

    WCSession* session = WCSession.defaultSession;
    if (session.activationState != WCSessionActivationStateActivated || !session.watchAppInstalled) {
        self.needsManifestSyncAfterActivation = YES;
        return NO;
    }

    NSError* contextError = nil;
    [session updateApplicationContext:payload error:&contextError];
    if (contextError) {
        [self _transferUserInfo:payload];
    }

    if (session.reachable) {
        [session sendMessage:payload replyHandler:nil errorHandler:^(__unused NSError* error) {
            [self _transferUserInfo:payload];
        }];
    }

    self.needsManifestSyncAfterActivation = NO;
    return YES;
#else
    return NO;
#endif
}

- (void)_transferUserInfo:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    if (![WCSession isSupported]) {
        return;
    }
    WCSession* session = WCSession.defaultSession;
    if (session.activationState != WCSessionActivationStateActivated) {
        return;
    }
    [session transferUserInfo:payload];
#endif
}

- (void)_handleIncomingPayload:(NSDictionary*)payload
{
    NSString* type = [payload[ICAppleWatchMessageTypeKey] isKindOfClass:[NSString class]] ? payload[ICAppleWatchMessageTypeKey] : nil;
    if (type.length == 0) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _handleIncomingPayloadOnMainThread:payload type:type];
    });
}

- (void)_handleIncomingPayloadOnMainThread:(NSDictionary*)payload type:(NSString*)type
{
    self.lastWatchStatusDate = [NSDate date];
    BOOL shouldSyncAfterHandling = NO;

    if ([type isEqualToString:@"watch.ackManifest"]) {
        NSArray* episodeHashes = [payload[@"episodeHashes"] isKindOfClass:[NSArray class]] ? payload[@"episodeHashes"] : @[];
        for (NSString* episodeHash in episodeHashes) {
            AppleWatchEpisodeState* state = [self stateForEpisodeHash:episodeHash];
            if (state && !state.downloadedOnWatch && !state.removingFromWatch) {
                state.watchStatus = ICAppleWatchStatusQueuedOnWatch;
                state.watchLastSeenDate = [NSDate date];
            }
        }
    }
    else if ([type isEqualToString:@"watch.downloadQueued"]) {
        [self _updateStateForPayload:payload status:ICAppleWatchStatusQueuedOnWatch error:nil];
    }
    else if ([type isEqualToString:@"watch.downloadProgress"]) {
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusDownloading error:nil];
        [self _updateCurrentWatchDownloadFromPayload:payload state:state];
    }
    else if ([type isEqualToString:@"watch.downloaded"]) {
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusDownloaded error:nil];
        if (state) {
            state.watchDownloadedDate = [self _dateFromPayload:payload key:@"timestamp"] ?: [NSDate date];
            state.watchActualDuration = [payload[@"actualDuration"] intValue];
            state.watchActualFileSize = [payload[@"actualFileSize"] longLongValue];
            [self _clearCurrentWatchDownloadIfMatchesHash:state.episodeHash];
        }
        else {
            [self _clearCurrentWatchDownloadIfMatchesHash:payload[@"episodeHash"]];
        }
    }
    else if ([type isEqualToString:@"watch.downloadFailed"]) {
        NSString* error = [payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : @"";
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusFailed error:error];
        [self _clearCurrentWatchDownloadIfMatchesHash:state.episodeHash ?: payload[@"episodeHash"]];
    }
    else if ([type isEqualToString:@"watch.deleted"]) {
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        AppleWatchEpisodeState* state = [self stateForEpisodeHash:episodeHash];
        [self _clearCurrentWatchDownloadIfMatchesHash:episodeHash];
        if (state) {
            if (state.removingFromWatch) {
                [DMANAGER.objectContext deleteObject:state];
            }
            else {
                if ([state.selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
                    [self _suppressAutomaticEpisodeHash:episodeHash];
                }
                [DMANAGER.objectContext deleteObject:state];
                shouldSyncAfterHandling = YES;
            }
        }
    }
    else if ([type isEqualToString:@"watch.downloadEvicted"]) {
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        AppleWatchEpisodeState* state = [self stateForEpisodeHash:episodeHash];
        [self _clearCurrentWatchDownloadIfMatchesHash:episodeHash];
        if (state) {
            state.watchStatus = ICAppleWatchStatusQueuedOnWatch;
            state.watchDownloadedDate = nil;
            state.watchActualFileSize = 0;
            state.watchActualDuration = 0;
        }
    }
    else if ([type isEqualToString:@"watch.storageStatus"]) {
        self.watchFreeBytes = [payload[@"freeBytes"] longLongValue];
        self.watchUsedBytes = [payload[@"usedBytes"] longLongValue];
        self.watchTotalBytes = [payload[@"totalBytes"] longLongValue];
        self.watchDownloadBytes = [payload[@"instacastWatchDownloadBytes"] longLongValue];
    }
    else if ([type isEqualToString:@"playback.watchPosition"] || [type isEqualToString:@"playback.watchFinished"]) {
        [self _mergeWatchPlaybackPayload:payload finished:[type isEqualToString:@"playback.watchFinished"]];
    }

    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
    if (shouldSyncAfterHandling) {
        [self syncNow];
    }
}

- (AppleWatchEpisodeState*)_updateStateForPayload:(NSDictionary*)payload status:(NSString*)status error:(NSString*)error
{
    NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episodeHash];
    if (!state) {
        return nil;
    }
    state.watchStatus = status;
    state.watchLastSeenDate = [self _dateFromPayload:payload key:@"timestamp"] ?: [NSDate date];
    state.watchLastError = error;
    return state;
}

- (void)_updateCurrentWatchDownloadFromPayload:(NSDictionary*)payload state:(AppleWatchEpisodeState*)state
{
    if (!state) {
        return;
    }

    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    self.currentWatchDownloadHash = state.episodeHash;
    self.currentWatchDownloadTitle = episode.title ?: @"";
    self.currentWatchDownloadedBytes = MAX((int64_t)0, [payload[@"downloadedBytes"] longLongValue]);
    self.currentWatchExpectedBytes = MAX((int64_t)0, [payload[@"expectedBytes"] longLongValue]);
}

- (void)_clearCurrentWatchDownloadIfMatchesHash:(NSString*)episodeHash
{
    if (![episodeHash isKindOfClass:[NSString class]] || episodeHash.length == 0) {
        return;
    }
    if (self.currentWatchDownloadHash.length > 0 && ![self.currentWatchDownloadHash isEqualToString:episodeHash]) {
        return;
    }
    self.currentWatchDownloadHash = nil;
    self.currentWatchDownloadTitle = nil;
    self.currentWatchDownloadedBytes = 0;
    self.currentWatchExpectedBytes = 0;
}

- (void)_mergeWatchPlaybackPayload:(NSDictionary*)payload finished:(BOOL)finished
{
    NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
    if (episodeHash.length == 0) {
        return;
    }

    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episodeHash];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    if (!state || !episode) {
        return;
    }

    NSDate* timestamp = [self _dateFromPayload:payload key:@"timestamp"] ?: [NSDate date];
    NSDate* newestPhoneDate = state.lastPhonePositionDate ?: [NSDate distantPast];
    if ([timestamp compare:newestPhoneDate] == NSOrderedAscending && !finished) {
        return;
    }

    int32_t position = (int32_t)[payload[@"position"] intValue];
    int32_t duration = MAX(episode.duration, state.watchActualDuration);
    if (duration > 0) {
        position = MIN(position, duration);
    }
    position = MAX(0, position);

    state.lastWatchPosition = position;
    state.lastWatchPositionDate = timestamp;

    if (finished || [payload[@"consumed"] boolValue]) {
        [DMANAGER markEpisode:episode asConsumed:YES];
        state.watchConsumed = YES;
        state.watchConsumedDate = timestamp;
    }
    else {
        [DMANAGER setEpisode:episode position:position];
    }
}

- (void)_postEpisodeStatesChanged
{
    [[NSNotificationCenter defaultCenter] postNotificationName:ICAppleWatchEpisodeStatesDidChangeNotification object:self];
}

- (void)_refreshSessionStateAndNotify:(BOOL)notify
{
    BOOL oldPaired = self.paired;
    BOOL oldInstalled = self.watchAppInstalled;
    BOOL oldReachable = self.reachable;

#if IC_WATCH_CONNECTIVITY_ENABLED
    if ([WCSession isSupported]) {
        WCSession* session = WCSession.defaultSession;
        self.supported = YES;
        self.paired = session.paired;
        self.watchAppInstalled = session.watchAppInstalled;
        self.reachable = session.reachable;
    }
    else
#endif
    {
        self.supported = NO;
        self.paired = NO;
        self.watchAppInstalled = NO;
        self.reachable = NO;
    }

    if (notify && (oldPaired != self.paired || oldInstalled != self.watchAppInstalled || oldReachable != self.reachable)) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ICAppleWatchSyncManagerStateDidChangeNotification object:self];
    }
}

- (NSString*)_stringFromDate:(NSDate*)date
{
    static NSISO8601DateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

- (NSDate*)_dateFromPayload:(NSDictionary*)payload key:(NSString*)key
{
    id value = payload[key];
    if ([value isKindOfClass:[NSDate class]]) {
        return value;
    }
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    static NSISO8601DateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter dateFromString:value];
}

#if IC_WATCH_CONNECTIVITY_ENABLED

- (void)session:(WCSession*)session activationDidCompleteWithState:(WCSessionActivationState)activationState error:(NSError*)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
        if (activationState == WCSessionActivationStateActivated && session.watchAppInstalled && (self.needsManifestSyncAfterActivation || [self allEpisodeStates].count > 0)) {
            [self syncNow];
        }
    });
}

- (void)sessionDidBecomeInactive:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
    });
}

- (void)sessionDidDeactivate:(WCSession*)session
{
    [session activateSession];
}

- (void)sessionReachabilityDidChange:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
    });
}

- (void)sessionWatchStateDidChange:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
        if (session.watchAppInstalled && self.needsManifestSyncAfterActivation) {
            [self syncNow];
        }
    });
}

- (void)session:(WCSession*)session didReceiveUserInfo:(NSDictionary<NSString*, id>*)userInfo
{
    [self _handleIncomingPayload:userInfo];
}

- (void)session:(WCSession*)session didReceiveMessage:(NSDictionary<NSString*, id>*)message
{
    [self _handleIncomingPayload:message];
}

- (void)session:(WCSession*)session didReceiveApplicationContext:(NSDictionary<NSString*, id>*)applicationContext
{
    [self _handleIncomingPayload:applicationContext];
}

- (void)session:(WCSession*)session didReceiveMessage:(NSDictionary<NSString*, id>*)message replyHandler:(void (^)(NSDictionary<NSString*, id>* replyMessage))replyHandler
{
    [self _handleIncomingPayload:message];
    replyHandler(@{ @"ok": @YES });
}

#endif

@end
