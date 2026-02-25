/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample's licensing information

    Abstract:
    An object wrapper around the low-level BSD Sockets ping function.
*/

#import "SimplePing.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

#define check_compile_time(expr) _Static_assert(expr, #expr)

#pragma mark * ICMP On-The-Wire Format

// ICMP type and code combinations for echo request/reply (ICMPv4 and ICMPv6).

enum {
    ICMPv4TypeEchoRequest = 8,
    ICMPv4TypeEchoReply   = 0
};

enum {
    ICMPv6TypeEchoRequest = 128,
    ICMPv6TypeEchoReply   = 129
};

/// Describes the on-the-wire header format for an ICMP ping.
struct ICMPHeader {
    uint8_t     type;
    uint8_t     code;
    uint16_t    checksum;
    uint16_t    identifier;
    uint16_t    sequenceNumber;
    // data...
};
typedef struct ICMPHeader ICMPHeader;

// Check that ICMPHeader is the expected size.
check_compile_time(sizeof(ICMPHeader) == 8);

/// Describes the on-the-wire header format for an IPv4 packet.
struct IPv4Header {
    uint8_t     versionAndHeaderLength;
    uint8_t     differentiatedServices;
    uint16_t    totalLength;
    uint16_t    identification;
    uint16_t    flagsAndFragmentOffset;
    uint8_t     timeToLive;
    uint8_t     protocol;
    uint16_t    headerChecksum;
    uint8_t     sourceAddress[4];
    uint8_t     destinationAddress[4];
    // options...
    // data...
};
typedef struct IPv4Header IPv4Header;

check_compile_time(sizeof(IPv4Header) == 20);

static uint16_t in_cksum(const void *buffer, size_t bufferLen) {
    // Standard BSD checksum code from original Apple sample.
    size_t              bytesLeft;
    int32_t             sum;
    const uint16_t *    cursor;
    union {
        uint16_t        us;
        uint8_t         uc[2];
    } last;
    uint16_t            answer;

    bytesLeft = bufferLen;
    sum = 0;
    cursor = buffer;

    while (bytesLeft > 1) {
        sum += *cursor;
        cursor += 1;
        bytesLeft -= 2;
    }

    if (bytesLeft == 1) {
        last.uc[0] = *(const uint8_t *)cursor;
        last.uc[1] = 0;
        sum += last.us;
    }

    sum = (sum >> 16) + (sum & 0xffff);
    sum += (sum >> 16);
    answer = (uint16_t) ~sum;

    return answer;
}

#pragma mark * SimplePing

@interface SimplePing ()

// Read/write versions of public properties.
@property (nonatomic, copy, readwrite, nullable) NSData *hostAddress;
@property (nonatomic, assign, readwrite) uint16_t nextSequenceNumber;

// Private properties.
@property (nonatomic, strong, nullable) CFHostRef host __attribute__((NSObject));
@property (nonatomic, assign) int socket;

@end

@implementation SimplePing

- (instancetype)initWithHostName:(NSString *)hostName {
    NSParameterAssert(hostName != nil);
    self = [super init];
    if (self != nil) {
        _hostName = [hostName copy];
        _identifier = (uint16_t)arc4random();
        _socket = -1;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    // Note: The _host property is managed by ARC because of __attribute__((NSObject)).
}

- (sa_family_t)hostAddressFamily {
    sa_family_t result;
    if (self.hostAddress != nil) {
        result = ((const struct sockaddr *) self.hostAddress.bytes)->sa_family;
    } else {
        result = AF_UNSPEC;
    }
    return result;
}

/// Called by the delegate machinery to verify that the delegate supports a given method.
- (BOOL)delegateRespondsToSelector:(SEL)selector {
    id strongDelegate = self.delegate;
    return (strongDelegate != nil) && [strongDelegate respondsToSelector:selector];
}

/// Sends a delegate callback on the main thread.
- (void)didStartWithAddress:(NSData *)address {
    if ([self delegateRespondsToSelector:@selector(simplePing:didStartWithAddress:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didStartWithAddress:)]) {
                [strongDelegate simplePing:self didStartWithAddress:address];
            }
        }];
    }
}

- (void)didFailWithError:(NSError *)error {
    if ([self delegateRespondsToSelector:@selector(simplePing:didFailWithError:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didFailWithError:)]) {
                [strongDelegate simplePing:self didFailWithError:error];
            }
        }];
    }
}

- (void)didSendPacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber {
    if ([self delegateRespondsToSelector:@selector(simplePing:didSendPacket:sequenceNumber:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didSendPacket:sequenceNumber:)]) {
                [strongDelegate simplePing:self didSendPacket:packet sequenceNumber:sequenceNumber];
            }
        }];
    }
}

