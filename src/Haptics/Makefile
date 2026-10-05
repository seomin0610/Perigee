TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalHaptics
TidalHaptics_FILES = Tweak.m Analyze.c
TidalHaptics_CFLAGS = -fobjc-arc -Wall
TidalHaptics_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalHaptics_CFLAGS += -D__IPHONE_OS_VERSION_MIN_REQUIRED=150000
TidalHaptics_FRAMEWORKS = UIKit MediaPlayer QuartzCore AVFoundation CoreMedia CoreHaptics
TidalHaptics_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
