// Lists paired Bluetooth devices so you can mark which ones are your car.
// Selected devices are stored by Bluetooth address under "carDevices".

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>
#import <notify.h>

#define kPrefsDomain  CFSTR("com.adarsh.carprivacy")
#define kPrefsChanged "com.adarsh.carprivacy/prefsChanged"

@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (NSArray<BluetoothDevice *> *)pairedDevices;
@end

@interface CPDevicePickerController : PSListController
@end

@implementation CPDevicePickerController

- (instancetype)init {
    if ((self = [super init])) {
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        // Paired devices can show up a moment after BluetoothManager starts.
        for (NSString *name in @[@"BluetoothAvailabilityChangedNotification", @"BluetoothDeviceConnectSuccessNotification"]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadSpecifiers) name:name object:nil];
        }
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)title {
    return @"Car Bluetooth Devices";
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];

        BluetoothManager *manager = [NSClassFromString(@"BluetoothManager") sharedInstance];
        NSArray *devices = [manager respondsToSelector:@selector(pairedDevices)] ? manager.pairedDevices : @[];
        devices = [devices sortedArrayUsingComparator:^NSComparisonResult(BluetoothDevice *a, BluetoothDevice *b) {
            return [a.name ?: @"" localizedCaseInsensitiveCompare:b.name ?: @""];
        }];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"Paired Devices"];
        [group setProperty:(devices.count
                            ? @"Turn on every device that belongs to your car. If your car uses CarPlay, \"Detect CarPlay\" already covers it."
                            : @"No paired devices found. Turn Bluetooth on and come back, or type your car's name on the previous page.")
                    forKey:@"footerText"];
        [specifiers addObject:group];

        for (BluetoothDevice *device in devices) {
            NSString *address = device.address.uppercaseString;
            if (!address.length) continue;
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:device.name ?: address
                                                              target:self
                                                                 set:@selector(setCarDevice:specifier:)
                                                                 get:@selector(isCarDevice:)
                                                              detail:nil
                                                                cell:PSSwitchCell
                                                                edit:nil];
            [row setProperty:address forKey:@"address"];
            [specifiers addObject:row];
        }

        _specifiers = specifiers;
    }
    return _specifiers;
}

- (NSMutableArray<NSString *> *)savedAddresses {
    id saved = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("carDevices"), kPrefsDomain));
    return [saved isKindOfClass:NSArray.class] ? [saved mutableCopy] : [NSMutableArray array];
}

- (id)isCarDevice:(PSSpecifier *)specifier {
    return @([[self savedAddresses] containsObject:[specifier propertyForKey:@"address"]]);
}

- (void)setCarDevice:(id)value specifier:(PSSpecifier *)specifier {
    NSString *address = [specifier propertyForKey:@"address"];
    NSMutableArray *addresses = [self savedAddresses];
    [addresses removeObject:address];
    if ([value boolValue]) [addresses addObject:address];

    CFPreferencesSetAppValue(CFSTR("carDevices"), (__bridge CFArrayRef)addresses, kPrefsDomain);
    CFPreferencesAppSynchronize(kPrefsDomain);
    notify_post(kPrefsChanged);
}

@end
