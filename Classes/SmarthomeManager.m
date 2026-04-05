//
//  SmarthomeManager.m
//  Instacast
//
//  MQTT smart home integration manager.
//

#import "SmarthomeManager.h"
#import "ICMQTTClient.h"
#import "ICMetadata.h"
#import "Reachability.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MPVolumeView.h>
#import <ifaddrs.h>
#import <net/if.h>

NSString* SmarthomeManagerDidChangeConnectionStateNotification = @"SmarthomeManagerDidChangeConnectionStateNotification";

@interface SmarthomeManager () <ICMQTTClientDelegate>
{
    ICMQTTClient *_client;
    NSTimer *_statusTimer;
    NSTimer *_reconnectTimer;
    NSTimeInterval _reconnectDelay;
    BOOL _intentionalDisconnect;

    // Dynamic topic base: "InstacastPlus/{deviceName}"
    NSString *_topicBase;

    // Deduplication: last published values
    NSString *_lastPlay;
    NSString *_lastVolume;
    NSString *_lastPodcastName;
    NSString *_lastPodcastEpisode;
    NSString *_lastChapter;
    NSString *_lastSpeed;
    NSString *_lastPosition;
    NSString *_lastDuration;
    NSString *_lastProgress;
    NSString *_lastSleeptimerActive;
    NSString *_lastSleeptimerRemaining;
    NSString *_lastOutputDevice;
    NSString *_lastLocked;
    NSString *_lastCharging;
    NSString *_lastBatteryLevel;
    NSString *_lastFellAsleep;
    NSString *_lastAppActive;
    NSString *_lastMotionDetected;

    // Pending events to send after reconnect
    BOOL _pendingEpisodeFinished;

    // Motion detection throttling
    NSTimer *_motionResetTimer;
    BOOL _motionDetectedState;
    BOOL _fellAsleepActive;

    // Fell-asleep auto-reset
    NSTimer *_fellAsleepResetTimer;
}
@end

@implementation SmarthomeManager

+ (SmarthomeManager*)sharedManager
{
    static SmarthomeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SmarthomeManager alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _reconnectDelay = 2.0;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidStart:) name:PlaybackManagerDidStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidEnd:) name:PlaybackManagerDidEndNotification object:nil];
        // PlaybackManagerDidUpdateNotification fires 30+ times/second during playback.
        // All continuous state (position, chapter, play) is handled by the 5-second statusTimer instead.
        // Discrete events (start, stop, episode change) have their own handlers below.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidChangeEpisode:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioRouteDidChange:) name:AudioSessionAudioRouteDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sleepTimerDidExpire:) name:AudioSessionSleepTimerDidExpireNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(motionDidDetect:) name:ApplicationDidDetectMotionNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(episodeDidFinish:) name:PlaybackManagerEpisodeDidFinishNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];

        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryStateDidChange:) name:UIDeviceBatteryStateDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(batteryLevelDidChange:) name:UIDeviceBatteryLevelDidChangeNotification object:nil];

        // KVO for system volume
        [[AVAudioSession sharedInstance] addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew context:NULL];

        // Network change
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkDidChange:) name:kReachabilityChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[AVAudioSession sharedInstance] removeObserver:self forKeyPath:@"outputVolume"];
}

#pragma mark - Topic Building

- (void)buildTopicBase
{
    NSString *deviceName = [USER_DEFAULTS stringForKey:SmarthomeDeviceName];
    if (deviceName && deviceName.length > 0) {
        _topicBase = [NSString stringWithFormat:@"InstacastPlus/%@", deviceName];
    } else {
        _topicBase = @"InstacastPlus";
    }
}

- (NSString*)topic:(NSString*)name
{
    return [NSString stringWithFormat:@"%@/%@", _topicBase, name];
}

- (NSString*)topicWildcard
{
    return [NSString stringWithFormat:@"%@/+", _topicBase];
}

+ (NSString*)defaultDeviceName
{
    NSString *name = [UIDevice currentDevice].name;
    // Sanitize for MQTT topic: replace spaces and special chars with hyphens
    NSMutableString *sanitized = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
            [sanitized appendFormat:@"%C", c];
        } else if (c == ' ') {
            [sanitized appendString:@"-"];
        }
        // Skip other characters (emojis, accented chars, etc.)
    }
    if (sanitized.length == 0) {
        return @"iPhone";
    }
    return [sanitized copy];
}

#pragma mark - Public

