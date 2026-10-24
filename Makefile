#
# tzyhb
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

DY_VERSION := $(shell awk -F': *' '$$1 == "Version" { print $$2; exit }' control)
TZYHB_PACKAGE_SCHEME ?= $(if $(THEOS_PACKAGE_SCHEME),$(THEOS_PACKAGE_SCHEME),rootful)

ifeq ($(strip $(DY_VERSION)),)
$(error Missing Version in control)
endif

ifeq ($(TZYHB_PACKAGE_SCHEME),rootful)
unexport THEOS_PACKAGE_SCHEME
else ifeq ($(TZYHB_PACKAGE_SCHEME),rootless)
export THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(TZYHB_PACKAGE_SCHEME),roothide)
export THEOS_PACKAGE_SCHEME = roothide
else
$(error Unsupported TZYHB_PACKAGE_SCHEME: $(TZYHB_PACKAGE_SCHEME))
endif

include $(THEOS)/makefiles/common.mk

# ============================================================
# Tweak
# ============================================================
TWEAK_NAME = tzyhb
CD_CORE_FILES = $(wildcard classdump-core/Core/*.m) $(wildcard classdump-core/Cursors/*.m)
CD_CORE_FILES += $(wildcard classdump-core/Extensions/*.m) $(wildcard classdump-core/Extras/*.m)
CD_CORE_FILES += $(wildcard classdump-core/FileManagement/*.m) $(wildcard classdump-core/LoadCommands/*.m)
CD_CORE_FILES += $(wildcard classdump-core/OC/*.m) $(wildcard classdump-core/ObjC/*.m)
CD_CORE_FILES += $(wildcard classdump-core/Structure/*.m) $(wildcard classdump-core/Type/*.m)
CD_CORE_FILES += $(wildcard classdump-core/Visitors/*.m)
CD_CORE_FILES += $(filter-out classdump-core/Extras/blowfish.c,$(wildcard classdump-core/Extras/*.c))
CD_CORE_FILES += $(wildcard classdump-core/Core/*.m)
CD_CORE_FILES += $(wildcard classdump-core/Extensions/*.mm)
CD_CORE_FILES += DKStaticClassDump.m
tzyhb_FILES = Entry.xm DKDebugCapture.m DKDebugExport.m DKClassDump.m DKZipWriter.m DKAudioProbe.m $(CD_CORE_FILES)
tzyhb_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unknown-warning-option -Wno-unused-parameter -Wno-unused-function
tzyhb_CFLAGS += -Iclassdump-core -include classdump-core/class-dump-Prefix.pch
tzyhb_CFLAGS += -Iclassdump-core/Core -Iclassdump-core/Cursors -Iclassdump-core/Extensions
tzyhb_CFLAGS += -Iclassdump-core/Extras -Iclassdump-core/FileManagement -Iclassdump-core/LoadCommands
tzyhb_CFLAGS += -Iclassdump-core/OC -Iclassdump-core/ObjC -Iclassdump-core/Structure
tzyhb_CFLAGS += -Iclassdump-core/Type -Iclassdump-core/Visitors
# classdump-core 是 2019 年的代码，新 clang 会报很多旧式写法警告
# 只对 classdump-core 相关的警告关闭 -Werror，不影响 tzyhb 自己的代码
tzyhb_CFLAGS += -Wno-error=semicolon-before-method-body
tzyhb_CFLAGS += -Wno-error=deprecated-declarations
tzyhb_CFLAGS += -Wno-error=comma
tzyhb_CFLAGS += -Wno-error=implicit-function-declaration
tzyhb_CFLAGS += -Wno-error=incompatible-pointer-types
tzyhb_CFLAGS += -Wno-error=unused-variable
tzyhb_CFLAGS += -Wno-error=unused-but-set-variable
tzyhb_CFLAGS += -Wno-error=return-type
tzyhb_CFLAGS += -Wno-error=format
tzyhb_CFLAGS += -Wno-error=pointer-sign
tzyhb_CFLAGS += -Wno-error=shadow
tzyhb_CFLAGS += -Wno-error=missing-braces
tzyhb_CFLAGS += -Wno-error=nullability-completeness
tzyhb_CFLAGS += -Wno-error=objc-method-access
tzyhb_CFLAGS += -Wno-error=int-conversion
tzyhb_CFLAGS += -Wno-error=enum-conversion
tzyhb_CFLAGS += -Wno-error=incompatible-property-type
tzyhb_CFLAGS += -Wno-error=direct-ivar-access
tzyhb_CFLAGS += -Wno-error=objc-root-class
tzyhb_CFLAGS += -Wno-error=sign-compare
tzyhb_CFLAGS += -Wno-error=vla-cxx-extension
tzyhb_CFLAGS += -Wno-error=unused-but-set-variable
tzyhb_CFLAGS += -Wno-error=deprecated-declarations
tzyhb_CFLAGS += -Wno-error=tautological-compare
tzyhb_CFLAGS += -Wno-error=unreachable-code
tzyhb_CFLAGS += -Wno-error=unused-result
tzyhb_CFLAGS += -Wno-error=switch
tzyhb_CFLAGS += -Wno-error=objc-protocol-method-implementation
tzyhb_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
tzyhb_LIBRARIES = z
include $(THEOS_MAKE_PATH)/tweak.mk

# ============================================================
# PreferenceBundle
# ============================================================
BUNDLE_NAME = tzyhbPrefs
tzyhbPrefs_FILES = $(wildcard tzyhbPrefs/*.m)
tzyhbPrefs_FRAMEWORKS = UIKit Foundation
tzyhbPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
tzyhbPrefs_INSTALL_PATH = /Library/PreferenceBundles
tzyhbPrefs_RESOURCE_DIRS = tzyhbPrefs/Resources

include $(THEOS_MAKE_PATH)/bundle.mk

# ============================================================
# 关键：Stage 入口 plist (参考 AppData/Choicy 的 internal-stage)
# ============================================================
internal-stage::
	@echo ">>> Stage PreferenceLoader entry plist"
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"
	@cp -f "layout/Library/PreferenceLoader/Preferences/tzyhb.plist" \
	    "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/tzyhb.plist"

# ============================================================
export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

# ============================================================
clean::
	@rm -rf .theos packages

package-rootful::
	@rm -rf .theos
	@$(MAKE) all package TZYHB_PACKAGE_SCHEME=rootful FINALPACKAGE=1

package-rootless::
	@rm -rf .theos
	@$(MAKE) all package TZYHB_PACKAGE_SCHEME=rootless FINALPACKAGE=1

package-roothide::
	@rm -rf .theos
	@$(MAKE) all package TZYHB_PACKAGE_SCHEME=roothide FINALPACKAGE=1