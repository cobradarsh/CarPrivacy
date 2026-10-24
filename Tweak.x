// CarPrivacy — runs inside SpringBoard.
//
// Part 1: hides notifications from chosen apps on the CarPlay screen
//         (they still arrive normally on the phone).
// Part 2: turns Location Services on when the phone joins your car
//         (CarPlay and/or chosen Bluetooth devices) and, depending on the
//         chosen mode, back off when you leave.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <os/lock.h>
#import "Headers/Private.h"

#define kPrefsDomain   CFSTR("com.adarsh.carprivacy")
#define kStateDomain   CFSTR("com.adarsh.carprivacy.state")
#define kPrefsChanged  CFSTR("com.adarsh.carprivacy/prefsChanged")
#define kStatusRequest CFSTR("com.adarsh.carprivacy/statusRequest")

#define CPLog(fmt, ...) do { if (gDebug) NSLog(@"[CarPrivacy] " fmt, ##__VA_ARGS__); } while (0)

typedef NS_ENUM(NSInteger, CPLocationOffMode) {
    CPLocationOffModeRestore = 0, // turn off only if CarPrivacy was the one that turned it on
    CPLocationOffModeAlways  = 1, // always turn off when leaving the car
    CPLocationOffModeNever   = 2, // never turn off
};

#pragma mark - Preferences

static BOOL gEnabled = YES;
static BOOL gTriggerCarPlay = YES;
static BOOL gTriggerBluetooth = YES;
static BOOL gSuppressEnabled = YES;
static BOOL gLocationEnabled = YES;
static BOOL gDebug = NO;
static CPLocationOffMode gOffMode = CPLocationOffModeRestore;
static double gDisconnectDelay = 20.0;
static NSSet<NSString *> *gBlockedApps;   // also read from SpringBoard's notification queues
static os_unfair_lock gBlockedAppsLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *gCarAddresses;  // uppercase MAC addresses
static NSSet<NSString *> *gCarNames;      // lowercase device names

static id CPPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain));
}

static BOOL CPBool(NSString *key, BOOL fallback) {
    id value = CPPref(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSSet<NSString *> *CPNormalizedSet(NSArray *items, BOOL uppercase) {
    NSMutableSet *set = [NSMutableSet set];
    for (id item in items) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *s = [item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length) [set addObject:uppercase ? s.uppercaseString : s.lowercaseString];
    }
    return set;
}

static void CPReloadPrefs(void) {
    CFPreferencesAppSynchronize(kPrefsDomain);

    gEnabled          = CPBool(@"enabled", YES);
    gTriggerCarPlay   = CPBool(@"triggerCarPlay", YES);
    gTriggerBluetooth = CPBool(@"triggerBluetooth", YES);
    gSuppressEnabled  = CPBool(@"suppressEnabled", YES);
    gLocationEnabled  = CPBool(@"locationEnabled", YES);
    gDebug            = CPBool(@"debugLogging", NO);

    id mode = CPPref(@"locationOffMode");
    gOffMode = [mode respondsToSelector:@selector(integerValue)] ? (CPLocationOffMode)[mode integerValue] : CPLocationOffModeRestore;

    id delay = CPPref(@"disconnectDelay");
    gDisconnectDelay = [delay respondsToSelector:@selector(doubleValue)] ? MAX(0.0, [delay doubleValue]) : 20.0;

    id apps = CPPref(@"blockedApps");
    NSSet *blocked = [NSSet setWithArray:[apps isKindOfClass:NSArray.class] ? apps : @[]];
    os_unfair_lock_lock(&gBlockedAppsLock);
    gBlockedApps = blocked;
    os_unfair_lock_unlock(&gBlockedAppsLock);

    id addresses = CPPref(@"carDevices");
    gCarAddresses = CPNormalizedSet([addresses isKindOfClass:NSArray.class] ? addresses : @[], YES);

    id names = CPPref(@"carDeviceNames");
    gCarNames = CPNormalizedSet([names isKindOfClass:NSString.class] ? [names componentsSeparatedByString:@","] : @[], NO);
}

#pragma mark - Status (shown in Settings > CarPrivacy > Show Status)

static BOOL gCarPlaySession;   // from CarKit callbacks
static BOOL gCarPlayActive;    // CarKit session or CarPlay audio route
static BOOL gBluetoothActive;  // a chosen car Bluetooth device is connected
static BOOL gInCar;
static NSString *gMatchedDevice;
static NSMutableOrderedSet<NSString *> *gHookedDestinations;
static NSString *gLastSuppressed;
static NSString *gLastDestinations;
static NSString *gLastLocationAction = @"none yet";

static void CPWriteStatus(void) {
    NSDictionary *status = @{
        @"carPlayActive":     @(gCarPlayActive),
        @"bluetoothActive":   @(gBluetoothActive),
        @"inCar":             @(gInCar),
        @"matchedDevice":     gMatchedDevice ?: @"",
        @"hookedDestinations": gHookedDestinations.array ?: @[],
        @"lastSuppressed":    gLastSuppressed ?: @"",
        @"lastDestinations":  gLastDestinations ?: @"",
        @"lastLocationAction": gLastLocationAction ?: @"",
        @"updated":           NSDate.date,
    };
    CFPreferencesSetAppValue(CFSTR("status"), (__bridge CFDictionaryRef)status, kStateDomain);
    CFPreferencesAppSynchronize(kStateDomain);
}

static void CPWriteStatusOnMain(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ CPWriteStatus(); });
}