- (BOOL)_hasActiveWiFiInterface
{
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return NO;
    }

    BOOL hasWiFi = NO;
    for (struct ifaddrs *ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr) continue;
        if (strcmp(ifa->ifa_name, "en0") != 0) continue;

        sa_family_t family = ifa->ifa_addr->sa_family;
        if (family != AF_INET && family != AF_INET6) continue;

        BOOL isUp = (ifa->ifa_flags & IFF_UP) != 0;
        BOOL isRunning = (ifa->ifa_flags & IFF_RUNNING) != 0;
        BOOL isLoopback = (ifa->ifa_flags & IFF_LOOPBACK) != 0;
        if (isUp && isRunning && !isLoopback) {
            hasWiFi = YES;
            break;
        }
    }

    freeifaddrs(interfaces);
    return hasWiFi;
}

- (void)_tearDownClient
{
    if (!_client) return;
    [_statusTimer invalidate];
    _statusTimer = nil;
    _client.delegate = nil;
    [_client disconnect];
    _client = nil;
}

- (BOOL)_isOnWiFi
{
    // WiFi-only means "real WLAN interface active", independent of cellular fallback routes.
    return [self _hasActiveWiFiInterface];
}

- (void)start
{
    if (![USER_DEFAULTS boolForKey:SmarthomeMQTTEnabled]) return;

    NSString *host = [USER_DEFAULTS stringForKey:SmarthomeMQTTHost];
    if (!host || host.length == 0) return;

    if ([USER_DEFAULTS boolForKey:SmarthomeWiFiOnly] && ![self _isOnWiFi]) {
        if (_client && _client.connectionState != ICMQTTConnectionStateDisconnected) {
            [self _tearDownClient];
        }
        _connectionStatusText = @"Waiting for WiFi…".ls;
        [self postConnectionStateChange];
        return;
    }

    if (_client && _client.connectionState != ICMQTTConnectionStateDisconnected) return;

    _intentionalDisconnect = NO;
    [self buildTopicBase];
    [self connectToMQTT];
}

- (void)checkWiFiAndReconnect
{
    if ([USER_DEFAULTS boolForKey:SmarthomeWiFiOnly] && ![self _isOnWiFi]) {
        if (_client && _client.connectionState != ICMQTTConnectionStateDisconnected) {
            [self _tearDownClient];
        }
        _connectionStatusText = @"Waiting for WiFi…".ls;
        _intentionalDisconnect = NO;
        [self postConnectionStateChange];
    } else if (!self.connected && _client.connectionState != ICMQTTConnectionStateConnecting && !_intentionalDisconnect) {
        _reconnectDelay = 2.0;
        [self start];
    }
}

- (void)stop
{
    _intentionalDisconnect = YES;
    [_reconnectTimer invalidate];
    _reconnectTimer = nil;
    [_statusTimer invalidate];
    _statusTimer = nil;
    [_motionResetTimer invalidate];
    _motionResetTimer = nil;
    _motionDetectedState = NO;
    [_fellAsleepResetTimer invalidate];
    _fellAsleepResetTimer = nil;
    [self _tearDownClient];
    _connectionStatusText = @"Disconnected".ls;
    [self clearLastValues];
    [self clearPendingEvents];
    [self postConnectionStateChange];
}

- (void)clearPendingEvents
{
    _pendingEpisodeFinished = NO;
}

- (void)reconnectIfNeeded
{
    if (_intentionalDisconnect) return;
    if (self.connected) return;
    if (_client.connectionState == ICMQTTConnectionStateConnecting) return;

    [self start];
}

- (BOOL)connected
{
    return _client && _client.connectionState == ICMQTTConnectionStateConnected;
}

#pragma mark - Connection

- (void)connectToMQTT
{
    [self _tearDownClient];

    NSString *host = [USER_DEFAULTS stringForKey:SmarthomeMQTTHost];
    NSInteger port = [USER_DEFAULTS integerForKey:SmarthomeMQTTPort];
    NSString *user = [USER_DEFAULTS stringForKey:SmarthomeMQTTUsername];
    NSString *pass = [USER_DEFAULTS stringForKey:SmarthomeMQTTPassword];

    if (!host || host.length == 0) return;
    if (port == 0) port = 1883;

    _client = [[ICMQTTClient alloc] init];
    _client.delegate = self;
    _client.host = host;
    _client.port = (uint16_t)port;
    if (user.length > 0) _client.username = user;
    if (pass.length > 0) _client.password = pass;
    _client.keepAlive = 60;

    // Last Will and Testament
    _client.willTopic = [self topic:@"connected"];
    _client.willMessage = @"0";
    _client.willRetain = YES;

    _connectionStatusText = @"Connecting...".ls;
    [self postConnectionStateChange];
    [_client connect];
}

