//
//  PlayerTimerButton.m
//  Instacast
//
//  Created by Martin Hering on 10.01.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "PlayerTimerButton.h"
#import "VDModalInfo.h"
#import "InstacastAppDelegate.h"
#import "MainViewController_4.h"
//#import "DropDownMenu.h"

@interface PlayerTimerButton ()
@property (nonatomic, strong) UIImageView* clockStepsImageView;
@property (nonatomic, assign) PlaybackStopTimeValue timerValue;
@property (nonatomic, strong) VDModalInfo* modalInfo;
@end

@implementation PlayerTimerButton {
    BOOL        _observing;
    NSDate*     _trackingDate;
    NSTimer*    _longTrackingTimer;
    UIAlertAction *noValueBtn;
    UIAlertAction *value3Btn;
    UIAlertAction *value5Btn;
    UIAlertAction *value10Btn;
    UIAlertAction *value20Btn;
    UIAlertAction *value30Btn;
    UIAlertAction *value60Btn;
    //DropDownMenu *dropDown;
    //BOOL isDropDownViewAdded;
    //BOOL isDropDownViewShowing;
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    if (newWindow && !self.clockStepsImageView)
    {
        //[self update];
        [self IntelligentSleepTimerUpdate];
        
        [[AudioSession sharedAudioSession] addTaskObserver:self forKeyPath:@"timerRemainingTime" task:^(id obj, NSDictionary *change) {
            [self IntelligentSleepTimerUpdate];
        }];
        _observing = YES;
    }
    else if (!newWindow && self.clockStepsImageView)
    {
        if (_observing) {
            [[AudioSession sharedAudioSession] removeTaskObserver:self forKeyPath:@"timerRemainingTime"];
            _observing = NO;
        }
    }
}

/*
- (void) update
{
    AudioSession* session = [AudioSession sharedAudioSession];
    
    if (session.timerValue == PlaybackStopTimeNoValue) {
        [self setImage:[[UIImage imageNamed:@"Player Timer Outline"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
              forState:UIControlStateNormal];
        [self setTitle:nil forState:UIControlStateNormal];
    }
    else
    {
        NSTimeInterval tRem = session.timerRemainingTime;
        
        [self setImage:[[UIImage imageNamed:@"Player Timer Fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
              forState:UIControlStateNormal];
        
        [self setTitle:[NSString stringWithFormat:@"%ld", (long)(tRem/60)+1] forState:UIControlStateNormal];
    }
    
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self setTitleColor:ICBackgroundColor forState:UIControlStateNormal];
}*/

