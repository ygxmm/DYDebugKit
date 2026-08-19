#
# DYDebugKit
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = Aweme

TWEAK_NAME = DYDebugKit

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
# Source
# ============================================================

DYDebugKit_FILES = \
	Entry.xm \
	DYDebugCapture.m \
	DYDebugExport.m


# ============================================================
# Compiler
# ============================================================

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


# ============================================================
# Logos
# ============================================================

DYDebugKit_LOGOS_DEFAULT_GENERATOR = internal

export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal


# ============================================================
# Tweak
# ============================================================

include $(THEOS_MAKE_PATH)/tweak.mk


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

	@if [ -d "$(THEOS_VENDOR_MODULE_PATH)/roothide" ] || \
	    [ -d "$(THEOS_MODULE_PATH)/roothide" ]; then \
		rm -rf .theos; \
		$(MAKE) all package \
			DYDEBUGKIT_PACKAGE_SCHEME=roothide \
			FINALPACKAGE=1; \
	else \
		echo ""; \
		echo "ERROR: RootHide Theos package scheme not found."; \
		echo ""; \
		echo "Install/use a Theos tree containing the roothide scheme."; \
		echo ""; \
		exit 1; \
	fi


# ============================================================
# Build all three packages
# ============================================================

all-packages::
	@rm -rf packages
	@mkdir -p packages

	@$(MAKE) package-rootful FINALPACKAGE=1

	@$(MAKE) package-rootless FINALPACKAGE=1

	@$(MAKE) package-roothide FINALPACKAGE=1


# ============================================================
# Scheme staging
# ============================================================

before-package::

ifneq ($(THEOS_PACKAGE_INSTALL_PREFIX),)

	@mkdir -p "$(_THEOS_SCHEME_STAGE)"

endif


# ============================================================
# Rename package
# ============================================================

after-package::

	@mkdir -p packages

	@DEB=$$(cat .theos/last_package 2>/dev/null || true); \
	OUT="packages/DYDebugKit_$(DY_VERSION)_$(DYDEBUGKIT_PACKAGE_SUFFIX).deb"; \
	if [ -n "$$DEB" ] && [ -f "$$DEB" ]; then \
		mv -f "$$DEB" "$$OUT"; \
	fi

	@echo ""
	@echo "================================"
	@echo "Package generated"
	@echo "================================"
	@echo "packages/DYDebugKit_$(DY_VERSION)_$(DYDEBUGKIT_PACKAGE_SUFFIX).deb"
	@echo ""