- (void)scheduleReconnect
{
    if (_intentionalDisconnect) return;
    if ([USER_DEFAULTS boolForKey:SmarthomeWiFiOnly] && ![self _isOnWiFi]) return;

    [_reconnectTimer invalidate];
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:_reconnectDelay target:self selector:@selector(reconnectTimerFired) userInfo:nil repeats:NO];

    // Exponential backoff, max 60s
    _reconnectDelay = MIN(_reconnectDelay * 2, 60.0);
}

- (void)reconnectTimerFired
{
    _reconnectTimer = nil;
    [self start];
}

#pragma mark - ICMQTTClientDelegate

- (void)mqttClientDidConnect:(ICMQTTClient*)client
{
    if (client != _client) return;

    _reconnectDelay = 2.0;
    _connectionStatusText = @"Connected".ls;
    [self postConnectionStateChange];

    // Publish connected status
    [_client publishMessage:@"1" toTopic:[self topic:@"connected"] retain:YES];

    // FIRST publish all current states (sets _last* values for echo prevention)
    [self clearLastValues];
    [self publishAllStates];

    // Send pending events that occurred while offline
    [self sendPendingEvents];

    // THEN subscribe to control topics only (not wildcard — avoids echoes of status-only topics)
    // _last* values are already set from publishAllStates, so retained echoes will be filtered
    if ([USER_DEFAULTS boolForKey:SmarthomeAllowControl]) {
        NSArray *controlTopics = @[
            @"play", @"skip-forward", @"skip-back", @"volume",
            @"playback-position", @"playback-speed", @"episode-progress",
            @"sleeptimer", @"sleeptimer-remaining", @"sleeptimer-active",
            @"next-chapter", @"prev-chapter", @"next-episode"
        ];
        for (NSString *name in controlTopics) {
            [_client subscribeToTopic:[self topic:name]];
        }
    }

    // Start periodic status timer (every 5 seconds for position/progress/sleeptimer)
    [_statusTimer invalidate];
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(statusTimerFired) userInfo:nil repeats:YES];
}

- (void)mqttClientDidDisconnect:(ICMQTTClient*)client error:(NSError*)error
{
    if (client != _client) return;

    [_statusTimer invalidate];
    _statusTimer = nil;

    if ([USER_DEFAULTS boolForKey:SmarthomeWiFiOnly] && ![self _isOnWiFi]) {
        _connectionStatusText = @"Waiting for WiFi…".ls;
        [self postConnectionStateChange];
        return;
    }

    if (error) {
        _connectionStatusText = [NSString stringWithFormat:@"%@: %@", @"Error".ls, error.localizedDescription];
    } else {
        _connectionStatusText = @"Disconnected".ls;
    }
    [self postConnectionStateChange];

    [self scheduleReconnect];
}

