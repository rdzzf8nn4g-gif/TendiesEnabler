TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ZonePrefs
ZonePrefs_FILES = ZonePrefsRootListController.m
# 【修改这里】：追加了 AVFoundation 和 PhotosUI
ZonePrefs_FRAMEWORKS = UIKit Foundation AVFoundation PhotosUI
ZonePrefs_PRIVATE_FRAMEWORKS = Preferences
ZonePrefs_INSTALL_PATH = /Library/PreferenceBundles
ZonePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
