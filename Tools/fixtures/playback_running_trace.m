// Read-only runtime observations for the running-playback regression driver.
// No production method is replaced. The optional audio tap passes samples through unchanged.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <stdatomic.h>
#import <CoreData/CoreData.h>
#import "PlaybackManager.h"

@interface NSObject (ICRunningFixtureAPI)
+ (id)sharedDatabaseManager;
- (void)setString:(NSString *)value forKey:(NSString *)key;
@end

static dispatch_queue_t ICTraceQueue;
static NSFileHandle *ICTraceLog;
static NSString *ICTraceDirectory;
static atomic_bool ICTraceStopped;

static UIWindow *ICPlayerWindow(void) {
    UIViewController *controller = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller.view.window;
}

static void ICInspectView(UIView *view, UIView *window, NSMutableArray *rows) {
    NSMutableDictionary *row = [@{@"class":NSStringFromClass(view.class),
        @"frame":NSStringFromCGRect([view convertRect:view.bounds toView:window]),
        @"hidden":@(view.hidden), @"alpha":@(view.alpha),
        @"label":view.accessibilityLabel ?: @"", @"identifier":view.accessibilityIdentifier ?: @""} mutableCopy];
    if ([view isKindOfClass:UIControl.class]) {
        row[@"enabled"] = @([(UIControl *)view isEnabled]);
        NSMutableDictionary *actions = [NSMutableDictionary dictionary];
        for (id target in [(UIControl *)view allTargets]) {
            for (NSNumber *event in @[@(UIControlEventTouchDown),@(UIControlEventTouchUpInside),@(UIControlEventTouchUpOutside),@(UIControlEventTouchCancel)]) {
                NSArray *names = [(UIControl *)view actionsForTarget:target forControlEvent:event.unsignedLongLongValue];
                if (names.count) actions[event.stringValue] = names;
            }
        }
        row[@"actions"] = actions;
    }
    if ([view isKindOfClass:UILabel.class]) row[@"text"] = [(UILabel *)view text] ?: @"";
    [rows addObject:row];
    for (UIView *child in view.subviews) ICInspectView(child,window,rows);
}

static NSNumber *ICTime(CMTime t) {
    double s = CMTimeGetSeconds(t);
    return @(isfinite(s) ? s : -1);
}

