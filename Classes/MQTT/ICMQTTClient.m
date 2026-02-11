//
//  ICMQTTClient.m
//  Instacast
//
//  Lightweight MQTT 3.1.1 client (QoS 0) for smart home integration.
//

#import "ICMQTTClient.h"

// MQTT Control Packet Types
typedef NS_ENUM(uint8_t, ICMQTTPacketType) {
    ICMQTTPacketConnect     = 1,
    ICMQTTPacketConnAck     = 2,
    ICMQTTPacketPublish     = 3,
    ICMQTTPacketSubscribe   = 8,
    ICMQTTPacketSubAck      = 9,
    ICMQTTPacketPingReq     = 12,
    ICMQTTPacketPingResp    = 13,
    ICMQTTPacketDisconnect  = 14
};

@interface ICMQTTClient () <NSStreamDelegate>
{
    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
    NSMutableData *_readBuffer;
    NSMutableData *_writeBuffer;
    NSTimer *_pingTimer;
    NSTimer *_connectTimeoutTimer;
    uint16_t _packetId;
    ICMQTTClient *_selfRetainWhileDisconnecting;
}
@end

@implementation ICMQTTClient

+ (void)_networkThreadMain:(id)__unused object
{
    @autoreleasepool {
        [[NSThread currentThread] setName:@"ICMQTTClient.NetworkThread"];
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        while (YES) {
            @autoreleasepool {
                [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
            }
        }
    }
}

+ (NSThread *)networkThread
{
    static NSThread *thread = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        thread = [[NSThread alloc] initWithTarget:self selector:@selector(_networkThreadMain:) object:nil];
        [thread start];
    });
    return thread;
}

- (void)performOnNetworkThread:(SEL)selector waitUntilDone:(BOOL)wait
{
    NSThread *networkThread = [[self class] networkThread];
    if ([NSThread currentThread] == networkThread) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:selector];
#pragma clang diagnostic pop
        return;
    }
    [self performSelector:selector onThread:networkThread withObject:nil waitUntilDone:wait];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _port = 1883;
        _keepAlive = 60;
        _clientId = [[NSString alloc] initWithFormat:@"instacast-%@", [[NSUUID UUID] UUIDString]];
        _readBuffer = [[NSMutableData alloc] init];
        _writeBuffer = [[NSMutableData alloc] init];
        _connectionState = ICMQTTConnectionStateDisconnected;
        _packetId = 0;
    }
    return self;
}

- (void)dealloc
{
    _delegate = nil;
}

#pragma mark - Connection

- (void)connect
{
    [self performOnNetworkThread:@selector(connectOnNetworkThread) waitUntilDone:NO];
}

- (void)connectOnNetworkThread
{
    if (_connectionState != ICMQTTConnectionStateDisconnected) {
        return;
    }

    _connectionState = ICMQTTConnectionStateConnecting;
    [_readBuffer setLength:0];

    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)_host, _port, &readStream, &writeStream);

    _inputStream = (__bridge_transfer NSInputStream*)readStream;
    _outputStream = (__bridge_transfer NSOutputStream*)writeStream;

    _inputStream.delegate = self;
    _outputStream.delegate = self;

    [_inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

    [_inputStream open];
    [_outputStream open];

    // Connection timeout after 10 seconds
    [_connectTimeoutTimer invalidate];
    _connectTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(connectTimeout) userInfo:nil repeats:NO];
}

- (void)disconnect
{
    _selfRetainWhileDisconnecting = self;
    [self performOnNetworkThread:@selector(disconnectOnNetworkThread) waitUntilDone:NO];
}

- (void)disconnectOnNetworkThread
{
    if (_connectionState == ICMQTTConnectionStateDisconnected) {
        _selfRetainWhileDisconnecting = nil;
        return;
    }

    if (_connectionState == ICMQTTConnectionStateConnected) {
        [self sendDisconnect];
    }

    [self closeStreams];
    _connectionState = ICMQTTConnectionStateDisconnected;
    _selfRetainWhileDisconnecting = nil;
}

