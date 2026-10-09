TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalKaraoke
TidalKaraoke_FILES = Tweak.m Score.m DSP.c
TidalKaraoke_CFLAGS = -fobjc-arc -Wall
TidalKaraoke_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalKaraoke_CFLAGS += -D__IPHONE_OS_VERSION_MIN_REQUIRED=150000
TidalKaraoke_FRAMEWORKS = Foundation AudioToolbox AVFoundation CoreGraphics CoreMedia QuartzCore MediaPlayer UIKit
TidalKaraoke_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
