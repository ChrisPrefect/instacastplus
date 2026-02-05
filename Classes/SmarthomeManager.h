//
//  SmarthomeManager.h
//  Instacast
//
//  MQTT smart home integration manager.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* SmarthomeManagerDidChangeConnectionStateNotification;

@interface SmarthomeManager : NSObject

+ (SmarthomeManager*)sharedManager;

- (void)start;
- (void)stop;
- (void)reconnectIfNeeded;

@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly, nullable) NSString *connectionStatusText;

+ (NSString*)defaultDeviceName;

@end

NS_ASSUME_NONNULL_END
