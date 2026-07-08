//
//  Sound.h
//  Instacast
//
//  Created by Martin Hering on 18.03.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <Foundation/Foundation.h>


void PlaySoundFile(NSString* name, BOOL vibrate);

typedef NS_ENUM(NSInteger, ICHapticFeedbackType) {
    ICHapticFeedbackLight,   // state toggles (played, favorite, play next)
    ICHapticFeedbackMedium,  // transport actions (play/pause, skip)
};

// Fires a haptic tap; no-op when disabled in settings (UIHapticsEnabled).
// Main thread only.
void PlayHapticFeedback(ICHapticFeedbackType type);