- (void)closeStreams
{
    [_pingTimer invalidate];
    _pingTimer = nil;

    [_connectTimeoutTimer invalidate];
    _connectTimeoutTimer = nil;

    _inputStream.delegate = nil;
    _outputStream.delegate = nil;

    [_inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

    [_inputStream close];
    [_outputStream close];

    _inputStream = nil;
    _outputStream = nil;

    [_writeBuffer setLength:0];
}

- (void)connectTimeout
{
    _connectTimeoutTimer = nil;

    if (_connectionState == ICMQTTConnectionStateConnecting) {
        NSError *error = [NSError errorWithDomain:@"ICMQTTErrorDomain" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Connection timeout - server not reachable".ls}];
        [self closeStreams];
        _connectionState = ICMQTTConnectionStateDisconnected;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate mqttClientDidDisconnect:self error:error];
        });
    }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream*)stream handleEvent:(NSStreamEvent)event
{
    switch (event) {
        case NSStreamEventOpenCompleted:
            if (stream == _outputStream) {
                [self sendConnect];
            }
            break;

        case NSStreamEventHasBytesAvailable:
            if (stream == _inputStream) {
                [self readFromStream];
            }
            break;

        case NSStreamEventHasSpaceAvailable:
            if (stream == _outputStream) {
                [self flushWriteBuffer];
            }
            break;

        case NSStreamEventErrorOccurred:
        {
            NSError *error = stream.streamError;
            [self closeStreams];
            ICMQTTConnectionState prevState = _connectionState;
            _connectionState = ICMQTTConnectionStateDisconnected;
            if (prevState != ICMQTTConnectionStateDisconnected) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate mqttClientDidDisconnect:self error:error];
                });
            }
            break;
        }

        case NSStreamEventEndEncountered:
        {
            [self closeStreams];
            ICMQTTConnectionState prevState = _connectionState;
            _connectionState = ICMQTTConnectionStateDisconnected;
            if (prevState != ICMQTTConnectionStateDisconnected) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate mqttClientDidDisconnect:self error:nil];
                });
            }
            break;
        }

        default:
            break;
    }
}

#pragma mark - Reading

- (void)readFromStream
{
    uint8_t buf[4096];
    while (_inputStream.hasBytesAvailable) {
        NSInteger len = [_inputStream read:buf maxLength:sizeof(buf)];
        if (len > 0) {
            [_readBuffer appendBytes:buf length:len];
        }
    }

    [self processReadBuffer];
}

- (void)processReadBuffer
{
    while (_readBuffer.length >= 2) {
        const uint8_t *bytes = _readBuffer.bytes;

        // Parse fixed header
        uint8_t packetTypeByte = bytes[0];

        // Parse remaining length (variable-length encoding)
        NSUInteger offset = 1;
        NSUInteger remainingLength = 0;
        NSUInteger multiplier = 1;
        uint8_t encodedByte;

        do {
            if (offset >= _readBuffer.length) {
                return; // Need more data
            }
            encodedByte = bytes[offset++];
            remainingLength += (encodedByte & 0x7F) * multiplier;
            multiplier *= 128;
            if (multiplier > 128 * 128 * 128) {
                // Malformed remaining length
                [self disconnect];
                return;
            }
        } while (encodedByte & 0x80);

        NSUInteger totalPacketLength = offset + remainingLength;
        if (_readBuffer.length < totalPacketLength) {
            return; // Need more data
        }

        // Extract packet data
        NSData *packetData = [_readBuffer subdataWithRange:NSMakeRange(offset, remainingLength)];

        // Remove processed data from buffer
        [_readBuffer replaceBytesInRange:NSMakeRange(0, totalPacketLength) withBytes:NULL length:0];

        // Handle packet
        uint8_t packetType = (packetTypeByte >> 4) & 0x0F;
        [self handlePacketType:packetType flags:packetTypeByte data:packetData];
    }
}

- (void)handlePacketType:(uint8_t)type flags:(uint8_t)flags data:(NSData*)data
{
    switch (type) {
        case ICMQTTPacketConnAck:
            [self handleConnAck:data];
            break;

        case ICMQTTPacketPublish:
            [self handlePublish:data flags:flags];
            break;

        case ICMQTTPacketSubAck:
            // Subscription acknowledged
            break;

        case ICMQTTPacketPingResp:
            // Ping response received
            break;

        default:
            break;
    }
}

