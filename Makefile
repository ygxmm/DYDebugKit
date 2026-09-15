TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ============================================================
# Tweak
# ============================================================
TWEAK_NAME = DYDebugKit
DYDebugKit_FILES = Entry.xm DYDebugCapture.m DYDebugExport.m DKClassDump.m DKZipWriter.m
DYDebugKit_CFLAGS = -fobjc-arc
DYDebugKit_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
DYDebugKit_LIBRARIES = z

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# PreferenceBundle
# ============================================================
BUNDLE_NAME = DYDebugKitPrefs
DYDebugKitPrefs_FILES = DYDebugKitPrefs/RootListController.m
DYDebugKitPrefs_FRAMEWORKS = UIKit Foundation
DYDebugKitPrefs_PRIVATE_FRAMEWORKS = Preferences
DYDebugKitPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk