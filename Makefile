TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DYDebugKit
DYDebugKit_FILES = src/Entry.xm src/Debug/DYDebugCapture.m src/Debug/DYDebugExport.m
DYDebugKit_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
DYDebugKit_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
DYDebugKit_LDFLAGS += -lz

include $(THEOS_MAKE_PATH)/tweak.mk