- (void)mqttClient:(ICMQTTClient*)client didReceiveMessage:(NSString*)message onTopic:(NSString*)topic
{
    if (client != _client) return;

    // Ignore empty/placeholder messages
    if (!message || message.length == 0 || [message isEqualToString:@"NaN"]) {
        return;
    }

    if (![USER_DEFAULTS boolForKey:SmarthomeAllowControl]) {
        return;
    }

    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];

    if ([topic isEqualToString:[self topic:@"play"]]) {
        NSInteger requested = [message integerValue];
        BOOL isPlaying = pm.playingEpisode && !pm.paused;

        if (requested == 1) {
            if (pm.playingEpisode) {
                if (!isPlaying) [pm play];
            } else {
                // No episode loaded - correct the value back to 0
                _lastPlay = nil;
                [self publishPlayState];
            }
        } else {
            if (isPlaying) [pm pause];
        }
    }
    else if ([topic isEqualToString:[self topic:@"skip-forward"]]) {
        if (pm.playingEpisode) {
            [pm seekForward];
        }
    }
    else if ([topic isEqualToString:[self topic:@"skip-back"]]) {
        if (pm.playingEpisode) {
            [pm seekBackward];
        }
    }
    else if ([topic isEqualToString:[self topic:@"volume"]]) {
        // Ignore if value matches current state (prevents echo)
        int currentVol = (int)([AVAudioSession sharedInstance].outputVolume * 100);
        int requestedVol = [message intValue];
        if (abs(currentVol - requestedVol) <= 1) return;

        float vol = requestedVol / 100.0f;
        vol = MAX(0, MIN(1, vol));
        [self setSystemVolume:vol];
    }
    else if ([topic isEqualToString:[self topic:@"playback-position"]]) {
        if (!pm.playingEpisode) {
            // No episode - correct the value back to 0
            _lastPosition = nil;
            [self publishPositionState];
            return;
        }

        // Ignore if this is our own published value echoed back (e.g. retained message on reconnect)
        if (_lastPosition && [_lastPosition isEqualToString:message]) return;

        // Ignore if value is close to current position
        NSTimeInterval currentPos = pm.time;
        NSTimeInterval requestedPos = [message doubleValue];
        if (fabs(currentPos - requestedPos) < 2.0) return;

        [pm seekToTime:requestedPos];
    }
    else if ([topic isEqualToString:[self topic:@"playback-speed"]]) {
        // Ignore echo of our own published value
        if (_lastSpeed && [_lastSpeed isEqualToString:message]) return;

        float rate = [message floatValue];
        if (rate >= 0.5f && rate <= 3.0f) {
            pm.playbackRate = rate;
        }
    }
    else if ([topic isEqualToString:[self topic:@"episode-progress"]]) {
        if (!pm.playingEpisode || pm.duration <= 0) {
            // No episode - correct the value back to 0
            _lastProgress = nil;
            [self publishPositionState];
            return;
        }

        // Ignore if this is our own published value echoed back
        if (_lastProgress && [_lastProgress isEqualToString:message]) return;

        // Ignore if value is close to current progress (prevents echo)
        int currentProgress = (int)((pm.time / pm.duration) * 100);
        int requestedProgress = [message intValue];
        if (abs(currentProgress - requestedProgress) <= 1) return;

        // Convert percentage to time and seek
        NSTimeInterval targetTime = (requestedProgress / 100.0) * pm.duration;
        [pm seekToTime:targetTime];
    }
    else if ([topic isEqualToString:[self topic:@"sleeptimer"]]) {
        // Set sleeptimer with arbitrary seconds (0=off)
        NSTimeInterval seconds = [message doubleValue];
        [as setTimerWithDuration:seconds];
    }
    else if ([topic isEqualToString:[self topic:@"sleeptimer-remaining"]]) {
        // Ignore echo of our own published value
        if (_lastSleeptimerRemaining && [_lastSleeptimerRemaining isEqualToString:message]) return;

        // External command: set sleeptimer with arbitrary seconds (0=off)
        NSTimeInterval seconds = [message doubleValue];
        [as setTimerWithDuration:seconds];
    }
    else if ([topic isEqualToString:[self topic:@"sleeptimer-active"]]) {
        // 0 = deactivate timer, 1 = ignored (use sleeptimer/sleeptimer-remaining to set duration)
        NSInteger active = [message integerValue];
        if (active == 0 && as.timerValue != PlaybackStopTimeNoValue) {
            as.timerValue = PlaybackStopTimeNoValue;
        }
    }
    else if ([topic isEqualToString:[self topic:@"next-chapter"]]) {
        if (pm.playingEpisode && pm.chapters.count > 0) {
            [pm nextChapter];
        }
    }
    else if ([topic isEqualToString:[self topic:@"prev-chapter"]]) {
        if (pm.playingEpisode && pm.chapters.count > 0) {
            [pm previousChapter];
        }
    }
    else if ([topic isEqualToString:[self topic:@"next-episode"]]) {
        CDEpisode *nextEpisode = [as nextPlayableEpisode];
        if (nextEpisode) {
            [as playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES];
        }
    }
}

#pragma mark - Pending Events

- (void)sendPendingEvents
{
    if (!self.connected) return;

    // Send episode-finished if it occurred while offline (not retained, but useful for automation)
    if (_pendingEpisodeFinished) {
        _pendingEpisodeFinished = NO;
        [_client publishMessage:@"1" toTopic:[self topic:@"episode-finished"] retain:NO];
    }
}

#pragma mark - State Publishing