- (void)handleConnAck:(NSData*)data
{
    if (data.length < 2) return;

    const uint8_t *bytes = data.bytes;
    uint8_t returnCode = bytes[1];

    if (returnCode == 0) {
        [_connectTimeoutTimer invalidate];
        _connectTimeoutTimer = nil;
        _connectionState = ICMQTTConnectionStateConnected;
        [self startPingTimer];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate mqttClientDidConnect:self];
        });
    } else {
        [_connectTimeoutTimer invalidate];
        _connectTimeoutTimer = nil;
        NSString *desc;
        switch (returnCode) {
            case 1: desc = @"Protocol version not supported".ls; break;
            case 2: desc = @"Client ID rejected".ls; break;
            case 3: desc = @"Server unavailable".ls; break;
            case 4: desc = @"Invalid username or password".ls; break;
            case 5: desc = @"Not authorized".ls; break;
            default: desc = @"Connection refused".ls; break;
        }
        NSError *error = [NSError errorWithDomain:@"ICMQTTErrorDomain" code:returnCode
                                         userInfo:@{NSLocalizedDescriptionKey: desc}];
        [self closeStreams];
        _connectionState = ICMQTTConnectionStateDisconnected;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate mqttClientDidDisconnect:self error:error];
        });
    }
}

- (void)handlePublish:(NSData*)data flags:(uint8_t)flags
{
    if (data.length < 2) return;

    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    uint8_t headerFlags = flags & 0x0F;
    uint8_t qos = (headerFlags >> 1) & 0x03;

    // Topic length (MSB + LSB)
    uint16_t topicLen = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    if (offset + topicLen > data.length) return;

    NSString *topic = [[NSString alloc] initWithBytes:bytes + offset length:topicLen encoding:NSUTF8StringEncoding];
    offset += topicLen;

    // QoS 1/2 includes packet identifier after topic.
    if (qos > 0) {
        if (offset + 2 > data.length) return;
        offset += 2;
    }

    NSString *message = @"";
    if (offset < data.length) {
        message = [[NSString alloc] initWithBytes:bytes + offset length:data.length - offset encoding:NSUTF8StringEncoding];
        if (!message) message = @"";
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate mqttClient:self didReceiveMessage:message onTopic:topic];
    });
}

#pragma mark - Sending

- (void)writeData:(NSData*)data
{
    if (!_outputStream) return;

    // Add to write buffer
    [_writeBuffer appendData:data];

    // Try to flush immediately if stream is ready
    [self flushWriteBuffer];
}

- (void)flushWriteBuffer
{
    if (!_outputStream || _outputStream.streamStatus != NSStreamStatusOpen) {
        return;
    }
    if (_writeBuffer.length == 0) return;
    if (!_outputStream.hasSpaceAvailable) {
        return;
    }

    const uint8_t *bytes = _writeBuffer.bytes;
    NSInteger len = [_outputStream write:bytes maxLength:_writeBuffer.length];

    if (len > 0) {
        [_writeBuffer replaceBytesInRange:NSMakeRange(0, len) withBytes:NULL length:0];
    }
}

- (NSMutableData*)encodeRemainingLength:(NSUInteger)length
{
    NSMutableData *encoded = [NSMutableData data];
    do {
        uint8_t byte = length % 128;
        length /= 128;
        if (length > 0) {
            byte |= 0x80;
        }
        [encoded appendBytes:&byte length:1];
    } while (length > 0);
    return encoded;
}

- (void)appendUTF8String:(NSString*)string toData:(NSMutableData*)data
{
    NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t len = CFSwapInt16HostToBig((uint16_t)utf8.length);
    [data appendBytes:&len length:2];
    [data appendData:utf8];
}

- (uint16_t)nextPacketId
{
    _packetId++;
    if (_packetId == 0) _packetId = 1;
    return _packetId;
}

#pragma mark - MQTT Packets