- (void)didFailToSendPacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber error:(NSError *)error {
    if ([self delegateRespondsToSelector:@selector(simplePing:didFailToSendPacket:sequenceNumber:error:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didFailToSendPacket:sequenceNumber:error:)]) {
                [strongDelegate simplePing:self didFailToSendPacket:packet sequenceNumber:sequenceNumber error:error];
            }
        }];
    }
}

- (void)didReceivePingResponsePacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber {
    if ([self delegateRespondsToSelector:@selector(simplePing:didReceivePingResponsePacket:sequenceNumber:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didReceivePingResponsePacket:sequenceNumber:)]) {
                [strongDelegate simplePing:self didReceivePingResponsePacket:packet sequenceNumber:sequenceNumber];
            }
        }];
    }
}

- (void)didReceiveUnexpectedPacket:(NSData *)packet {
    if ([self delegateRespondsToSelector:@selector(simplePing:didReceiveUnexpectedPacket:)]) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            id<SimplePingDelegate> strongDelegate = (id<SimplePingDelegate>)self.delegate;
            if (strongDelegate && [strongDelegate respondsToSelector:@selector(simplePing:didReceiveUnexpectedPacket:)]) {
                [strongDelegate simplePing:self didReceiveUnexpectedPacket:packet];
            }
        }];
    }
}

/// Builds a ping packet from the supplied parameters.
- (NSData *)pingPacketWithType:(uint8_t)type payload:(NSData *)payload requiresChecksum:(BOOL)requiresChecksum {
    NSMutableData *packet;
    ICMPHeader *icmpPtr;

    packet = [NSMutableData dataWithLength:sizeof(*icmpPtr) + payload.length];
    assert(packet != nil);

    icmpPtr = packet.mutableBytes;
    icmpPtr->type = type;
    icmpPtr->code = 0;
    icmpPtr->checksum = 0;
    icmpPtr->identifier = OSSwapHostToBigInt16(self.identifier);
    icmpPtr->sequenceNumber = OSSwapHostToBigInt16(self.nextSequenceNumber);
    memcpy(&icmpPtr[1], payload.bytes, payload.length);

    if (requiresChecksum) {
        icmpPtr->checksum = in_cksum(packet.bytes, packet.length);
    }

    return packet;
}

- (void)sendPingWithData:(nullable NSData *)data {
    int err;
    NSData *payload;
    NSData *packet;
    ssize_t bytesSent;
    id<SimplePingDelegate> strongDelegate;

    // data may be nil
    NSParameterAssert(self.hostAddress != nil);

    // Construct the ping packet.
    payload = data;
    if (payload == nil) {
        payload = [[NSString stringWithFormat:@"%28zd bottles of beer on the wall", (ssize_t) 99 - (size_t) (self.nextSequenceNumber % 100)] dataUsingEncoding:NSASCIIStringEncoding];
        assert(payload != nil);
        // Our dummy payload is sized so that the resulting ICMP packet (including
        // the ICMP header) is 64 bytes, which makes it easier to recognise our
        // packets in a packet trace.
        assert([payload length] == 56);
    }

    switch (self.hostAddressFamily) {
        case AF_INET: {
            packet = [self pingPacketWithType:ICMPv4TypeEchoRequest payload:payload requiresChecksum:YES];
        } break;
        case AF_INET6: {
            packet = [self pingPacketWithType:ICMPv6TypeEchoRequest payload:payload requiresChecksum:NO];
        } break;
        default: {
            assert(NO);
        } break;
    }

    // Send the packet.
    if (self.socket < 0) {
        bytesSent = -1;
        err = EBADF;
    } else {
        bytesSent = sendto(
            self.socket,
            packet.bytes,
            packet.length,
            0,
            self.hostAddress.bytes,
            (socklen_t) self.hostAddress.length
        );
        err = (bytesSent >= 0) ? 0 : errno;
    }

    // Handle the results of the send.
    self.nextSequenceNumber += 1;
    if (bytesSent > 0 && ((NSUInteger) bytesSent == packet.length)) {
        // Complete success. Tell the client.
        [self didSendPacket:packet sequenceNumber:(uint16_t)(self.nextSequenceNumber - 1)];
    } else {
        NSError *error;
        if (err == 0) {
            error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOBUFS userInfo:nil];
        } else {
            error = [NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil];
        }
        [self didFailToSendPacket:packet sequenceNumber:(uint16_t)(self.nextSequenceNumber - 1) error:error];
    }
}

