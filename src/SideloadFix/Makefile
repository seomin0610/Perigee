TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalSideloadFix
TidalSideloadFix_FILES = Tweak.m
TidalSideloadFix_CFLAGS = -fobjc-arc -Wall
TidalSideloadFix_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalSideloadFix_FRAMEWORKS = Foundation Security
TidalSideloadFix_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
