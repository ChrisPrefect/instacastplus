//
//  Application.m
//  Instacast
//
//  Created by Martin Hering on 03.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#include <asl.h>
#include <sys/sysctl.h>
#include <sqlite3.h>
#include <unistd.h>

#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "VDModalInfo.h"
#import "Reachability.h"
#import "ICErrorSheet.h"
#import <MediaPlayer/MPVolumeView.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CDModel.h"
#import "CDPlaylist.h"
#import "CDPlaylistEpisode.h"
#import "CDSmartPlaylist.h"
#import "CDEpisodeList.h"
#import "DatabaseManager.h"
#import "SubscriptionManager.h"
#import "ICFeed.h"
#import "UtilityFunctions.h"
#import "InstacastPlus-Swift.h"


NSString* UniqueDeviceId = @"UniqueDeviceId";
NSString* ApplicationDidRegisterTouchNotification = @"ApplicationDidRegisterTouchNotification";

@interface Application ()
@property (nonatomic, readwrite, strong) UIAlertController* errorAlertController;
@property (nonatomic, readwrite, strong) NSOperationQueue* mainQueue;
@property (nonatomic, readwrite, strong) CTTelephonyNetworkInfo* telephonyInfo;
@property (nonatomic, strong) Reachability* reachability;
@property (nonatomic, strong) ICErrorSheet* backgroundErrorSheet;
@property (nonatomic, readwrite, strong) GTMLogger* applicationLogger;
@property (nonatomic, strong) CMMotionManager *motionManager;
@end

@implementation Application {
@protected
	NSInteger	_networkActivityRetainCount;
	BOOL		_errorShown;
    BOOL        _sendTouchNotifications;
    double     lastAccelX;
    double     lastAccelY;
    double     lastAccelZ;
    NSTimeInterval lastAccelTimestamp;
    CMAcceleration previousAcceleration;
    NSTimeInterval previousAccelerationTimestamp;
    NSUInteger motionSampleCount;
    dispatch_queue_t _motionQueue;
    BOOL _motionDetectionRunning;
    BOOL _motionReferenceValid;
    NSUInteger _motionDetectionClientCount;
    BOOL _sleepTimerCountdownRunning;
    UIInterfaceOrientation orientationLast;
}

- (id) init
{
	if ((self = [super init]))
	{
		_mainQueue = [[NSOperationQueue alloc] init];

        // Skip iOS-only hardware access on macOS ("Designed for iPad") to avoid TCC dialogs.
        BOOL isiOSAppOnMac = NO;
        isiOSAppOnMac = NSProcessInfo.processInfo.isiOSAppOnMac;

        _reachability = [Reachability reachabilityForInternetConnection];
        [_reachability startNotifier];

#if !TARGET_OS_SIMULATOR
        if (!isiOSAppOnMac) {
            _telephonyInfo = [CTTelephonyNetworkInfo new];
        }
#endif

        [self updateNetworkAccessTechnology];

#if !TARGET_OS_SIMULATOR
        if (!isiOSAppOnMac) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:CTServiceRadioAccessTechnologyDidChangeNotification object:nil];
        }
#endif

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:kReachabilityChangedNotification object:nil];

        // CMMotionManager (accelerometer) is not available on macOS — skip.
        // Init on background thread — CMMotionManager reads CoreMotion.plist synchronously
        // which blocks for seconds on device due to sandbox permission errors.
        if (!isiOSAppOnMac) {
            // The accelerometer only runs while something consumes it (see -updateMotionDetection).
            _motionQueue = dispatch_queue_create("com.iteconomy.instacast.motion", DISPATCH_QUEUE_SERIAL);
            NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
            [center addObserver:self selector:@selector(_sleepTimerStateDidChange:) name:AudioSessionSleepTimerDidChangeNotification object:nil];
            [center addObserver:self selector:@selector(_sleepTimerStateDidChange:) name:AudioSessionSleepTimerDidExpireNotification object:nil];
            [center addObserver:self selector:@selector(updateMotionDetection) name:NSUserDefaultsDidChangeNotification object:nil];
            [center addObserver:self selector:@selector(updateMotionDetection) name:UIApplicationDidBecomeActiveNotification object:nil];
        }
        [self volumeChangeNotification];
	}
	return self;
}