/// Returns YES if packet looks like a valid ICMPv4 ping response for us.
- (BOOL)validatePing4ResponsePacket:(NSMutableData *)packet sequenceNumber:(uint16_t *)sequenceNumberPtr {
    BOOL result;
    const struct IPv4Header *ipPtr;
    size_t ipHeaderLength;
    const ICMPHeader *icmpPtr;

    result = NO;

    if (packet.length >= (sizeof(IPv4Header) + sizeof(ICMPHeader))) {
        ipPtr = (const IPv4Header *) packet.bytes;
        assert((ipPtr->versionAndHeaderLength & 0xF0) == 0x40); // IPv4
        ipHeaderLength = (ipPtr->versionAndHeaderLength & 0x0F) * sizeof(uint32_t);

        if (packet.length >= (ipHeaderLength + sizeof(ICMPHeader))) {
            icmpPtr = (const ICMPHeader *) (((const uint8_t *) packet.bytes) + ipHeaderLength);

            if (icmpPtr->type == ICMPv4TypeEchoReply && icmpPtr->code == 0) {
                if (OSSwapBigToHostInt16(icmpPtr->identifier) == self.identifier) {
                    if (sequenceNumberPtr != NULL) {
                        *sequenceNumberPtr = OSSwapBigToHostInt16(icmpPtr->sequenceNumber);
                    }
                    result = YES;
                }
            }
        }
    }

    return result;
}

/// Returns YES if packet looks like a valid ICMPv6 ping response for us.
- (BOOL)validatePing6ResponsePacket:(NSMutableData *)packet sequenceNumber:(uint16_t *)sequenceNumberPtr {
    BOOL result;
    const ICMPHeader *icmpPtr;

    result = NO;

    if (packet.length >= sizeof(ICMPHeader)) {
        icmpPtr = (const ICMPHeader *) packet.bytes;

        if (icmpPtr->type == ICMPv6TypeEchoReply && icmpPtr->code == 0) {
            if (OSSwapBigToHostInt16(icmpPtr->identifier) == self.identifier) {
                if (sequenceNumberPtr != NULL) {
                    *sequenceNumberPtr = OSSwapBigToHostInt16(icmpPtr->sequenceNumber);
                }
                result = YES;
            }
        }
    }

    return result;
}

/// Returns YES if the packet is a valid ping response (either IPv4 or IPv6).
- (BOOL)validatePingResponsePacket:(NSMutableData *)packet sequenceNumber:(uint16_t *)sequenceNumberPtr {
    BOOL result;

    switch (self.hostAddressFamily) {
        case AF_INET: {
            result = [self validatePing4ResponsePacket:packet sequenceNumber:sequenceNumberPtr];
        } break;
        case AF_INET6: {
            result = [self validatePing6ResponsePacket:packet sequenceNumber:sequenceNumberPtr];
        } break;
        default: {
            result = NO;
        } break;
    }

    return result;
}

/// Reads data from the ICMP socket.
- (void)readData {
    int err;
    struct sockaddr_storage addr;
    socklen_t addrLen;
    ssize_t bytesRead;
    void *buffer;
    enum { kBufferSize = 65535 };

    // 65535 is enough for any ICMP packet.
    buffer = malloc(kBufferSize);
    assert(buffer != NULL);

    addrLen = sizeof(addr);
    bytesRead = recvfrom(self.socket, buffer, kBufferSize, 0, (struct sockaddr *) &addr, &addrLen);
    err = (bytesRead >= 0) ? 0 : errno;

    if (bytesRead > 0) {
        NSMutableData *packet;
        uint16_t sequenceNumber;

        packet = [NSMutableData dataWithBytes:buffer length:(NSUInteger) bytesRead];
        assert(packet != nil);

        // Try to interpret the packet as a ping response.
        if ([self validatePingResponsePacket:packet sequenceNumber:&sequenceNumber]) {
            [self didReceivePingResponsePacket:packet sequenceNumber:sequenceNumber];
        } else {
            [self didReceiveUnexpectedPacket:packet];
        }
    } else {
        // We failed to read the data, so shut everything down.
        if (err == 0) {
            err = EPIPE;
        }
        [self didFailWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]];
        [self stop];
    }

    free(buffer);
}

/// Called by CFSocket when there's data to read.
static void SocketReadCallback(CFSocketRef s, CFSocketCallBackType type, CFDataRef address, const void *data, void *info) {
    SimplePing *obj;

    (void)s;
    (void)type;
    (void)address;
    (void)data;

    obj = (__bridge SimplePing *) info;
    assert([obj isKindOfClass:[SimplePing class]]);

    [obj readData];
}

