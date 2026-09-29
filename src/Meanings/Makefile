TARGET := iphone:clang:26.5:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalMeanings
TidalMeanings_FILES = Tweak.m
TidalMeanings_CFLAGS = -fobjc-arc -Wall
TidalMeanings_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks # Xcode 26 SDKs keep some UIKit headers here; Theos' clang doesn't look there
TidalMeanings_FRAMEWORKS = UIKit MediaPlayer QuartzCore CoreGraphics WebKit SafariServices
TidalMeanings_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