- (void)IntelligentSleepTimerUpdate
{
    AudioSession* session = [AudioSession sharedAudioSession];
    NSString* announcement = nil;
    //NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    if (session.timerValue == PlaybackStopTimeNoValue)
    {
        [self setImage:[[UIImage imageNamed:@"timer_watch_devd"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
              forState:UIControlStateNormal];
        [self setTitle:nil forState:UIControlStateNormal];
        //session.timerValue = PlaybackStopTimeNoValue;
        announcement = @"Sleep Timer disabled.".ls;
    }
    else
    {
        /*if (sleepTimer == PlaybackStopTime5min)
         {
         session.timerValue = PlaybackStopTime5min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 5];
         }
         else if (sleepTimer == PlaybackStopTime10min)
         {
         session.timerValue = PlaybackStopTime10min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 10];
         }
         else if (sleepTimer == PlaybackStopTime15min)
         {
         session.timerValue = PlaybackStopTime15min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 15];
         }
         else if (sleepTimer == PlaybackStopTime20min)
         {
         session.timerValue = PlaybackStopTime20min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 20];
         }
         else if (sleepTimer == PlaybackStopTime30min)
         {
         session.timerValue = PlaybackStopTime30min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 30];
         }
         else if (sleepTimer == PlaybackStopTime60min)
         {
         session.timerValue = PlaybackStopTime60min;
         announcement = [NSString stringWithFormat:@"Sleep Timer set to %d minutes.".ls, 60];
         }*/
        //Player Timer Fill Square, Player Time Square
        
        [self setImage:[[UIImage imageNamed:@"Player Speed Fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [self setTitleColor:ICBackgroundColor forState:UIControlStateNormal];
        //[self setTitle:[NSString stringWithFormat:@"%ld", sleepTimer] forState:UIControlStateNormal];
        
        NSTimeInterval tRem = session.timerRemainingTime + 1;
        //NSLog(@"Player time remaining==%f",tRem);
        NSInteger minutes = floor(tRem/60);
        NSInteger seconds = trunc(tRem - minutes * 60);
        NSString*remainingTime = [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
        //NSLog(@"Player time remaining==%@",remainingTime);
        [self setTitle:[NSString stringWithFormat:@"%@", remainingTime] forState:UIControlStateNormal];
        //[self setTitle:[NSString stringWithFormat:@"%ld", (long)(tRem/60)+1] forState:UIControlStateNormal];
    }
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _trackingDate = [NSDate date];
    
    _longTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_longTrackingTimer:) userInfo:nil repeats:NO];
    
    return [super beginTrackingWithTouch:touch withEvent:event];
}

- (void) _longTrackingTimer:(NSTimer*)timer
{
//    if (isDropDownViewShowing)
//    {
//        [dropDown.view setHidden:true];
//        isDropDownViewShowing = false;
//    }
//    
//    if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
//    {
    //timer_watch_devd, Player Timer Watch
        [self setImage:[[UIImage imageNamed:@"timer_watch_devd"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
              forState:UIControlStateNormal];
        [self setTitle:nil forState:UIControlStateNormal];
        
        [AudioSession sharedAudioSession].timerValue = PlaybackStopTimeNoValue;
        [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
        [USER_DEFAULTS setInteger:PlaybackStopTimeNoValue forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS setBool:NO forKey:ScreenTimerAlwaysActive];
        [USER_DEFAULTS synchronize];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Sleep Timer disabled.".ls);

        VDModalInfo* modalInfo = [VDModalInfo modalInfo];
        modalInfo.closableByTap = NO;
        modalInfo.animation = VDModalInfoAnimationMoveDown;
        modalInfo.alignment = VDModalInfoAlignmentPhonePlayer;
        modalInfo.size = CGSizeMake(280, 44);
        
        modalInfo.textLabel.text = @"Sleep Timer disabled.".ls;
        [modalInfo show];
        
        [self perform:^(id sender) {
            [modalInfo close];
        } afterDelay:1];
    //}
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    [super endTrackingWithTouch:touch withEvent:event];
    
    CGRect b = CGRectInset(self.bounds, -10, -10);
    if (CGRectContainsPoint(b,  [touch locationInView:self]))
    {
        if ([_trackingDate timeIntervalSinceNow] >= -0.5)
        {
            /*if (isDropDownViewShowing)
            {
                [dropDown.view setHidden:true];
                isDropDownViewShowing = false;
            }
            else
            {
                [self showTimerDropDown];
                isDropDownViewShowing = true;
            }*/
            [self showIntelligentSleepTimerAlert];
        }
    }
    
    [_longTrackingTimer invalidate];
    _longTrackingTimer = nil;
    
    _trackingDate = nil;
}

- (void)showTimerDropDown
{
    /*
    if (isDropDownViewAdded)
    {
        [dropDown realodDropDownView];
        [dropDown.view setHidden:false];
    }
    else
    {
        isDropDownViewAdded = true;
        UIViewController* rootViewController = [self getRootViewControllerDev];
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Main" bundle:nil];
        dropDown = (DropDownMenu *)[storyboard instantiateViewControllerWithIdentifier:@"DropDownMenu"];
        
        [dropDown willMoveToParentViewController:rootViewController];
        CGFloat width = [UIScreen mainScreen].bounds.size.width;
        CGFloat height = [UIScreen mainScreen].bounds.size.height;
        CGRect newFrame= CGRectMake(width/3.5, height - 350, width/1.4, 280);
        [dropDown.view setFrame:newFrame];
        [rootViewController.view addSubview:dropDown.view];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"selectedListItem" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changeValue:) name:@"selectedListItem" object:nil];
    }*/
    [self showIntelligentSleepTimerAlert];
}

- (void) setAlwaysSleepTimer:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:ScreenTimerAlwaysActive];
    [USER_DEFAULTS synchronize];
    [self setAlwaysSleepTimerUpdate:sender.on];
    [self updateTimerAlertButtonsCheckmarks];
}

-(void)setAlwaysSleepTimerUpdate:(BOOL)isOn
{
    if (isOn)
    {
        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        if (sleepTimer == PlaybackStopTimeNoValue)
        {
            NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            if (lastSleepTimer > 0)
            {
                [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
            }
            else
            {
                [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
                [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:LastSelectedSleepTimer];
                [USER_DEFAULTS synchronize];
            }
        }
        [self IntelligentSleepTimerUpdate];
    }
    else
    {
        // Restore timer to explicitly selected value only
        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        [AudioSession sharedAudioSession].timerValue = sleepTimer;
        [self IntelligentSleepTimerUpdate];
    }
}

- (void) setIntelligentTimer:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:IntelligentSleepTimerAlwaysActive];
    [USER_DEFAULTS synchronize];
}

- (void)showIntelligentSleepTimerAlert
{
    UILabel *intelligentLbl = [[UILabel alloc] init];
    intelligentLbl.text = @"Smart Sleep Timer".ls;
    intelligentLbl.textColor = UIColor.labelColor;
    intelligentLbl.tag = 0;
    [intelligentLbl sizeToFit];
    
    UISwitch *intelligentSwitch = [[UISwitch alloc] init];
    intelligentSwitch.on = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
    
    [intelligentSwitch addTarget:self action:@selector(setIntelligentTimer:) forControlEvents:UIControlEventValueChanged];
    [intelligentSwitch.layer setValue:intelligentLbl forKey:@"label"];
    
    UIStackView *intelligentStack = [[UIStackView alloc] init];
    intelligentStack.axis = UILayoutConstraintAxisHorizontal;
    intelligentStack.alignment = UIStackViewAlignmentCenter;
    intelligentStack.spacing = 10;
    
    [intelligentStack addArrangedSubview:intelligentLbl];
    [intelligentStack addArrangedSubview:intelligentSwitch];
    
    UILabel *screenAlwaysLbl = [[UILabel alloc] init];
    screenAlwaysLbl.text = @"Sleep Timer Always Active".ls;
    screenAlwaysLbl.textColor = UIColor.labelColor;
    screenAlwaysLbl.tag = 0;
    [screenAlwaysLbl sizeToFit];
    
    UISwitch *screenAlwaysSwitch = [[UISwitch alloc] init];
    screenAlwaysSwitch.on = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
    
    [screenAlwaysSwitch addTarget:self action:@selector(setAlwaysSleepTimer:) forControlEvents:UIControlEventValueChanged];
    [screenAlwaysSwitch.layer setValue:screenAlwaysLbl forKey:@"label"];
    
    UIStackView *screenAlwaysStack = [[UIStackView alloc] init];
    screenAlwaysStack.axis = UILayoutConstraintAxisHorizontal;
    screenAlwaysStack.alignment = UIStackViewAlignmentCenter;
    screenAlwaysStack.spacing = 10;
    
    [screenAlwaysStack addArrangedSubview:screenAlwaysLbl];
    [screenAlwaysStack addArrangedSubview:screenAlwaysSwitch];
    
    UIStackView *mainStack = [[UIStackView alloc] init];
    mainStack.axis = UILayoutConstraintAxisVertical;
    mainStack.alignment = UIStackViewAlignmentCenter;
    mainStack.spacing = 2;

    [mainStack addArrangedSubview:intelligentStack];
    [mainStack addArrangedSubview:screenAlwaysStack];
    [mainStack setCustomSpacing:10 afterView:intelligentStack];
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    noValueBtn = [UIAlertAction actionWithTitle:@"Off".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            //            if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
            //            {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTimeNoValue forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setBool:NO forKey:ScreenTimerAlwaysActive];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTimeNoValue;
            [self IntelligentSleepTimerUpdate];
//            if ([USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
//            {
//                [self setAlwaysSleepTimerUpdate:YES];
//            }
            // }
        } afterDelay:0.1];
    }];
    [alert addAction:noValueBtn];
    
    value3Btn = [UIAlertAction actionWithTitle:@"3 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime3min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime3min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime3min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];

    value5Btn = [UIAlertAction actionWithTitle:@"5 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    
   value10Btn = [UIAlertAction actionWithTitle:@"10 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime10min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime10min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime10min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    
    /*UIAlertAction *value15Btn = [UIAlertAction actionWithTitle:@"15 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS setInteger:PlaybackStopTime15min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime15min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    [alert addAction:value15Btn];*/
    
    value20Btn = [UIAlertAction actionWithTitle:@"20 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime20min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime20min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime20min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    
    value30Btn = [UIAlertAction actionWithTitle:@"30 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime30min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime30min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime30min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    
    value60Btn = [UIAlertAction actionWithTitle:@"60 Minutes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS setInteger:PlaybackStopTime60min forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS setInteger:PlaybackStopTime60min forKey:LastSelectedSleepTimer];
            [USER_DEFAULTS synchronize];
            [AudioSession sharedAudioSession].timerValue = PlaybackStopTime60min;
            [self IntelligentSleepTimerUpdate];
        } afterDelay:0.1];
    }];
    [alert addAction:value60Btn];
    [alert addAction:value30Btn];
    [alert addAction:value20Btn];
    [alert addAction:value10Btn];
    [alert addAction:value5Btn];
    [alert addAction:value3Btn];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {

    }]];
    
    [self updateTimerAlertButtonsCheckmarks];
    
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [self getRootViewControllerDev];
    popPresenter.sourceView = self;
    popPresenter.sourceRect = self.bounds;
    popPresenter.permittedArrowDirections = UIPopoverArrowDirectionDown;
    //
    [alert.view addSubview:mainStack];
    alert.view.clipsToBounds = YES;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [mainStack.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor].active = YES;
    [mainStack.topAnchor constraintEqualToAnchor:alert.view.topAnchor constant:8].active = YES;
    [mainStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:alert.view.leadingAnchor constant:16].active = YES;
    [mainStack.trailingAnchor constraintLessThanOrEqualToAnchor:alert.view.trailingAnchor constant:-16].active = YES;
    [alert.view layoutIfNeeded];

    // Set minimum width for the alert to prevent text truncation
    CGFloat minWidth = 280;
    [alert.view.widthAnchor constraintGreaterThanOrEqualToConstant:minWidth].active = YES;

    // Height constraint for the alert view
    CGFloat height = 30 + alert.actions.count * 52 + mainStack.bounds.size.height;
    [alert.view.heightAnchor constraintEqualToConstant:height].active = YES;
    //
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    [rootViewController presentViewController:alert animated:YES completion:nil];
}

-(void)updateTimerAlertButtonsCheckmarks
{
    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
    BOOL isAlwaysTimerActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
    [noValueBtn setValue:@false forKey:@"checked"];
    [value3Btn setValue:@false forKey:@"checked"];
    [value5Btn setValue:@false forKey:@"checked"];
    [value10Btn setValue:@false forKey:@"checked"];
    [value20Btn setValue:@false forKey:@"checked"];
    [value30Btn setValue:@false forKey:@"checked"];
    [value60Btn setValue:@false forKey:@"checked"];
    if (sleepTimer == PlaybackStopTimeNoValue)
    {
        if (isAlwaysTimerActive)
        {
            if (lastSleepTimer == PlaybackStopTime3min)
            {
                [value3Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value3Btn setValue:@true forKey:@"checked"];
            }
            else if (lastSleepTimer == PlaybackStopTime5min)
            {
                [value5Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value5Btn setValue:@true forKey:@"checked"];
            }
            else if (lastSleepTimer == PlaybackStopTime10min)
            {
                [value10Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value10Btn setValue:@true forKey:@"checked"];
            }
            else if (lastSleepTimer == PlaybackStopTime20min)
            {
                [value20Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value20Btn setValue:@true forKey:@"checked"];
            }
            else if (lastSleepTimer == PlaybackStopTime30min)
            {
                [value30Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value30Btn setValue:@true forKey:@"checked"];
            }
            else if (lastSleepTimer == PlaybackStopTime60min)
            {
                [value60Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [value60Btn setValue:@true forKey:@"checked"];
            }
            else
            {
                [noValueBtn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
                [noValueBtn setValue:@true forKey:@"checked"];
            }
        }
        else
        {
            [noValueBtn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
            [noValueBtn setValue:@true forKey:@"checked"];
        }
    }
    else if (sleepTimer == PlaybackStopTime3min)
    {
        [value3Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value3Btn setValue:@true forKey:@"checked"];
    }
    else if (sleepTimer == PlaybackStopTime5min)
    {
        [value5Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value5Btn setValue:@true forKey:@"checked"];
    }
    else if (sleepTimer == PlaybackStopTime10min)
    {
        [value10Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value10Btn setValue:@true forKey:@"checked"];
    }
    //    else if (sleepTimer == PlaybackStopTime15min)
    //    {
    //        [value15Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
    //        [value15Btn setValue:@true forKey:@"checked"];
    //    }
    else if (sleepTimer == PlaybackStopTime20min)
    {
        [value20Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value20Btn setValue:@true forKey:@"checked"];
    }
    else if (sleepTimer == PlaybackStopTime30min)
    {
        [value30Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value30Btn setValue:@true forKey:@"checked"];
    }
    else if (sleepTimer == PlaybackStopTime60min)
    {
        [value60Btn setValue:[UIColor systemBlueColor] forKey:@"imageTintColor"];
        [value60Btn setValue:@true forKey:@"checked"];
    }
}

- (UIViewController*)getRootViewControllerDev
{
    UIViewController* rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
    if([rootViewController isKindOfClass:[UINavigationController class]])
    {
        rootViewController = ((UINavigationController *)rootViewController).viewControllers.firstObject;
    }
    else if([rootViewController isKindOfClass:[UITabBarController class]])
    {
        rootViewController = ((UITabBarController *)rootViewController).selectedViewController;
    }
    else if([rootViewController isKindOfClass:[MainViewController_4 class]])
    {
        rootViewController = ((MainViewController_4 *)rootViewController).presentedViewController;
    }
    return rootViewController;
}

/*
- (void)changeValue:(NSNotification *)notify
{
    NSString *selItem = [[notify userInfo] valueForKey:@"item"];
    [dropDown.view setHidden:true];
    isDropDownViewShowing = false;
    if ([selItem.ls isEqualToString:@"Off".ls])
    {
        if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
        {
            [USER_DEFAULTS setInteger:PlaybackStopTimeNoValue forKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS synchronize];
            [self IntelligentSleepTimerUpdate];
        }
    }
    else if ([selItem.ls isEqualToString:@"5 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
    else if ([selItem.ls isEqualToString:@"10 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime10min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
    else if ([selItem.ls isEqualToString:@"15 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime15min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
    else if ([selItem.ls isEqualToString:@"20 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime20min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
    else if ([selItem.ls isEqualToString:@"30 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime30min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
    else if ([selItem.ls isEqualToString:@"60 Minutes".ls])
    {
        [USER_DEFAULTS setInteger:PlaybackStopTime60min forKey:DefaultIntelligentSleepTimer];
        [USER_DEFAULTS synchronize];
        [self IntelligentSleepTimerUpdate];
    }
}
*/
- (CGRect)titleRectForContentRect:(CGRect)contentRect
{
    CGFloat w = 53;
    CGFloat h = 22;
    return CGRectMake(contentRect.origin.x + (contentRect.size.width - w) / 2,
                      contentRect.origin.y + (contentRect.size.height - h) / 2,
                      w, h);
}

- (CGRect)imageRectForContentRect:(CGRect)contentRect
{
    AudioSession* session = [AudioSession sharedAudioSession];
    if (session.timerValue == PlaybackStopTimeNoValue)
    {
        CGFloat w = 30;
        CGFloat h = 30;
        return CGRectMake(contentRect.origin.x + (contentRect.size.width - w) / 2,
                          contentRect.origin.y + (contentRect.size.height - h) / 2,
                          w, h);
    }
    else
    {
        CGFloat w = 53;
        CGFloat h = 22;
        return CGRectMake(contentRect.origin.x + (contentRect.size.width - w) / 2,
                          contentRect.origin.y + (contentRect.size.height - h) / 2,
                          w, h);
    }
}

@end