- (void)publishAllStates
{
    [self publishPlayState];
    [self publishEpisodeInfo];
    [self publishVolumeState];
    [self publishSpeedState];
    [self publishPositionState];
    [self publishSleeptimerState];
    [self publishOutputDevice];
    [self publishLockState];
    [self publishChargingState];
    [self publishChapterState];
    [self publishBatteryLevel];
    [self publishAppState];
    [self publishFellAsleepState];
    [self publishMotionState];
}

- (void)publishFellAsleepState
{
    [self publishValue:(_fellAsleepActive ? @"1" : @"0")
               toTopic:[self topic:@"fell-asleep"]
             lastValue:&_lastFellAsleep
                retain:YES];
}

- (void)publishPlayState
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    BOOL hasEpisode = (pm.playingEpisode != nil);
    BOOL paused = pm.paused;
    BOOL podcastPlaying = pm.isPodcastPlaying;
    BOOL waiting = pm.waitingForLoad;
    BOOL playing = hasEpisode && !paused;
    [self publishValue:(playing ? @"1" : @"0") toTopic:[self topic:@"play"] lastValue:&_lastPlay retain:YES];
}

- (void)publishEpisodeInfo
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    CDEpisode *episode = pm.playingEpisode;

    NSString *podcastName = episode.feed.title ?: @"";
    NSString *episodeTitle = episode.title ?: @"";

    [self publishValue:podcastName toTopic:[self topic:@"podcast-name"] lastValue:&_lastPodcastName retain:YES];
    [self publishValue:episodeTitle toTopic:[self topic:@"podcast-episode"] lastValue:&_lastPodcastEpisode retain:YES];
}

- (void)publishChapterState
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    NSString *chapterName = @"";
    if (pm.chapters.count > 0 && pm.currentChapter >= 0 && pm.currentChapter < (NSInteger)pm.chapters.count) {
        ICMetadataChapter *chapter = pm.chapters[pm.currentChapter];
        chapterName = chapter.title ?: @"";
    }
    [self publishValue:chapterName toTopic:[self topic:@"chapter"] lastValue:&_lastChapter retain:YES];
}

- (void)publishVolumeState
{
    float vol = [AVAudioSession sharedInstance].outputVolume;
    NSString *value = [NSString stringWithFormat:@"%d", (int)(vol * 100)];
    [self publishValue:value toTopic:[self topic:@"volume"] lastValue:&_lastVolume retain:YES];
}

- (void)publishSpeedState
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    float rate = pm.playbackRate;
    if (rate <= 0) rate = 1.0f;
    NSString *speed = [NSString stringWithFormat:@"%.2g", rate];
    [self publishValue:speed toTopic:[self topic:@"playback-speed"] lastValue:&_lastSpeed retain:YES];
}

- (void)publishPositionState
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    if (!pm.playingEpisode) {
        [self publishValue:@"0" toTopic:[self topic:@"playback-position"] lastValue:&_lastPosition retain:YES];
        [self publishValue:@"0" toTopic:[self topic:@"episode-duration"] lastValue:&_lastDuration retain:YES];
        [self publishValue:@"0" toTopic:[self topic:@"episode-progress"] lastValue:&_lastProgress retain:YES];
        return;
    }

    NSString *pos = [NSString stringWithFormat:@"%d", (int)pm.time];
    NSString *dur = [NSString stringWithFormat:@"%d", (int)pm.duration];
    int progress = (pm.duration > 0) ? (int)((pm.time / pm.duration) * 100) : 0;
    NSString *prog = [NSString stringWithFormat:@"%d", progress];

    [self publishValue:pos toTopic:[self topic:@"playback-position"] lastValue:&_lastPosition retain:YES];
    [self publishValue:dur toTopic:[self topic:@"episode-duration"] lastValue:&_lastDuration retain:YES];
    [self publishValue:prog toTopic:[self topic:@"episode-progress"] lastValue:&_lastProgress retain:YES];
}

- (void)publishSleeptimerState
{
    AudioSession *as = [AudioSession sharedAudioSession];
    BOOL active = (as.timerValue != PlaybackStopTimeNoValue);
    NSString *activeStr = active ? @"1" : @"0";
    [self publishValue:activeStr toTopic:[self topic:@"sleeptimer-active"] lastValue:&_lastSleeptimerActive retain:YES];

    // Use timerRemainingTime which correctly handles pause state
    NSInteger remaining = 0;
    if (active) {
        remaining = (NSInteger)as.timerRemainingTime;
        if (remaining < 0) remaining = 0;
    }
    NSString *remainStr = [NSString stringWithFormat:@"%ld", (long)remaining];
    [self publishValue:remainStr toTopic:[self topic:@"sleeptimer-remaining"] lastValue:&_lastSleeptimerRemaining retain:YES];
}