static void ICRecord(NSDictionary *row) {
    if (atomic_load(&ICTraceStopped)) return;
    NSMutableDictionary *entry = row.mutableCopy;
    entry[@"wall"] = @(NSProcessInfo.processInfo.systemUptime);
    dispatch_async(ICTraceQueue, ^{
        if (atomic_load(&ICTraceStopped)) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        if (data) {
            [ICTraceLog writeData:data];
            [ICTraceLog writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        }
    });
}

@interface ICOutputCapture : NSObject
@property NSFileHandle *file;
@property AudioStreamBasicDescription format;
@property NSUInteger offset;
@end
@implementation ICOutputCapture @end

static void ICTapInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
    *storage = (void *)CFRetain(info);
}
static void ICTapFinalize(MTAudioProcessingTapRef tap) {
    CFRelease(MTAudioProcessingTapGetStorage(tap));
}
static void ICTapPrepare(MTAudioProcessingTapRef tap, CMItemCount frames, const AudioStreamBasicDescription *format) {
    ICOutputCapture *capture = (__bridge id)MTAudioProcessingTapGetStorage(tap);
    capture.format = *format;
    ICRecord(@{@"event":@"audio-format", @"sampleRate":@(format->mSampleRate),
        @"channels":@(format->mChannelsPerFrame), @"bits":@(format->mBitsPerChannel),
        @"formatID":@(format->mFormatID), @"flags":@(format->mFormatFlags),
        @"bytesPerFrame":@(format->mBytesPerFrame)});
}
static void ICTapUnprepare(MTAudioProcessingTapRef tap) {}
static void ICTapProcess(MTAudioProcessingTapRef tap, CMItemCount requested, MTAudioProcessingTapFlags flags,
                         AudioBufferList *buffers, CMItemCount *frames, MTAudioProcessingTapFlags *outFlags) {
    CMTimeRange range = kCMTimeRangeInvalid;
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, outFlags, &range, frames);
    if (status != noErr) { ICRecord(@{@"event":@"audio-error", @"status":@(status)}); return; }
    if (atomic_load(&ICTraceStopped)) return;
    ICOutputCapture *capture = (__bridge id)MTAudioProcessingTapGetStorage(tap);
    NSMutableData *data = [NSMutableData data];
    NSMutableArray *sizes = [NSMutableArray array];
    for (UInt32 i = 0; i < buffers->mNumberBuffers; i++) {
        AudioBuffer buffer = buffers->mBuffers[i];
        [sizes addObject:@(buffer.mDataByteSize)];
        if (buffer.mData && buffer.mDataByteSize) [data appendBytes:buffer.mData length:buffer.mDataByteSize];
    }
    CMItemCount count = *frames;
    MTAudioProcessingTapFlags returnedFlags = *outFlags;
    CFTimeInterval wall = NSProcessInfo.processInfo.systemUptime;
    dispatch_async(ICTraceQueue, ^{
        if (atomic_load(&ICTraceStopped)) return;
        NSDictionary *entry = @{@"event":@"audio", @"wall":@(wall), @"offset":@(capture.offset),
            @"bytes":@(data.length), @"bufferSizes":sizes, @"frames":@(count), @"flags":@(returnedFlags),
            @"start":ICTime(range.start), @"duration":ICTime(range.duration)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        [capture.file writeData:data]; capture.offset += data.length;
        [ICTraceLog writeData:json]; [ICTraceLog writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    });
}

@interface ICRunningPlaybackTrace : NSObject
@property PlaybackManager *manager;
@property AVPlayer *player;
@property AVPlayerItem *item;
@property BOOL tapped;
@property ICOutputCapture *capture;
@property NSHashTable *controls;
@property CFTimeInterval lastControlScan;
@end

@implementation ICRunningPlaybackTrace
- (void)recordControl:(UIControl *)control event:(UIEvent *)event kind:(NSString *)kind {
    UITouch *touch = event.allTouches.anyObject;
    ICRecord(@{@"event":@"control", @"kind":kind, @"label":control.accessibilityLabel ?: @"",
        @"time":@(self.manager.time), @"point":touch ? NSStringFromCGPoint([touch locationInView:control]) : @"",
        @"bounds":NSStringFromCGRect(control.bounds), @"tracking":@(control.tracking), @"touchInside":@(control.touchInside)});
}
- (void)traceTouchDown:(UIControl *)control event:(UIEvent *)event { [self recordControl:control event:event kind:@"down"]; }
- (void)traceTouchInside:(UIControl *)control event:(UIEvent *)event { [self recordControl:control event:event kind:@"up-inside"]; }
- (void)traceTouchOutside:(UIControl *)control event:(UIEvent *)event { [self recordControl:control event:event kind:@"up-outside"]; }
- (void)traceTouchCancel:(UIControl *)control event:(UIEvent *)event { [self recordControl:control event:event kind:@"cancel"]; }
- (void)watchControls:(UIView *)view {
    if ([view isKindOfClass:UIControl.class] && ![self.controls containsObject:view]) {
        [self.controls addObject:view];
        UIControl *control = (UIControl *)view;
        [control addTarget:self action:@selector(traceTouchDown:event:) forControlEvents:UIControlEventTouchDown];
        [control addTarget:self action:@selector(traceTouchInside:event:) forControlEvents:UIControlEventTouchUpInside];
        [control addTarget:self action:@selector(traceTouchOutside:event:) forControlEvents:UIControlEventTouchUpOutside];
        [control addTarget:self action:@selector(traceTouchCancel:event:) forControlEvents:UIControlEventTouchCancel];
    }
    for (UIView *child in view.subviews) [self watchControls:child];
}
- (void)attachTap {
    if (self.tapped || self.item.status != AVPlayerItemStatusReadyToPlay ||
        ![NSProcessInfo.processInfo.environment[@"IC_RUNNING_CAPTURE_PCM"] boolValue]) return;
    self.tapped = YES;
    AVAssetTrack *track = [self.item.asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return;
    ICOutputCapture *capture = [ICOutputCapture new];
    self.capture = capture;
    NSString *path = [ICTraceDirectory stringByAppendingPathComponent:@"rendered.pcm"];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    capture.file = [NSFileHandle fileHandleForWritingAtPath:path];
    MTAudioProcessingTapCallbacks callbacks = {kMTAudioProcessingTapCallbacksVersion_0, (__bridge void *)capture,
        ICTapInit, ICTapFinalize, ICTapPrepare, ICTapUnprepare, ICTapProcess};
    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
    ICRecord(@{@"event":@"attach-audio-tap", @"status":@(status)});
    if (status != noErr) return;
    AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    parameters.audioTapProcessor = tap;
    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix]; mix.inputParameters = @[parameters];
    self.item.audioMix = mix;
    CFRelease(tap);
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    PlaybackManager *m = self.manager;
    if (object == m && [path isEqual:@"player"]) {
        for (NSString *key in @[@"rate",@"timeControlStatus",@"reasonForWaitingToPlay"]) [self.player removeObserver:self forKeyPath:key];
        [self.item removeObserver:self forKeyPath:@"status"];
        self.player = [m valueForKey:@"player"];
        self.item = self.player.currentItem; self.tapped = NO;
        for (NSString *key in @[@"rate",@"timeControlStatus",@"reasonForWaitingToPlay"]) [self.player addObserver:self forKeyPath:key options:0 context:NULL];
        [self.item addObserver:self forKeyPath:@"status" options:0 context:NULL];
    }
    NSMutableDictionary *row = [@{@"event":@"change", @"key":path, @"object":NSStringFromClass([object class]),
        @"time":@(m.time), @"state":[m valueForKey:@"state"], @"rate":@(self.player.rate),
        @"target":@([[m valueForKey:@"seekingPosition"] doubleValue] * m.duration)} mutableCopy];
    if (![path isEqual:@"timeControlStatus"] && ![path isEqual:@"reasonForWaitingToPlay"]) row[@"stack"] = NSThread.callStackSymbols;
    ICRecord(row);
    [self attachTap];
}
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        ICTraceDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"SilenceTrimProbe"];
        [[NSFileManager defaultManager] createDirectoryAtPath:ICTraceDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [ICTraceDirectory stringByAppendingPathComponent:@"running-trace.jsonl"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        ICTraceLog = [NSFileHandle fileHandleForWritingAtPath:path];
        ICTraceQueue = dispatch_queue_create("ICRunningPlaybackTrace", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        __block ICRunningPlaybackTrace *trace;
        NSTimer *timer = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
            if (![(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSString *stopPath = [ICTraceDirectory stringByAppendingPathComponent:@"trace-stop.json"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:stopPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:stopPath error:nil];
                atomic_store(&ICTraceStopped, YES); [timer invalidate];
                dispatch_async(ICTraceQueue, ^{
                    [trace.capture.file closeFile]; [ICTraceLog closeFile];
                    [@"{}" writeToFile:[ICTraceDirectory stringByAppendingPathComponent:@"trace-stopped.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                });
                return;
            }
            if (!trace) {
                trace = [self new]; trace.manager = [NSClassFromString(@"PlaybackManager") playbackManager];
                trace.controls = NSHashTable.weakObjectsHashTable;
                for (NSString *key in @[@"seekingPositionChangeDate",@"state",@"seeking",@"playingEpisode.position"])
                    [trace.manager addObserver:trace forKeyPath:key options:0 context:NULL];
                [trace.manager addObserver:trace forKeyPath:@"player" options:NSKeyValueObservingOptionInitial context:NULL];
            }
            NSString *setupPath = [ICTraceDirectory stringByAppendingPathComponent:@"fixture-setup.json"];
            NSData *setupData = [NSData dataWithContentsOfFile:setupPath];
            if (setupData) {
                NSDictionary *setup = [NSJSONSerialization JSONObjectWithData:setupData options:0 error:nil];
                NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"objectContext"];
                NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"objectHash == %@",setup[@"episodeHash"]];
                NSManagedObject *episode = [[context executeFetchRequest:request error:nil] firstObject];
                id feed = [episode valueForKey:@"feed"];
                for (NSString *key in setup[@"feedProperties"]) {
                    NSString *resolved = [key stringByReplacingOccurrencesOfString:@"__UID__" withString:[feed valueForKey:@"uid"]];
                    [feed setString:setup[@"feedProperties"][key] forKey:resolved];
                }
                NSError *error; BOOL saved = [context save:&error];
                NSDictionary *reply = @{@"saved":@(saved), @"error":error.description ?: @""};
                [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil] writeToFile:[ICTraceDirectory stringByAppendingPathComponent:@"fixture-ready.json"] atomically:YES];
                [[NSFileManager defaultManager] removeItemAtPath:setupPath error:nil];
            }
            NSString *inspectPath = [ICTraceDirectory stringByAppendingPathComponent:@"inspect.json"];
            NSData *inspectData = [NSData dataWithContentsOfFile:inspectPath];
            if (inspectData) {
                NSDictionary *request = [NSJSONSerialization JSONObjectWithData:inspectData options:0 error:nil];
                NSMutableArray *rows = [NSMutableArray array];
                UIWindow *window = ICPlayerWindow();
                ICInspectView(window,window,rows);
                [[NSJSONSerialization dataWithJSONObject:rows options:0 error:nil] writeToFile:[ICTraceDirectory stringByAppendingPathComponent:[request[@"file"] lastPathComponent]] atomically:YES];
                [[NSFileManager defaultManager] removeItemAtPath:inspectPath error:nil];
            }
            PlaybackManager *m = trace.manager;
            if (!trace.player) return;
            if (NSProcessInfo.processInfo.systemUptime - trace.lastControlScan > 1) {
                trace.lastControlScan = NSProcessInfo.processInfo.systemUptime;
                [trace watchControls:ICPlayerWindow()];
            }
            ICRecord(@{@"event":@"sample", @"time":@(m.time), @"raw":ICTime(trace.player.currentTime),
                @"rate":@(trace.player.rate), @"state":[m valueForKey:@"state"],
                @"timeControlStatus":@(trace.player.timeControlStatus), @"applicationState":@(UIApplication.sharedApplication.applicationState),
                @"waitingReason":trace.player.reasonForWaitingToPlay ?: @""});
        }];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemTimeJumpedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            ICRecord(@{@"event":@"time-jumped", @"time":ICTime([(AVPlayerItem*)note.object currentTime])});
        }];
        for (NSString *name in @[UIApplicationWillResignActiveNotification,UIApplicationDidEnterBackgroundNotification,UIApplicationDidBecomeActiveNotification,AVAudioSessionInterruptionNotification,AVAudioSessionRouteChangeNotification]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                ICRecord(@{@"event":@"notification", @"name":name, @"info":note.userInfo.description ?: @""});
            }];
        }
    });
}
@end