- (void)sendConnect
{
    NSMutableData *variableHeader = [NSMutableData data];

    // Protocol Name
    [self appendUTF8String:@"MQTT" toData:variableHeader];

    // Protocol Level (4 = MQTT 3.1.1)
    uint8_t protocolLevel = 4;
    [variableHeader appendBytes:&protocolLevel length:1];

    // Connect Flags
    uint8_t connectFlags = 0x02; // Clean Session
    if (_username) connectFlags |= 0x80;
    if (_password) connectFlags |= 0x40;
    if (_willTopic && _willMessage) {
        connectFlags |= 0x04; // Will Flag
        if (_willRetain) connectFlags |= 0x20; // Will Retain
    }
    [variableHeader appendBytes:&connectFlags length:1];

    // Keep Alive
    uint16_t ka = CFSwapInt16HostToBig((uint16_t)_keepAlive);
    [variableHeader appendBytes:&ka length:2];

    // Payload
    NSMutableData *payload = [NSMutableData data];
    [self appendUTF8String:_clientId toData:payload];

    if (_willTopic && _willMessage) {
        [self appendUTF8String:_willTopic toData:payload];
        [self appendUTF8String:_willMessage toData:payload];
    }

    if (_username) [self appendUTF8String:_username toData:payload];
    if (_password) [self appendUTF8String:_password toData:payload];

    // Build packet
    NSUInteger remainingLength = variableHeader.length + payload.length;
    NSMutableData *packet = [NSMutableData data];
    uint8_t fixedHeader = (ICMQTTPacketConnect << 4);
    [packet appendBytes:&fixedHeader length:1];
    [packet appendData:[self encodeRemainingLength:remainingLength]];
    [packet appendData:variableHeader];
    [packet appendData:payload];

    [self writeData:packet];
}

- (void)sendDisconnect
{
    uint8_t packet[] = { (ICMQTTPacketDisconnect << 4), 0x00 };
    [self writeData:[NSData dataWithBytes:packet length:2]];
}

- (void)publishMessage:(NSString*)message toTopic:(NSString*)topic retain:(BOOL)retain
{
    NSDictionary *payload = @{
        @"message": message ?: @"",
        @"topic": topic ?: @"",
        @"retain": @(retain)
    };
    [self performSelector:@selector(publishOnNetworkThread:) onThread:[[self class] networkThread] withObject:payload waitUntilDone:NO];
}

- (void)publishOnNetworkThread:(NSDictionary *)payload
{
    if (_connectionState != ICMQTTConnectionStateConnected) {
        return;
    }

    NSString *message = payload[@"message"];
    NSString *topic = payload[@"topic"];
    BOOL retain = [payload[@"retain"] boolValue];

    NSMutableData *variableHeader = [NSMutableData data];
    [self appendUTF8String:topic toData:variableHeader];
    // QoS 0: no packet identifier

    NSData *payloadData = [message dataUsingEncoding:NSUTF8StringEncoding];

    NSUInteger remainingLength = variableHeader.length + payloadData.length;
    NSMutableData *packet = [NSMutableData data];
    uint8_t fixedHeader = (ICMQTTPacketPublish << 4);
    if (retain) fixedHeader |= 0x01;
    [packet appendBytes:&fixedHeader length:1];
    [packet appendData:[self encodeRemainingLength:remainingLength]];
    [packet appendData:variableHeader];
    [packet appendData:payloadData];

    [self writeData:packet];
}

- (void)subscribeToTopic:(NSString*)topic
{
    [self performSelector:@selector(subscribeOnNetworkThread:) onThread:[[self class] networkThread] withObject:topic waitUntilDone:NO];
}

- (void)subscribeOnNetworkThread:(NSString*)topic
{
    if (_connectionState != ICMQTTConnectionStateConnected) return;

    NSMutableData *variableHeader = [NSMutableData data];
    uint16_t pid = CFSwapInt16HostToBig([self nextPacketId]);
    [variableHeader appendBytes:&pid length:2];

    NSMutableData *payload = [NSMutableData data];
    [self appendUTF8String:topic toData:payload];
    uint8_t qos = 0;
    [payload appendBytes:&qos length:1];

    NSUInteger remainingLength = variableHeader.length + payload.length;
    NSMutableData *packet = [NSMutableData data];
    uint8_t fixedHeader = (ICMQTTPacketSubscribe << 4) | 0x02; // Reserved bit must be 1
    [packet appendBytes:&fixedHeader length:1];
    [packet appendData:[self encodeRemainingLength:remainingLength]];
    [packet appendData:variableHeader];
    [packet appendData:payload];

    [self writeData:packet];
}

#pragma mark - Ping

- (void)startPingTimer
{
    [_pingTimer invalidate];
    NSTimeInterval interval = _keepAlive * 0.75;
    _pingTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self
                                                selector:@selector(sendPing) userInfo:nil repeats:YES];
}

- (void)sendPing
{
    if (_connectionState != ICMQTTConnectionStateConnected) return;
    uint8_t packet[] = { (ICMQTTPacketPingReq << 4), 0x00 };
    [self writeData:[NSData dataWithBytes:packet length:2]];
}

@end
