TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# roothide build — requires the roothide fork of Theos (github.com/roothide/theos)
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CarPrivacy

CarPrivacy_FILES = Tweak.x
CarPrivacy_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CarPrivacy_FRAMEWORKS = UIKit CoreLocation AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += carprivacyprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
