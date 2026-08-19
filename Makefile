TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYDebugKit

DYDebugKit_FILES = Entry.xm \
                   DYDebugCapture.m \
                   DYDebugExport.m

DYDebugKit_CFLAGS = -fobjc-arc -Wall -Wextra
DYDebugKit_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk