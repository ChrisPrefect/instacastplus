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
    UIInterfaceOrientation orientationLast;
}

- (id) init
{
	if ((self = [super init]))
	{
		_mainQueue = [[NSOperationQueue alloc] init];

        _reachability = [Reachability reachabilityForInternetConnection];
        [_reachability startNotifier];

#if !TARGET_OS_SIMULATOR
        _telephonyInfo = [CTTelephonyNetworkInfo new];
#endif

        [self updateNetworkAccessTechnology];

#if !TARGET_OS_SIMULATOR
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:CTServiceRadioAccessTechnologyDidChangeNotification object:nil];
#endif

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:kReachabilityChangedNotification object:nil];
        [self deviceMotionDetection];
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
        if (_networkActivityRetainCount == 0) {
            // networkActivityIndicatorVisible is deprecated in iOS 13 with no replacement
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.networkActivityIndicatorVisible = YES;
#pragma clang diagnostic pop
        }
        _networkActivityRetainCount++;
    });
}

- (void) releaseNetworkActivity
{
	dispatch_async(dispatch_get_main_queue(), ^{
        _networkActivityRetainCount = MAX(_networkActivityRetainCount-1,0);

        if (_networkActivityRetainCount == 0) {
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
    [super sendEvent:event];
    
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
    BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
    BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
    if (isIntelligentTimerActive){
        if (isTouchActive){
            if (myidleTimer)
            {
                [myidleTimer invalidate];
            }
            //convert the wait period into minutes rather than seconds
            NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            if ([PlaybackManager playbackManager].isPodcastPlaying)
            {
                if (sleepTimer > 0)
                {
                    [AudioSession sharedAudioSession].timerValue = sleepTimer;
                    int timeout = (int)sleepTimer * 60;
                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                }
                else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                {
                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                    int timeout = (int)lastSleepTimer * 60;
                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                }
            }
        }
    }
}

-(void)idleTimerExceeded
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kApplicationDidTimeoutNotification object:nil];
}

-(void)deviceMotionDetection
{
    self.motionManager = [[CMMotionManager alloc] init];
    self.motionManager.accelerometerUpdateInterval = 0.3;

    if ([self.motionManager isAccelerometerAvailable])
    {
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        [self.motionManager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CMAcceleration acc = accelerometerData.acceleration;
                double threshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
                if (threshold <= 0) threshold = 0.004;
                if (fabs(acc.x - self->lastAccelX) > threshold ||
                    fabs(acc.y - self->lastAccelY) > threshold ||
                    fabs(acc.z - self->lastAccelZ) > threshold)
                {
                    self->lastAccelX = acc.x;
                    self->lastAccelY = acc.y;
                    self->lastAccelZ = acc.z;
                    [[NSNotificationCenter defaultCenter] postNotificationName:ApplicationDidDetectMotionNotification object:nil];
                    BOOL isMotionActive = [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep];
                    BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];

                    if (isIntelligentTimerActive){
                        if (isMotionActive){
                            if ([PlaybackManager playbackManager].isPodcastPlaying)
                            {
                                if (myidleTimer)
                                {
                                    [myidleTimer invalidate];
                                }
                                NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                                [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
                                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                                
                                if (sleepTimer > 0)
                                {
                                    [AudioSession sharedAudioSession].timerValue = sleepTimer;
                                    int timeout = (int)sleepTimer * 60;
                                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                                }
                                else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                                {
                                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                                    int timeout = (int)lastSleepTimer * 60;
                                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                                }
                            }
                        }
                    }
                }
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
    
    if ([keyPath isEqual:@"outputVolume"]) {
        BOOL isVolumeActive = [USER_DEFAULTS boolForKey:VolumeChangeIntelligentSleep];
        BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
        if (isIntelligentTimerActive){
            if (isVolumeActive){
                if ([PlaybackManager playbackManager].isPodcastPlaying)
                {
                    if (myidleTimer)
                    {
                        [myidleTimer invalidate];
                    }
                    //convert the wait period into minutes rather than seconds
                    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                    [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
                    NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                    if (sleepTimer > 0)
                    {
                        [AudioSession sharedAudioSession].timerValue = sleepTimer;
                        int timeout = (int)sleepTimer * 60;
                        myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                    }
                    else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                    {
                        [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                        int timeout = (int)lastSleepTimer * 60;
                        myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                    }
                }
            }
        }
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