#pragma mark - Part 1: hiding notifications from CarPlay

static BOOL CPShouldHideFromCar(id request) {
    if (!gEnabled || !gSuppressEnabled || !request) return NO;
    if (![request respondsToSelector:@selector(sectionIdentifier)]) return NO;
    NSString *bundleID = [request sectionIdentifier];
    if (![bundleID isKindOfClass:NSString.class]) return NO;
    os_unfair_lock_lock(&gBlockedAppsLock);
    BOOL blocked = [gBlockedApps containsObject:bundleID];
    os_unfair_lock_unlock(&gBlockedAppsLock);
    return blocked;
}

static void CPNoteSuppressed(id request, NSString *where) {
    NSString *bundleID = [request sectionIdentifier];
    CPLog(@"Hid %@ from CarPlay (%@)", bundleID, where);
    dispatch_async(dispatch_get_main_queue(), ^{
        gLastSuppressed = [NSString stringWithFormat:@"%@ via %@", bundleID, where];
        CPWriteStatus();
    });
}

// Matches "CarPlay", "CarDestination", ... but not "Card".
static BOOL CPLooksCarRelated(id value) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"Car(?![a-z])" options:0 error:nil];
    });
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *s = value;
    return [regex firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

// Layer A: hook the CarPlay notification destination itself, whatever it is called
// on this iOS build. Hooks are installed per class with blocks so several candidate
// classes can be handled by the same code.

static void CPHookBoolMethod(Class cls, SEL sel) {
    if (!class_getInstanceMethod(cls, sel)) return;
    __block BOOL (*orig)(id, SEL, id) = NULL;
    IMP replacement = imp_implementationWithBlock(^BOOL(id self_, id request) {
        if (CPShouldHideFromCar(request)) {
            CPNoteSuppressed(request, NSStringFromSelector(sel));
            return NO;
        }
        return orig ? orig(self_, sel, request) : YES;
    });
    MSHookMessageEx(cls, sel, replacement, (IMP *)&orig);
}

static void CPHookVoidMethod1(Class cls, SEL sel) {
    if (!class_getInstanceMethod(cls, sel)) return;
    __block void (*orig)(id, SEL, id) = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self_, id request) {
        if (CPShouldHideFromCar(request)) {
            CPNoteSuppressed(request, NSStringFromSelector(sel));
            return;
        }
        if (orig) orig(self_, sel, request);
    });
    MSHookMessageEx(cls, sel, replacement, (IMP *)&orig);
}