- (GTMLogger*) _initializeLoggerAtPath:(NSString*)path
{
    
#ifdef DEBUG
    
    @try {
        GTMLogBasicFormatter *formatter = [[GTMLogBasicFormatter alloc] init];
        
        GTMLogger *stdoutLogger =
        [GTMLogger loggerWithWriter:[NSFileHandle fileHandleWithStandardOutput]
                     formatter:formatter
                        filter:[[GTMLogMaximumLevelFilter alloc] initWithMaximumLevel:kGTMLoggerLevelInfo]];
        
        GTMLogger *stderrLogger =
        [GTMLogger loggerWithWriter:[NSFileHandle fileHandleWithStandardError]
                     formatter:formatter
                        filter:[[GTMLogMininumLevelFilter alloc] initWithMinimumLevel:kGTMLoggerLevelError]];
        
        
        GTMLogger* fileLogger = [GTMLogger standardLoggerWithPath:path];
        [fileLogger setFilter:[[GTMLogNoFilter alloc] init]];
        
        NSURL* url = [NSURL fileURLWithPath:path];
        NSError *error = nil;
        [url setResourceValue:@(YES) forKey: NSURLIsExcludedFromBackupKey error:&error];
        
        GTMLogger *compositeWriter =
        [GTMLogger loggerWithWriter:@[stdoutLogger, stderrLogger, fileLogger]
                          formatter:formatter
                             filter:[[GTMLogNoFilter alloc] init]];
        
        GTMLogger *outerLogger = [GTMLogger standardLogger];
        [outerLogger setWriter:compositeWriter];
        return outerLogger;
    }
    @catch (id e) {
        // Ignored
    }
    
    
    GTMLogger* logger = [GTMLogger standardLoggerWithStdoutAndStderr];
    return logger;
#else
    GTMLogger* logger = [GTMLogger standardLoggerWithPath:path];
    [logger setFilter:[[GTMLogLevelFilter alloc] init]];
    
    NSURL* url = [NSURL fileURLWithPath:path];
    
    NSError *error = nil;
    [url setResourceValue:@(YES) forKey: NSURLIsExcludedFromBackupKey error:&error];
    
    return logger;
#endif
}

- (void) initializeLoggers
{
    NSString* appLogsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"Application.Log"];
    _applicationLogger = [self _initializeLoggerAtPath:appLogsPath];
}

#pragma mark - Network Info

- (void) _networkAccessTechnologyDidChange:(NSNotification*)note
{
    [self updateNetworkAccessTechnology];
}

- (void) updateNetworkAccessTechnology
{
    if (self.reachability.currentReachabilityStatus == ReachableViaWiFi) {
        self.networkAccessTechnology = kICNetworkAccessTechnlogyWIFI;
    }
    else if (self.reachability.currentReachabilityStatus == NotReachable) {
        self.networkAccessTechnology = kICNetworkAccessTechnlogyNone;
    }
    else
    {
        // Use serviceCurrentRadioAccessTechnology (returns dictionary of service identifier -> technology)
        NSDictionary<NSString*, NSString*> *radioAccessTechnologies = self.telephonyInfo.serviceCurrentRadioAccessTechnology;
        NSString* currentRadioAccessTechnology = radioAccessTechnologies.allValues.firstObject;
        if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyGPRS]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyGPRS;
        }
        else if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyEdge]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyEDGE;
        }
        else if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyLTE]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyLTE;
        }
        else {
            self.networkAccessTechnology = kICNetworkAccessTechnlogy3G;
        }
    }
    
    
}

- (void) retainNetworkActivity
{
	dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_networkActivityRetainCount == 0) {
            // networkActivityIndicatorVisible is deprecated in iOS 13 with no replacement
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.networkActivityIndicatorVisible = YES;
#pragma clang diagnostic pop
        }
        self->_networkActivityRetainCount++;
    });
}

