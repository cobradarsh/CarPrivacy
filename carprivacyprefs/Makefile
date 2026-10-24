TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CarPrivacyPrefs

CarPrivacyPrefs_FILES = CPRootListController.m CPDevicePickerController.m
CarPrivacyPrefs_FRAMEWORKS = UIKit CoreLocation
CarPrivacyPrefs_PRIVATE_FRAMEWORKS = Preferences
CarPrivacyPrefs_INSTALL_PATH = /Library/PreferenceBundles
CarPrivacyPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CarPrivacyPrefs_LDFLAGS = -lroothide

include $(THEOS_MAKE_PATH)/bundle.mk