static void CPHookVoidMethod2(Class cls, SEL sel) {
    if (!class_getInstanceMethod(cls, sel)) return;
    __block void (*orig)(id, SEL, id, id) = NULL;
    IMP replacement = imp_implementationWithBlock(^(id self_, id request, id other) {
        if (CPShouldHideFromCar(request)) {
            CPNoteSuppressed(request, NSStringFromSelector(sel));
            return;
        }
        if (orig) orig(self_, sel, request, other);
    });
    MSHookMessageEx(cls, sel, replacement, (IMP *)&orig);
}

static void CPHookCarDestinationClass(Class cls) {
    if (!cls) return;
    NSString *name = NSStringFromClass(cls);
    @synchronized (gHookedDestinations) {
        if ([gHookedDestinations containsObject:name]) return;
        [gHookedDestinations addObject:name];
    }

    CPHookBoolMethod(cls, @selector(canReceiveNotificationRequest:));
    CPHookVoidMethod1(cls, @selector(postNotificationRequest:));
    CPHookVoidMethod2(cls, @selector(postNotificationRequest:forCoalescedNotification:));
    CPHookVoidMethod1(cls, @selector(modifyNotificationRequest:));
    CPHookVoidMethod2(cls, @selector(modifyNotificationRequest:forCoalescedNotification:));

    CPLog(@"Hooked CarPlay notification destination %@", name);
    CPWriteStatusOnMain();
}

static BOOL CPIsCarDestination(id<CPNotificationDestination> destination) {
    if (CPLooksCarRelated(NSStringFromClass([destination class]))) return YES;
    if ([destination respondsToSelector:@selector(identifier)]) {
        return CPLooksCarRelated([destination identifier]);
    }
    return NO;
}

// Layer B: strip CarPlay destinations off the request before SpringBoard routes it,
// so the banner/lock screen/Notification Center copies are untouched.

static NCNotificationRequest *CPRequestWithoutCarDestinations(NCNotificationRequest *request) {
    if (![request respondsToSelector:@selector(requestDestinations)]) return request;
    NSSet *destinations = request.requestDestinations;

    if (gDebug) {
        NSString *joined = [[destinations.allObjects valueForKey:@"description"] componentsJoinedByString:@", "];
        dispatch_async(dispatch_get_main_queue(), ^{ gLastDestinations = joined; });
    }

    if (!CPShouldHideFromCar(request)) return request;

    NSMutableSet *kept = [NSMutableSet setWithCapacity:destinations.count];
    for (id destination in destinations) {
        if (!CPLooksCarRelated(destination)) [kept addObject:destination];
    }
    if (kept.count == destinations.count) return request;
    if (![request respondsToSelector:@selector(mutableCopyWithZone:)]) return request;

    id copy = [request mutableCopy];
    if (![copy respondsToSelector:@selector(setRequestDestinations:)]) return request;
    [copy setRequestDestinations:kept];
    CPNoteSuppressed(request, @"request destinations");
    return copy;
}

%hook NCNotificationDispatcher

- (void)addDestination:(id<CPNotificationDestination>)destination {
    if (CPIsCarDestination(destination)) CPHookCarDestinationClass([destination class]);
    %orig;
}

- (void)postNotificationWithRequest:(NCNotificationRequest *)request {
    %orig(CPRequestWithoutCarDestinations(request));
}

- (void)modifyNotificationWithRequest:(NCNotificationRequest *)request {
    %orig(CPRequestWithoutCarDestinations(request));
}

%end

#pragma mark - Part 2: Location Services

static NSUInteger gDisconnectGeneration;

static dispatch_queue_t CPLocationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.adarsh.carprivacy.location", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Persisted so a respring mid-drive doesn't forget who turned location on.
static BOOL CPWeEnabledLocation(void) {
    CFPreferencesAppSynchronize(kStateDomain);
    return CFPreferencesGetAppBooleanValue(CFSTR("weEnabledLocation"), kStateDomain, NULL);
}

