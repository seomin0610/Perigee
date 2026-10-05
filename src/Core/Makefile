TARGET := iphone:clang:26.5:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalCore
TidalCore_FILES = Tweak.m
TidalCore_CFLAGS = -fobjc-arc -Wall
TidalCore_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalCore_CFLAGS += -D__IPHONE_OS_VERSION_MIN_REQUIRED=160000
ifdef TT_BUILD
TidalCore_CFLAGS += -DTT_BUILD='@"$(TT_BUILD)"'
endif
TidalCore_FRAMEWORKS = UIKit OSLog CoreGraphics WebKit Security
TidalCore_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
