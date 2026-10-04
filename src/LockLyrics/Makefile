TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalLockLyrics
TidalLockLyrics_FILES = Tweak.m Art.m Settings.m
TidalLockLyrics_CFLAGS = -fobjc-arc -Wall
TidalLockLyrics_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalLockLyrics_FRAMEWORKS = UIKit MediaPlayer QuartzCore AVFoundation CoreMedia CoreGraphics
TidalLockLyrics_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
