TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = TendiesPrefs
TendiesPrefs_FILES = TendiesPrefsRootListController.m
TendiesPrefs_FRAMEWORKS = UIKit
# 必须链接 Foundation 以避免某些符号找不到
TendiesPrefs_PRIVATE_FRAMEWORKS = Preferences Bom
TendiesPrefs_INSTALL_PATH = /Library/PreferenceBundles
TendiesPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
