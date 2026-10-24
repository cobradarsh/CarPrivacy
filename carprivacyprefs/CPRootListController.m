#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>
#import <notify.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) (path)
#endif

#define kStateDomain   CFSTR("com.adarsh.carprivacy.state")
#define kStatusRequest "com.adarsh.carprivacy/statusRequest"

@interface CPRootListController : PSListController
@end

@implementation CPRootListController

+ (void)initialize {
    if (self != CPRootListController.class) return;
    // AltList provides the app picker; load it before Root.plist names its controller.
    dlopen(jbroot("/Library/Frameworks/AltList.framework/AltList"), RTLD_NOW);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)showStatus {
    notify_post(kStatusRequest);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CFPreferencesAppSynchronize(kStateDomain);
        NSDictionary *status = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("status"), kStateDomain));

        NSString *message;
        if (![status isKindOfClass:NSDictionary.class]) {
            message = @"No status from SpringBoard yet. Make sure CarPrivacy is installed and tweak injection is on, then respring.";
        } else {
            NSArray *hooked = status[@"hookedDestinations"];
            NSString *(^yesNo)(NSString *) = ^NSString *(NSString *key) { return [status[key] boolValue] ? @"Yes" : @"No"; };
            message = [NSString stringWithFormat:
                @"In car: %@\nCarPlay connected: %@\nCar Bluetooth connected: %@ %@\n"
                @"Location Services on: %@\n\nLast location action:\n%@\n\n"
                @"CarPlay destinations hooked:\n%@\n\nLast hidden notification:\n%@\n\n"
                @"Last notification destinations (debug):\n%@\n\nUpdated: %@",
                yesNo(@"inCar"), yesNo(@"carPlayActive"), yesNo(@"bluetoothActive"), status[@"matchedDevice"] ?: @"",
                [CLLocationManager locationServicesEnabled] ? @"Yes" : @"No",
                status[@"lastLocationAction"] ?: @"-",
                hooked.count ? [hooked componentsJoinedByString:@", "] : @"none yet (normal until CarPlay connects)",
                [status[@"lastSuppressed"] length] ? status[@"lastSuppressed"] : @"-",
                [status[@"lastDestinations"] length] ? status[@"lastDestinations"] : @"-",
                status[@"updated"] ?: @"-"];
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CarPrivacy Status"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = message;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end
