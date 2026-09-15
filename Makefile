#
# DYDebugKit
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

DY_VERSION := $(shell awk -F': *' '$$1 == "Version" { print $$2; exit }' control)
DYDEBUGKIT_PACKAGE_SCHEME ?= $(if $(THEOS_PACKAGE_SCHEME),$(THEOS_PACKAGE_SCHEME),rootful)

ifeq ($(strip $(DY_VERSION)),)
$(error Missing Version in control)
endif

ifeq ($(DYDEBUGKIT_PACKAGE_SCHEME),rootful)
unexport THEOS_PACKAGE_SCHEME
DYDEBUGKIT_PACKAGE_SUFFIX = arm-rootful
else ifeq ($(DYDEBUGKIT_PACKAGE_SCHEME),rootless)
export THEOS_PACKAGE_SCHEME = rootless
DYDEBUGKIT_PACKAGE_SUFFIX = arm64-rootless
else ifeq ($(DYDEBUGKIT_PACKAGE_SCHEME),roothide)
export THEOS_PACKAGE_SCHEME = roothide
DYDEBUGKIT_PACKAGE_SUFFIX = arm64e-roothide
else
$(error Unsupported DYDEBUGKIT_PACKAGE_SCHEME: $(DYDEBUGKIT_PACKAGE_SCHEME))
endif

include $(THEOS)/makefiles/common.mk

# ============================================================
# Tweak
# ============================================================
TWEAK_NAME = DYDebugKit

DYDebugKit_FILES = \
    Entry.xm \
    DYDebugCapture.m \
    DYDebugExport.m \
    DKClassDump.m \
    DKZipWriter.m

DYDebugKit_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-unused-function
DYDebugKit_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
DYDebugKit_LIBRARIES = z

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# PreferenceBundle
# ============================================================
BUNDLE_NAME = DYDebugKitPrefs

DYDebugKitPrefs_FILES = \
    DYDebugKitPrefs/RootListController.m

DYDebugKitPrefs_FRAMEWORKS = UIKit Foundation

DYDebugKitPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

# ★ 关键 1：把 Info.plist 作为 bundle 资源打进去
DYDebugKitPrefs_RESOURCE_FILES = \
    DYDebugKitPrefs/Info.plist

DYDebugKitPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

# ============================================================
# ★ 关键 2：只 stage PreferenceLoader 入口 plist
#   bundle 内部的 Info.plist 由上面的 _RESOURCE_FILES 处理
# ============================================================
after-stage::
	@echo ">>> Stage PreferenceLoader entry plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences"
	@cp -f "DYDebugKitPrefs/DYDebugKit.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DYDebugKit.plist"
	@cp -f "DYDebugKitPrefs/DYDebugKit.plist" \
	    "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences/DYDebugKit.plist"

# ============================================================
DYDEBUGKIT_LOGOS_DEFAULT_GENERATOR = internal
export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

clean::
	@rm -rf .theos packages

package-rootful::
	@rm -rf .theos
	@$(MAKE) all package DYDEBUGKIT_PACKAGE_SCHEME=rootful FINALPACKAGE=1

package-rootless::
	@rm -rf .theos
	@$(MAKE) all package DYDEBUGKIT_PACKAGE_SCHEME=rootless FINALPACKAGE=1

package-roothide::
	@rm -rf .theos
	@$(MAKE) all package DYDEBUGKIT_PACKAGE_SCHEME=roothide FINALPACKAGE=1