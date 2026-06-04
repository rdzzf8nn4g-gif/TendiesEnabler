TARGET := iphone:clang:latest:14.0
# 如果你是 Rootless 越狱，这里保持你原有的架构设置，例如 ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ZoneCC
$(BUNDLE_NAME)_BUNDLE_EXTENSION = bundle
$(BUNDLE_NAME)_FILES = ZoneCCModule.m
$(BUNDLE_NAME)_PRIVATE_FRAMEWORKS = ControlCenterUIKit
$(BUNDLE_NAME)_INSTALL_PATH = /Library/ControlCenter/Bundles
# Rootless 环境下会自动转译到 /var/jb/Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk
