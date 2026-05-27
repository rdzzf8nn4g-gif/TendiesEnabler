DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.0.0

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
# 必须同时注入 SpringBoard (iOS 14-15 渲染) 和 PosterBoard (iOS 16-17 渲染)
INSTALL_TARGET_PROCESSES = SpringBoard PosterBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TendiesEnabler
TendiesEnabler_FILES = Tweak.x
TendiesEnabler_CFLAGS = -fobjc-arc
TendiesEnabler_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation
TendiesEnabler_PRIVATE_FRAMEWORKS = SpringBoardFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += tendiesprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
