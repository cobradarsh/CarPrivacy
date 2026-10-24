// Private iOS interfaces used by CarPrivacy.
// Everything here is looked up at runtime (NSClassFromString / respondsToSelector)
// so a missing class or method on a given iOS build is a no-op, not a crash.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

#pragma mark - SpringBoard

@interface SpringBoard : UIApplication
@end

#pragma mark - UserNotificationsKit (notification routing inside SpringBoard)

@interface NCNotificationRequest : NSObject <NSCopying, NSMutableCopying>
@property (nonatomic, copy, readonly) NSString *sectionIdentifier;   // app bundle ID
@property (nonatomic, copy, readonly) NSSet *requestDestinations;    // e.g. banner, lock screen, CarPlay
@end

@interface NCMutableNotificationRequest : NCNotificationRequest
- (void)setRequestDestinations:(NSSet *)destinations;
@end

@protocol CPNotificationDestination <NSObject>
@optional
- (NSString *)identifier;
@end

@interface NCNotificationDispatcher : NSObject
- (void)postNotificationWithRequest:(NCNotificationRequest *)request;
- (void)modifyNotificationWithRequest:(NCNotificationRequest *)request;
- (void)addDestination:(id<CPNotificationDestination>)destination;
@end

#pragma mark - CoreLocation (private)

@interface CLLocationManager (CarPrivacyPrivate)
+ (void)setLocationServicesEnabled:(BOOL)enabled;
@end

#pragma mark - BluetoothManager.framework

@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (BOOL)available;
- (NSArray<BluetoothDevice *> *)connectedDevices;
- (NSArray<BluetoothDevice *> *)pairedDevices;
@end

#pragma mark - CarKit.framework

@protocol CARSessionObserving <NSObject>
@optional
- (void)sessionDidConnect:(id)session;
- (void)sessionDidDisconnect:(id)session;
@end

@interface CARSessionStatus : NSObject
@property (nonatomic, readonly) id currentSession;
- (void)addSessionObserver:(id<CARSessionObserving>)observer;
- (void)removeSessionObserver:(id<CARSessionObserving>)observer;
@end
