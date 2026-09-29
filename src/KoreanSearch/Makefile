TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalKoreanSearch
TidalKoreanSearch_FILES = Tweak.m KSResolve.m KSMatch.m
TidalKoreanSearch_CFLAGS = -fobjc-arc -Wall
TidalKoreanSearch_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks # Xcode 26 SDKs keep some UIKit headers here; Theos' clang doesn't look there
TidalKoreanSearch_FRAMEWORKS = Foundation
TidalKoreanSearch_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