static void CPSetWeEnabledLocation(BOOL value) {
    CFPreferencesSetAppValue(CFSTR("weEnabledLocation"), value ? kCFBooleanTrue : kCFBooleanFalse, kStateDomain);
    CFPreferencesAppSynchronize(kStateDomain);
}

static void CPNoteLocationAction(NSString *action) {
    CPLog(@"%@", action);
    dispatch_async(dispatch_get_main_queue(), ^{
        gLastLocationAction = action;
        CPWriteStatus();
    });
}

static void CPCarDidConnect(void) {
    gDisconnectGeneration++; // cancels a pending "turn off" from a brief drop-out
    if (!gLocationEnabled) return;

    dispatch_async(CPLocationQueue(), ^{
        if ([CLLocationManager locationServicesEnabled]) {
            CPNoteLocationAction(@"Car connected, Location Services already on: left as is");
            return;
        }
        [CLLocationManager setLocationServicesEnabled:YES];
        CPSetWeEnabledLocation(YES);
        CPNoteLocationAction(@"Car connected: turned Location Services on");
    });
}

static void CPApplyLocationOffPolicy(void) {
    CPLocationOffMode mode = gOffMode;
    BOOL featureOn = gLocationEnabled;

    dispatch_async(CPLocationQueue(), ^{
        BOOL weEnabled = CPWeEnabledLocation();
        CPSetWeEnabledLocation(NO);
        if (!featureOn) return;

        if (![CLLocationManager locationServicesEnabled]) {
            CPNoteLocationAction(@"Car disconnected, Location Services already off");
            return;
        }

        BOOL turnOff = (mode == CPLocationOffModeAlways) || (mode == CPLocationOffModeRestore && weEnabled);
        if (turnOff) {
            [CLLocationManager setLocationServicesEnabled:NO];
            CPNoteLocationAction(@"Car disconnected: turned Location Services off");
        } else {
            CPNoteLocationAction(@"Car disconnected: left Location Services on (it was on before the drive, or mode is Never)");
        }
    });
}

static void CPCarDidDisconnect(void) {
    NSUInteger generation = ++gDisconnectGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gDisconnectDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != gDisconnectGeneration || gInCar) return;
        CPApplyLocationOffPolicy();
    });
}

#pragma mark - Car detection

static void CPUpdateCarState(void) {
    BOOL inCar = gEnabled && ((gTriggerCarPlay && gCarPlayActive) || (gTriggerBluetooth && gBluetoothActive));
    if (inCar != gInCar) {
        gInCar = inCar;
        CPLog(@"Car %@ (CarPlay: %d, Bluetooth: %d %@)", inCar ? @"connected" : @"disconnected",
              gCarPlayActive, gBluetoothActive, gMatchedDevice ?: @"");
        if (inCar) CPCarDidConnect();
        else CPCarDidDisconnect();
    }
    CPWriteStatus();
}

static BOOL CPAudioRouteIsCarPlay(void) {
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortCarAudio]) return YES;
    }
    return NO;
}

static void CPRefreshCarPlay(void) {
    gCarPlayActive = gCarPlaySession || CPAudioRouteIsCarPlay();
    CPUpdateCarState();
}

static BOOL CPIsCarBluetoothDevice(BluetoothDevice *device) {
    NSString *address = [device respondsToSelector:@selector(address)] ? device.address.uppercaseString : nil;
    NSString *name = [device respondsToSelector:@selector(name)] ? device.name.lowercaseString : nil;
    return (address && [gCarAddresses containsObject:address]) || (name && [gCarNames containsObject:name]);
}

static BOOL gDetectionStarted;

