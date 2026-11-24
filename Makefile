TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GPSHUD

GPSHUD_FILES = Tweak.xm
GPSHUD_FRAMEWORKS = CoreLocation UIKit QuartzCore
GPSHUD_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
