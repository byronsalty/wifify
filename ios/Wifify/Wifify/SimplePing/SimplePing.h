/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample's licensing information

    Abstract:
    An object wrapper around the low-level BSD Sockets ping function.
*/

@import Foundation;

#include <sys/socket.h>
#include <netinet/in.h>

NS_ASSUME_NONNULL_BEGIN

/// An object wrapper around the low-level BSD Sockets ping function.
///
/// To use the class create an instance, set the delegate, and then call `start`.
/// If things go well you'll be called with `-simplePing:didStartWithAddress:` and
/// can then start sending pings via `-sendPingWithData:`.
@interface SimplePing : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// Initializes the object to ping the specified host.
/// @param hostName The DNS name or IP address string of the host to ping.
- (instancetype)initWithHostName:(NSString *)hostName NS_DESIGNATED_INITIALIZER;

/// The DNS name or IP address string of the host being pinged.
@property (nonatomic, copy, readonly) NSString *hostName;

/// The delegate for this object.
@property (nonatomic, weak, nullable) id delegate;

/// Controls the IP address version to use.
///
/// You should set this before calling `-start`.
typedef NS_ENUM(NSInteger, SimplePingAddressStyle) {
    SimplePingAddressStyleAny,    ///< Use the first IPv4 or IPv6 address found
    SimplePingAddressStyleICMPv4, ///< Use the first IPv4 address found
    SimplePingAddressStyleICMPv6  ///< Use the first IPv6 address found
};
@property (nonatomic, assign) SimplePingAddressStyle addressStyle;

/// The address being pinged, set after name resolution completes.
@property (nonatomic, copy, readonly, nullable) NSData *hostAddress;

/// The address family for `hostAddress`, or `AF_UNSPEC` if not yet resolved.
@property (nonatomic, assign, readonly) sa_family_t hostAddressFamily;

/// The identifier used by this object.
///
/// When you create an instance of this class it generates a random identifier
/// which it uses to identify its own pings.
@property (nonatomic, assign, readonly) uint16_t identifier;

/// The next sequence number to be used by this object.
@property (nonatomic, assign, readonly) uint16_t nextSequenceNumber;

/// Start the pinger.
///
/// This tells the object to start the name resolution process.
/// Success or failure is indicated via delegate callbacks.
- (void)start;

/// Send a ping packet with the specified data.
///
/// Sends an actual ping. The delegate is called if the send succeeds or fails.
/// @param data Some data to include in the ping packet, after the ICMP header.
///     May be nil.
- (void)sendPingWithData:(nullable NSData *)data;

/// Stop the pinger.
///
/// This stops any name resolution, deregisters from runloop sources, etc.
- (void)stop;

@end

/// A delegate protocol for the SimplePing class.
@protocol SimplePingDelegate <NSObject>
@optional

/// Called after the object has started up, meaning name resolution completed.
- (void)simplePing:(SimplePing *)pinger didStartWithAddress:(NSData *)address;

/// Called if the object fails to start up.
- (void)simplePing:(SimplePing *)pinger didFailWithError:(NSError *)error;

/// Called when the object has successfully sent a ping packet.
- (void)simplePing:(SimplePing *)pinger didSendPacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber;

/// Called if the object fails to send a ping packet.
- (void)simplePing:(SimplePing *)pinger didFailToSendPacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber error:(NSError *)error;

/// Called when the object receives a valid ping response.
- (void)simplePing:(SimplePing *)pinger didReceivePingResponsePacket:(NSData *)packet sequenceNumber:(uint16_t)sequenceNumber;

/// Called when the object receives an unmatched ICMP packet.
- (void)simplePing:(SimplePing *)pinger didReceiveUnexpectedPacket:(NSData *)packet;

@end

NS_ASSUME_NONNULL_END
