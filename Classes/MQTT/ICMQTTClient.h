//
//  ICMQTTClient.h
//  Instacast
//
//  Lightweight MQTT 3.1.1 client (QoS 0) for smart home integration.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ICMQTTConnectionState) {
    ICMQTTConnectionStateDisconnected,
    ICMQTTConnectionStateConnecting,
    ICMQTTConnectionStateConnected
};

@class ICMQTTClient;

@protocol ICMQTTClientDelegate <NSObject>
@optional
- (void)mqttClientDidConnect:(ICMQTTClient*)client;
- (void)mqttClientDidDisconnect:(ICMQTTClient*)client error:(nullable NSError*)error;
- (void)mqttClient:(ICMQTTClient*)client didReceiveMessage:(NSString*)message onTopic:(NSString*)topic;
@end

@interface ICMQTTClient : NSObject

@property (nonatomic, weak, nullable) id<ICMQTTClientDelegate> delegate;
@property (nonatomic, readonly) ICMQTTConnectionState connectionState;

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, assign) NSTimeInterval keepAlive;

// Last Will and Testament
@property (nonatomic, copy, nullable) NSString *willTopic;
@property (nonatomic, copy, nullable) NSString *willMessage;
@property (nonatomic, assign) BOOL willRetain;

- (void)connect;
- (void)disconnect;

- (void)publishMessage:(NSString*)message toTopic:(NSString*)topic retain:(BOOL)retain;
- (void)subscribeToTopic:(NSString*)topic;

@end

NS_ASSUME_NONNULL_END
