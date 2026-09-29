TARGET := iphone:clang:26.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TidalPrivacy
TidalPrivacy_FILES = Tweak.m
TidalPrivacy_CFLAGS = -fobjc-arc -Wall
TidalPrivacy_FRAMEWORKS = Foundation
TidalPrivacy_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk
