TARGET := iphone:clang:26.5:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalCore
TidalCore_FILES = Tweak.m
TidalCore_CFLAGS = -fobjc-arc -Wall
TidalCore_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks # Xcode 26 SDKs keep some UIKit headers here; Theos' clang doesn't look there
ifdef TT_BUILD
TidalCore_CFLAGS += -DTT_BUILD='@"$(TT_BUILD)"'
endif
TidalCore_FRAMEWORKS = UIKit
TidalCore_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
