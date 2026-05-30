//
//  ImageFunctions.h
//  Instacast
//
//  Created by Martin Hering on 23.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <Foundation/Foundation.h>


#ifdef __cplusplus
extern "C" {
#endif
	
	CGImageRef CreateScaledCGImageFromCGImage(CGImageRef image, CGFloat maxSide);
	
	CGImageRef CreateSquaredScaledCGImageFromCGImage(CGImageRef image,
													 CGFloat minSide);
	CGImageRef CreateSquaredScaledCroppedCGImageFromCGImage(CGImageRef image,
															CGFloat width,
															CGFloat centerScale,
															CGPoint translatePoint);
#if TARGET_OS_IPHONE==1
	UIImage* CreateGreyscaleImage(UIImage* i);
    UIImage* ICImageFromByDrawingInContext(CGSize size, void(^drawBlock)(void));
    UIImage* ICImageFromByDrawingInContextWithScale(CGSize size, BOOL opaque, CGFloat scale, void(^drawBlock)(void));
    UIImage* ICSkipIntervalImage(BOOL forward, NSInteger seconds, CGFloat pointSize);
#else
    NSImage* CreateGreyscaleImage(NSImage* i);
#endif
    
    
	
#ifdef __cplusplus
}  // extern "C"
#endif