- (void) releaseNetworkActivity
{
	dispatch_async(dispatch_get_main_queue(), ^{
        self->_networkActivityRetainCount = MAX(self->_networkActivityRetainCount-1,0);

        if (self->_networkActivityRetainCount == 0) {
            // networkActivityIndicatorVisible is deprecated in iOS 13 with no replacement
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.networkActivityIndicatorVisible = NO;
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Global Error Handling

- (void) handleNoInternetConnection
{
    [self showBackgroundErrorWithTitle:@"No internet connection.".ls message:@"Please make sure you are connected to a cellular or WiFi network.".ls];
}

- (void) showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message
{
    [self showBackgroundErrorWithTitle:title message:message duration:4.0f];
}

- (void) showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message duration:(NSTimeInterval)duration
{
    PlaySoundFile(@"Tink", NO);
    
    if (self.backgroundErrorSheet) {
        self.backgroundErrorSheet.title = title;
        self.backgroundErrorSheet.message = message;
        [self.backgroundErrorSheet extendDismissingAfterDelay:duration];
        return;
    }
    
    self.backgroundErrorSheet = [ICErrorSheet sheet];
    self.backgroundErrorSheet.title = title;
    self.backgroundErrorSheet.message = message;
    
    __weak Application* weakSelf = self;
    [self.backgroundErrorSheet showAnimated:YES dismissAfterDelay:duration completion:^{
        weakSelf.backgroundErrorSheet = nil;
    }];
}


#pragma mark -


- (NSString*) errorLog
{
    NSString* logsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"Application.Log"];
    return [[NSString alloc] initWithContentsOfFile:logsPath encoding:NSUTF8StringEncoding error:nil];
}

-(void)sendEvent:(UIEvent *)event
{
    // Field report 17.11.2026: a tap showed no reaction for several seconds. Lifting a finger
    // is timed twice: how long the touch waited for the main thread before it arrived here,
    // and how long the app then took to handle it. Only slow touches are written.
    UITouch* endedTouch = nil;
    if (event.type == UIEventTypeTouches) {
        for (UITouch* touch in event.allTouches) {
            if (touch.phase == UITouchPhaseEnded) {
                endedTouch = touch;
                break;
            }
        }
    }
    CFTimeInterval eventHandlingStart = CACurrentMediaTime();
    [super sendEvent:event];
    if (endedTouch) {
        CFTimeInterval waitedMs = (eventHandlingStart - endedTouch.timestamp) * 1000.0;
        CFTimeInterval handledMs = (CACurrentMediaTime() - eventHandlingStart) * 1000.0;
        if (waitedMs > 250.0 || handledMs > 250.0) {
            [[ICDiagnosticLogger shared] logEvent:@"input-latency"
                                          message:@"Langsame Touch-Verarbeitung"
                                         metadata:@{
                @"waitedForMainThreadMs": [NSString stringWithFormat:@"%.1f", waitedMs],
                @"handlingMs": [NSString stringWithFormat:@"%.1f", handledMs],
                @"view": endedTouch.view ? NSStringFromClass(endedTouch.view.class) : @"",
            }];
        }
    }

    if (!myidleTimer)
    {
        [self resetIdleTimer];
    }
    
    NSSet *allTouches = [event allTouches];
    if ([allTouches count] > 0)
    {
        UITouchPhase phase = ((UITouch *)[allTouches anyObject]).phase;
        if (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved)
        {
            [self resetIdleTimer];
        }
        
    }
}
//as labeled...reset the timer
-(void)resetIdleTimer
{
    if ([USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive] &&
        [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep]) {
        [self _resetSleepTimerForActivity:@"touch"];
    }
}

- (void)_resetSleepTimerForActivity:(NSString*)reason
{
    [self _resetSleepTimerForActivity:reason metadata:@{}];
}

- (void)_resetSleepTimerForActivity:(NSString*)reason metadata:(NSDictionary*)metadata
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _resetSleepTimerForActivity:reason metadata:metadata];
        });
        return;
    }
    AudioSession* session = [AudioSession sharedAudioSession];
    [session resetSleepTimerForActivity:reason metadata:metadata];
    [myidleTimer invalidate];
    myidleTimer = nil;
    if (session.stopDate) {
        myidleTimer = [NSTimer scheduledTimerWithTimeInterval:session.timerRemainingTime target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
    }
}

-(void)idleTimerExceeded
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kApplicationDidTimeoutNotification object:nil];
}

// Consumers of the accelerometer: the motion-extended sleep timer while its countdown runs,
// the smart home motion topic, and the live indicator in the sleep timer settings.
- (BOOL)_motionDetectionNeeded
{
    if (_motionDetectionClientCount > 0) return YES;
    if ([USER_DEFAULTS boolForKey:SmarthomeMQTTEnabled]) return YES;
    return [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive] &&
           [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep] &&
           _sleepTimerCountdownRunning;
}

// Both notifications are posted by the audio session on the main thread, after it
// changed its countdown; reading the sender avoids creating the session early.
- (void)_sleepTimerStateDidChange:(NSNotification*)notification
{
    AudioSession* session = [notification.object isKindOfClass:[AudioSession class]] ? notification.object : nil;
    _sleepTimerCountdownRunning = (session.stopDate != nil);
    [self updateMotionDetection];
}

- (void)updateMotionDetection
{
    if (!_motionQueue) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateMotionDetection];
        });
        return;
    }
    BOOL needed = [self _motionDetectionNeeded];
    if (needed == _motionDetectionRunning) return;
    _motionDetectionRunning = needed;
    // A fresh start has no baseline: the first sample only sets the reference.
    _motionReferenceValid = NO;
    // CMMotionManager reads CoreMotion.plist synchronously, which blocks for seconds
    // on device: create, start and stop it off the main thread, in order.
    dispatch_async(_motionQueue, ^{
        if (needed) {
            [self deviceMotionDetection];
        } else {
            [self.motionManager stopAccelerometerUpdates];
        }
    });
}

- (void)beginMotionDetectionClient
{
    _motionDetectionClientCount++;
    [self updateMotionDetection];
}

- (void)endMotionDetectionClient
{
    if (_motionDetectionClientCount > 0) _motionDetectionClientCount--;
    [self updateMotionDetection];
}