// `leaving` is the device from a disconnect notification; it can still be listed
// as connected for a moment, so it is skipped explicitly.
static void CPRefreshBluetooth(BluetoothDevice *leaving) {
    if (!gDetectionStarted) return;
    BluetoothManager *manager = [NSClassFromString(@"BluetoothManager") sharedInstance];
    NSString *leavingAddress = [leaving respondsToSelector:@selector(address)] ? leaving.address : nil;

    NSString *matched = nil;
    for (BluetoothDevice *device in manager.connectedDevices) {
        if (leavingAddress && [device.address isEqualToString:leavingAddress]) continue;
        if (CPIsCarBluetoothDevice(device)) {
            matched = device.name ?: device.address;
            break;
        }
    }
    gBluetoothActive = matched != nil;
    gMatchedDevice = matched;
    CPUpdateCarState();
}

@interface CPCarPlayObserver : NSObject <CARSessionObserving>
@end

@implementation CPCarPlayObserver
- (void)sessionDidConnect:(id)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCarPlaySession = YES;
        CPRefreshCarPlay();
    });
}
- (void)sessionDidDisconnect:(id)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCarPlaySession = NO;
        CPRefreshCarPlay();
    });
}
@end

static CARSessionStatus *gSessionStatus;
static CPCarPlayObserver *gCarPlayObserver;

static void CPStartDetection(void) {
    if (gDetectionStarted) return;
    gDetectionStarted = YES;

    dlopen("/System/Library/PrivateFrameworks/CarKit.framework/CarKit", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);

    // CarPlay (wired and wireless)
    Class statusClass = NSClassFromString(@"CARSessionStatus");
    if (statusClass) {
        gSessionStatus = [statusClass new];
        gCarPlayObserver = [CPCarPlayObserver new];
        if ([gSessionStatus respondsToSelector:@selector(addSessionObserver:)]) {
            [gSessionStatus addSessionObserver:gCarPlayObserver];
        }
        if ([gSessionStatus respondsToSelector:@selector(currentSession)]) {
            gCarPlaySession = gSessionStatus.currentSession != nil;
        }
    } else {
        CPLog(@"CARSessionStatus not found; falling back to the CarPlay audio route only");
    }

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *main = NSOperationQueue.mainQueue;

    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:main usingBlock:^(NSNotification *note) {
        CPRefreshCarPlay();
    }];

    // Bluetooth
    for (NSString *name in @[@"BluetoothDeviceConnectSuccessNotification", @"BluetoothAvailabilityChangedNotification"]) {
        [center addObserverForName:name object:nil queue:main usingBlock:^(NSNotification *note) {
            CPRefreshBluetooth(nil);
        }];
    }
    [center addObserverForName:@"BluetoothDeviceDisconnectSuccessNotification" object:nil queue:main usingBlock:^(NSNotification *note) {
        CPRefreshBluetooth(note.object);
    }];
    [NSClassFromString(@"BluetoothManager") sharedInstance]; // makes BluetoothManager start posting

    CPRefreshCarPlay();
    CPRefreshBluetooth(nil);

    // If SpringBoard restarted after you left the car, finish the pending "turn off".
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gInCar && CPWeEnabledLocation()) CPApplyLocationOffPolicy();
    });
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    CPStartDetection();
}
%end

#pragma mark - Setup

static void CPPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CPReloadPrefs();
        CPRefreshBluetooth(nil); // re-runs CPUpdateCarState with the new device list
        if (!gDetectionStarted) CPUpdateCarState();
    });
}

static void CPStatusRequested(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CPWriteStatusOnMain();
}

%ctor {
    gHookedDestinations = [NSMutableOrderedSet orderedSet];
    CPReloadPrefs();

    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwin, NULL, CPPrefsChanged, kPrefsChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(darwin, NULL, CPStatusRequested, kStatusRequest, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // Known names of the CarPlay destination; anything else is caught by -addDestination:.
    for (NSString *name in @[@"SBNotificationCarDestination", @"SBNCCarDestination", @"CARNotificationDestination"]) {
        CPHookCarDestinationClass(NSClassFromString(name));
    }

    %init;
}
