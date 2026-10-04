TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalLiquidTab
TidalLiquidTab_FILES = Tweak.m
TidalLiquidTab_CFLAGS = -fobjc-arc -Wall
TidalLiquidTab_CFLAGS += -Wno-unguarded-availability-new
TidalLiquidTab_CFLAGS += -F$(SYSROOT)/System/Library/SubFrameworks
TidalLiquidTab_FRAMEWORKS = UIKit QuartzCore CoreGraphics
TidalLiquidTab_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
