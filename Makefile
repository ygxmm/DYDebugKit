#
# DYDebugKit
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# ============================================================
# 读 control 里的 Version
# ============================================================
DY_VERSION := $(shell awk -F': *' '$$1 == "Version" { print $$2; exit }' control)
DYDEBUGKIT_PACKAGE_SCHEME ?= $(if $(THEOS_PACKAGE_SCHEME),$(THEOS_PACKAGE_SCHEME),rootful)

ifeq ($(strip $(DY_VERSION)),)
$(error Missing Version in control)
endif

# ============================================================
# Package Scheme
# ============================================================
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

# ============================================================
# Theos
# ============================================================
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

DYDebugKit_CFLAGS = \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -Wno-unused-function

DYDebugKit_FRAMEWORKS = \
    UIKit \
    Foundation \
    QuartzCore \
    CoreGraphics

DYDebugKit_LIBRARIES = z

include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# PreferenceBundle
# ============================================================
BUNDLE_NAME = DYDebugKitPrefs

DYDebugKitPrefs_FILES = \
    DYDebugPrefs/RootListController.m

DYDebugKitPrefs_FRAMEWORKS = \
    UIKit \
    Foundation

DYDebugKitPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

DYDebugKitPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

# ============================================================
# 关键：把 Info.plist 和入口 plist 都 stage 进去
#
# 无论什么 scheme，两种路径都拷贝一份：
#   - /Library/...          给 rootful 用
#   - /var/jb/Library/...   给 rootless / roothide 用
# 多出的路径是空目录，不会有副作用。
# ============================================================
after-stage::
	@echo ">>> Stage PreferenceBundle Info.plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/DYDebugKitPrefs.bundle"
	@mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceBundles/DYDebugKitPrefs.bundle"
	@cp -f "DYDebugPrefs/Info.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/DYDebugKitPrefs.bundle/Info.plist"
	@cp -f "DYDebugPrefs/Info.plist" \
	    "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceBundles/DYDebugKitPrefs.bundle/Info.plist"

	@echo ">>> Stage PreferenceLoader entry plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@mkdir -p "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences"
	@cp -f "DYDebugPrefs/DYDebugKit.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DYDebugKit.plist"
	@cp -f "DYDebugPrefs/DYDebugKit.plist" \
	    "$(THEOS_STAGING_DIR)/var/jb/Library/PreferenceLoader/Preferences/DYDebugKit.plist"

# ============================================================
# Logos
# ============================================================
DYDEBUGKIT_LOGOS_DEFAULT_GENERATOR = internal
export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

# ============================================================
# Clean
# ============================================================
clean::
	@rm -rf .theos packages

# ============================================================
# Rootful
# ============================================================
package-rootful::
	@echo "================================"
	@echo "Building DYDebugKit Rootful"
	@echo "================================"
	@rm -rf .theos
	@$(MAKE) all package \
		DYDEBUGKIT_PACKAGE_SCHEME=rootful \
		FINALPACKAGE=1

# ============================================================
# Rootless
# ============================================================
package-rootless::
	@echo "================================"
	@echo "Building DYDebugKit Rootless"
	@echo "================================"
	@rm -rf .theos
	@$(MAKE) all package \
		DYDEBUGKIT_PACKAGE_SCHEME=rootless \
		FINALPACKAGE=1

# ============================================================
# RootHide
# ============================================================
package-roothide::
	@echo "================================"
	@echo "Building DYDebugKit RootHide"
	@echo "================================"
	@rm -rf .theos
	@$(MAKE) all package \
		DYDEBUGKIT_PACKAGE_SCHEME=roothide \
		FINALPACKAGE=1