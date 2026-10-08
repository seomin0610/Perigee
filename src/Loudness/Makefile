TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalLoudness
TidalLoudness_FILES = Tweak.m DSP.c
TidalLoudness_CFLAGS = -fobjc-arc -Wall
TidalLoudness_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalLoudness_CFLAGS += -D__IPHONE_OS_VERSION_MIN_REQUIRED=150000
TidalLoudness_FRAMEWORKS = Foundation AVFoundation
TidalLoudness_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
