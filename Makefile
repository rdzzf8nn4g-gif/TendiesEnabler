DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 0.0.1

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Zone
Zone_FILES = Tweak.x
Zone_CFLAGS = -fobjc-arc
Zone_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += zoneprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
