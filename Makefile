DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 1.0.0

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TendiesEnabler
TendiesEnabler_FILES = Tweak.x
TendiesEnabler_CFLAGS = -fobjc-arc
TendiesEnabler_FRAMEWORKS = Foundation UIKit
# 必须加上这行以支持系统原生的 SQLite3 数据库操作
TendiesEnabler_LDFLAGS = -lsqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += tendiesprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