/// Starts the actual socket for sending/receiving ICMP.
- (void)startWithHostAddress {
    int err;
    int fd;

    // Open the socket.
    switch (self.hostAddressFamily) {
        case AF_INET: {
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        } break;
        case AF_INET6: {
            fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
        } break;
        default: {
            fd = -1;
            errno = EPROTONOSUPPORT;
        } break;
    }
    err = (fd >= 0) ? 0 : errno;

    if (err != 0) {
        [self didFailWithError:[NSError errorWithDomain:NSPOSIXErrorDomain code:err userInfo:nil]];
    } else {
        self.socket = fd;

        // Wrap it in a CFSocket and schedule it on the run loop.
        CFSocketContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
        CFSocketRef cfSocket = CFSocketCreateWithNative(NULL, fd, kCFSocketReadCallBack, SocketReadCallback, &context);
        assert(cfSocket != NULL);

        // The CFSocket now owns the socket, so we can forget about it.
        // Actually it doesn't — we don't set the close-on-invalidate flag — but
        // that's fine because we handle cleanup in -stop.

        CFRunLoopSourceRef rls = CFSocketCreateRunLoopSource(NULL, cfSocket, 0);
        assert(rls != NULL);

        CFRunLoopAddSource(CFRunLoopGetMain(), rls, kCFRunLoopDefaultMode);

        CFRelease(rls);
        CFRelease(cfSocket);

        [self didStartWithAddress:self.hostAddress];
    }
}

/// Called by CFHost when name resolution completes.
static void HostResolveCallback(CFHostRef theHost, CFHostInfoType typeInfo, const CFStreamError *error, void *info) {
    SimplePing *obj;

    (void)typeInfo;

    obj = (__bridge SimplePing *) info;
    assert([obj isKindOfClass:[SimplePing class]]);
    assert(theHost == obj.host);

    if ((error != NULL) && (error->domain != 0)) {
        [obj didFailWithError:[NSError errorWithDomain:@"kCFStreamErrorDomainKey" code:error->error userInfo:nil]];
    } else {
        [obj hostResolutionDone];
    }
}

/// Called after host resolution completes to pick an address and start pinging.
- (void)hostResolutionDone {
    Boolean resolved;
    NSArray *addresses;

    addresses = (__bridge NSArray *) CFHostGetAddressing(self.host, &resolved);
    if (resolved && (addresses != nil)) {
        // Find the first address that matches our style.
        NSData *address = nil;
        for (NSData *candidate in addresses) {
            const struct sockaddr *addrPtr = candidate.bytes;
            if (addrPtr->sa_family == AF_INET) {
                if (self.addressStyle != SimplePingAddressStyleICMPv6) {
                    address = candidate;
                    break;
                }
            } else if (addrPtr->sa_family == AF_INET6) {
                if (self.addressStyle != SimplePingAddressStyleICMPv4) {
                    address = candidate;
                    break;
                }
            }
        }

        if (address != nil) {
            self.hostAddress = address;
            [self startWithHostAddress];
        } else {
            [self didFailWithError:[NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil]];
        }
    } else {
        [self didFailWithError:[NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorHostNotFound userInfo:nil]];
    }
}

- (void)start {
    // If it looks like an IPv4 address, avoid DNS and go directly.
    Boolean isIPv4 = NO;
    {
        struct sockaddr_in sin;
        memset(&sin, 0, sizeof(sin));
        sin.sin_len = sizeof(sin);
        sin.sin_family = AF_INET;
        isIPv4 = inet_pton(AF_INET, self.hostName.UTF8String, &sin.sin_addr) == 1;
        if (isIPv4) {
            NSData *address = [NSData dataWithBytes:&sin length:sizeof(sin)];
            self.hostAddress = address;
            [self startWithHostAddress];
            return;
        }
    }

    // If it looks like an IPv6 address, avoid DNS and go directly.
    {
        struct sockaddr_in6 sin6;
        memset(&sin6, 0, sizeof(sin6));
        sin6.sin6_len = sizeof(sin6);
        sin6.sin6_family = AF_INET6;
        if (inet_pton(AF_INET6, self.hostName.UTF8String, &sin6.sin6_addr) == 1) {
            NSData *address = [NSData dataWithBytes:&sin6 length:sizeof(sin6)];
            self.hostAddress = address;
            [self startWithHostAddress];
            return;
        }
    }

    // Otherwise, do DNS resolution.
    CFStreamClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFHostRef hostRef = CFHostCreateWithName(NULL, (__bridge CFStringRef) self.hostName);
    assert(hostRef != NULL);
    self.host = hostRef;

    CFHostSetClient(self.host, HostResolveCallback, &context);
    CFHostScheduleWithRunLoop(self.host, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    CFStreamError streamError;
    Boolean success = CFHostStartInfoResolution(self.host, kCFHostAddresses, &streamError);
    if (!success) {
        [self didFailWithError:[NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork code:kCFHostErrorUnknown userInfo:nil]];
    }

    CFRelease(hostRef);
}

- (void)stop {
    if (self.host != NULL) {
        CFHostSetClient(self.host, NULL, NULL);
        CFHostUnscheduleFromRunLoop(self.host, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        self.host = NULL;
    }
    self.hostAddress = nil;

    if (self.socket >= 0) {
        close(self.socket);
        self.socket = -1;
    }
}

@end