- (void)publishOutputDevice
{
    AudioSession *as = [AudioSession sharedAudioSession];
    NSString *device;
    if (as.airPlayActive) {
        device = @"airplay";
    } else if (as.headphonesAttached) {
        device = @"headphones";
    } else {
        device = @"speaker";
    }
    [self publishValue:device toTopic:[self topic:@"output-device"] lastValue:&_lastOutputDevice retain:YES];
}

- (void)publishLockState
{
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    BOOL locked = (state != UIApplicationStateActive);
    [self publishValue:(locked ? @"1" : @"0") toTopic:[self topic:@"iphone-locked"] lastValue:&_lastLocked retain:YES];
}

- (void)publishChargingState
{
    UIDeviceBatteryState battery = [UIDevice currentDevice].batteryState;
    BOOL charging = (battery == UIDeviceBatteryStateCharging || battery == UIDeviceBatteryStateFull);
    [self publishValue:(charging ? @"1" : @"0") toTopic:[self topic:@"charging"] lastValue:&_lastCharging retain:YES];
}

- (void)publishBatteryLevel
{
    float level = [UIDevice currentDevice].batteryLevel;
    // batteryLevel returns -1.0 if monitoring not enabled or unknown
    int percent = (level < 0) ? 0 : (int)(level * 100);
    NSString *value = [NSString stringWithFormat:@"%d", percent];
    [self publishValue:value toTopic:[self topic:@"battery-level"] lastValue:&_lastBatteryLevel retain:YES];
}

- (void)publishAppState
{
    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    BOOL active = (state == UIApplicationStateActive);
    [self publishValue:(active ? @"1" : @"0") toTopic:[self topic:@"app-active"] lastValue:&_lastAppActive retain:YES];
}

- (void)publishMotionState
{
    [self publishValue:(_motionDetectedState ? @"1" : @"0")
               toTopic:[self topic:@"motion-detected"]
             lastValue:&_lastMotionDetected
                retain:YES];
}

#pragma mark - Deduplication Helper

- (void)publishValue:(NSString*)value toTopic:(NSString*)topic lastValue:(NSString*__strong*)lastValue retain:(BOOL)retain
{
    if (!self.connected) return;
    if (*lastValue && [*lastValue isEqualToString:value]) return;

    *lastValue = [value copy];
    [_client publishMessage:value toTopic:topic retain:retain];
}

- (void)clearLastValues
{
    _lastPlay = nil;
    _lastVolume = nil;
    _lastPodcastName = nil;
    _lastPodcastEpisode = nil;
    _lastChapter = nil;
    _lastSpeed = nil;
    _lastPosition = nil;
    _lastDuration = nil;
    _lastProgress = nil;
    _lastSleeptimerActive = nil;
    _lastSleeptimerRemaining = nil;
    _lastOutputDevice = nil;
    _lastLocked = nil;
    _lastCharging = nil;
    _lastBatteryLevel = nil;
    _lastFellAsleep = nil;
    _lastAppActive = nil;
    _lastMotionDetected = nil;
}

#pragma mark - Notification Handlers

- (void)playbackDidStart:(NSNotification*)note
{
    [self publishPlayState];
    [self publishEpisodeInfo];
    [self publishChapterState];
    [self publishSpeedState];
}

- (void)playbackDidEnd:(NSNotification*)note
{
    [self publishPlayState];
    [self publishEpisodeInfo];
    [self publishChapterState];
    [self publishPositionState];
}

- (void)playbackDidChangeEpisode:(NSNotification*)note
{
    [self publishEpisodeInfo];
    [self publishChapterState];
    [self publishSpeedState];
}

- (void)audioRouteDidChange:(NSNotification*)note
{
    [self publishOutputDevice];
}

- (void)sleepTimerDidExpire:(NSNotification*)note
{
    [self publishSleeptimerState];
    _fellAsleepActive = YES;
    [self publishFellAsleepState];

    // Auto-reset to "0" after 5 seconds, independent of connection state.
    [_fellAsleepResetTimer invalidate];
    _fellAsleepResetTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(fellAsleepResetTimerFired) userInfo:nil repeats:NO];
}