-(void)deviceMotionDetection
{
    if (!self.motionManager) {
        self.motionManager = [[CMMotionManager alloc] init];
        self.motionManager.accelerometerUpdateInterval = 0.3;
    }

    if ([self.motionManager isAccelerometerAvailable])
    {
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        [self.motionManager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self->_motionDetectionRunning) return;
                CMAcceleration acc = accelerometerData.acceleration;
                if (!self->_motionReferenceValid && accelerometerData) {
                    // The first sample after a start is the device at rest, not a movement:
                    // compared with the zero (or an old) reference it would always count as
                    // motion and reset the timer and the smart home state on every start.
                    self->motionSampleCount++;
                    self->_motionReferenceValid = YES;
                    self->lastAccelX = acc.x;
                    self->lastAccelY = acc.y;
                    self->lastAccelZ = acc.z;
                    self->lastAccelTimestamp = accelerometerData.timestamp;
                    self->previousAcceleration = acc;
                    self->previousAccelerationTimestamp = accelerometerData.timestamp;
                    return;
                }
                CMAcceleration reference = { self->lastAccelX, self->lastAccelY, self->lastAccelZ };
                NSTimeInterval referenceTimestamp = self->lastAccelTimestamp;
                self->motionSampleCount++;
                double threshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
                if (threshold <= 0) threshold = 0.004;
                if (fabs(acc.x - self->lastAccelX) > threshold ||
                    fabs(acc.y - self->lastAccelY) > threshold ||
                    fabs(acc.z - self->lastAccelZ) > threshold)
                {
                    self->lastAccelX = acc.x;
                    self->lastAccelY = acc.y;
                    self->lastAccelZ = acc.z;
                    self->lastAccelTimestamp = accelerometerData.timestamp;
                    [[NSNotificationCenter defaultCenter] postNotificationName:ApplicationDidDetectMotionNotification object:nil];
                    BOOL isMotionActive = [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep];
                    BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];

                    if (isIntelligentTimerActive && isMotionActive) {
                        // Preserve the detector's input before the baseline/deadline is lost.
                        // The AudioSession logger still counts every reset and samples logs at 30 s.
                        [self _resetSleepTimerForActivity:@"motion" metadata:@{
                            @"motion.x": @(acc.x), @"motion.y": @(acc.y), @"motion.z": @(acc.z),
                            @"motion.referenceX": @(reference.x), @"motion.referenceY": @(reference.y), @"motion.referenceZ": @(reference.z),
                            @"motion.deltaX": @(acc.x - reference.x), @"motion.deltaY": @(acc.y - reference.y), @"motion.deltaZ": @(acc.z - reference.z),
                            @"motion.previousDeltaX": @(acc.x - self->previousAcceleration.x),
                            @"motion.previousDeltaY": @(acc.y - self->previousAcceleration.y),
                            @"motion.previousDeltaZ": @(acc.z - self->previousAcceleration.z),
                            @"motion.threshold": @(threshold),
                            @"motion.sampleNumber": @(self->motionSampleCount),
                            @"motion.samplePresent": @(accelerometerData != nil),
                            @"motion.sampleUptime": @(accelerometerData.timestamp),
                            @"motion.referenceSampleUptime": @(referenceTimestamp),
                            @"motion.previousSampleUptime": @(self->previousAccelerationTimestamp),
                            @"motion.sampleIntervalSeconds": @(accelerometerData.timestamp - self->previousAccelerationTimestamp),
                            @"motion.deliveryLagSeconds": @(NSProcessInfo.processInfo.systemUptime - accelerometerData.timestamp),
                            @"motion.errorDomain": error.domain ?: @"",
                            @"motion.errorCode": @(error.code),
                        }];
                    }
                }
                self->previousAcceleration = acc;
                self->previousAccelerationTimestamp = accelerometerData.timestamp;
            });
        }];
    }
}


-(void)volumeChangeNotification
{
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    //[audioSession setActive:YES error:nil];
    [audioSession addObserver:self forKeyPath:@"outputVolume" options:0 context:nil];
    //[[AudioSession sharedAudioSession] addObserver:self forKeyPath:@"outputVolume" options:0 context:nil];
}

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqual:@"outputVolume"] &&
        [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive] &&
        [USER_DEFAULTS boolForKey:VolumeChangeIntelligentSleep]) {
        [self _resetSleepTimerForActivity:@"volume"];
    }
}

#pragma mark - Scene-aware Key Window

- (UIWindow *)ic_keyWindow
{
    // Only UIWindowScene instances have UIWindow collections. CarPlay template scenes do not.
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene* windowScene = (UIWindowScene*)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    // Fallback: return first window from any foreground UIWindowScene.
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene* windowScene = (UIWindowScene*)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive ||
            windowScene.activationState == UISceneActivationStateForegroundInactive) {
            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }
    return nil;
}

@end
