TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalOffline
TidalOffline_FILES = Tweak.m
TidalOffline_CFLAGS = -fobjc-arc -Wall
TidalOffline_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalOffline_CFLAGS += -D__IPHONE_OS_VERSION_MIN_REQUIRED=150000
TidalOffline_FRAMEWORKS = UIKit AVFoundation CoreMedia
TidalOffline_LIBRARIES = sqlite3
TidalOffline_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