- (void)fellAsleepResetTimerFired
{
    _fellAsleepResetTimer = nil;
    _fellAsleepActive = NO;
    [self publishFellAsleepState];
}

- (void)resetFellAsleep
{
    // Manual reset helper (kept for compatibility).
    _fellAsleepActive = NO;
    [_fellAsleepResetTimer invalidate];
    _fellAsleepResetTimer = nil;
    [self publishFellAsleepState];
}

- (void)motionDidDetect:(NSNotification*)note
{
    // Keep state independent from playback/app/sleeptimer and connection.
    _motionDetectedState = YES;
    [self publishMotionState];

    // Reset/extend the timer - will publish "0" 5 seconds after last motion
    [_motionResetTimer invalidate];
    _motionResetTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(motionResetTimerFired) userInfo:nil repeats:NO];
}

- (void)motionResetTimerFired
{
    _motionResetTimer = nil;
    _motionDetectedState = NO;
    [self publishMotionState];
}

- (void)episodeDidFinish:(NSNotification*)note
{
    if (self.connected) {
        [_client publishMessage:@"1" toTopic:[self topic:@"episode-finished"] retain:NO];
    } else {
        // Store for later when we reconnect
        _pendingEpisodeFinished = YES;
    }
}

- (void)appDidBecomeActive:(NSNotification*)note
{
    if (self.connected) {
        // Force-refresh all states so the smart home system gets current values
        // even if we missed events while the app was in the background/suspended.
        [self clearLastValues];
        [self publishAllStates];
    } else {
        [self reconnectIfNeeded];
    }
}

- (void)appWillResignActive:(NSNotification*)note
{
    [self publishPlayState];
    [self publishLockState];
    [self publishAppState];
}

- (void)appDidEnterBackground:(NSNotification*)note
{
    [self publishPlayState];
    [self publishLockState];
    [self publishAppState];
}

- (void)appWillEnterForeground:(NSNotification*)note
{
    // Kick off reconnect early; the full state refresh happens in appDidBecomeActive.
    if (!self.connected) {
        [self reconnectIfNeeded];
    }
}

- (void)batteryStateDidChange:(NSNotification*)note
{
    [self publishChargingState];
    [self publishBatteryLevel];
}

- (void)batteryLevelDidChange:(NSNotification*)note
{
    [self publishBatteryLevel];
}

- (void)networkDidChange:(NSNotification*)note
{
    if ([USER_DEFAULTS boolForKey:SmarthomeWiFiOnly]) {
        if ([self _isOnWiFi]) {
            if (!self.connected && _client.connectionState != ICMQTTConnectionStateConnecting && !_intentionalDisconnect) {
                _reconnectDelay = 2.0;
                [self reconnectIfNeeded];
            }
        } else {
            // Left WiFi (or WiFi went down while connecting) - disconnect immediately.
            if (_client && _client.connectionState != ICMQTTConnectionStateDisconnected) {
                [self _tearDownClient];
            }
            _connectionStatusText = @"Waiting for WiFi…".ls;
            [self postConnectionStateChange];
        }
    } else if (!self.connected && _client.connectionState != ICMQTTConnectionStateConnecting) {
        // Reset reconnect delay for faster reconnection when network returns
        _reconnectDelay = 2.0;
        [self reconnectIfNeeded];
    }
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
    if ([keyPath isEqualToString:@"outputVolume"]) {
        [self publishVolumeState];
    }
}

#pragma mark - Status Timer

- (void)statusTimerFired
{
    [self publishPlayState];
    [self publishPositionState];
    [self publishChapterState];
    [self publishSleeptimerState];
    [self publishFellAsleepState];
    [self publishMotionState];
}

#pragma mark - System Volume

- (void)setSystemVolume:(float)volume
{
    // Use MPVolumeView to set system volume
    // Must keep a reference to volumeView so it's not deallocated before the slider is set
    MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    for (UIView *view in volumeView.subviews) {
        if ([view isKindOfClass:[UISlider class]]) {
            UISlider *slider = (UISlider *)view;
            // Capture volumeView to extend its lifetime
            dispatch_async(dispatch_get_main_queue(), ^{
                (void)volumeView; // Keep volumeView alive
                slider.value = volume;
            });
            break;
        }
    }
}

#pragma mark - Helpers

- (void)postConnectionStateChange
{
    [[NSNotificationCenter defaultCenter] postNotificationName:SmarthomeManagerDidChangeConnectionStateNotification object:self];
}

@end
