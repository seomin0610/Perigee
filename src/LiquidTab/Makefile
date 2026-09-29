TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalLiquidTab
TidalLiquidTab_FILES = Tweak.m
TidalLiquidTab_CFLAGS = -fobjc-arc -Wall
TidalLiquidTab_CFLAGS += -Wno-unguarded-availability-new # iOS 18/26 UIKit throughout; LTInit stays out below iOS 26
TidalLiquidTab_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks # Xcode 26 SDKs keep some UIKit headers here; Theos' clang doesn't look there
TidalLiquidTab_FRAMEWORKS = UIKit QuartzCore CoreGraphics
TidalLiquidTab_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
