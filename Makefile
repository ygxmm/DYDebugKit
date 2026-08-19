#
# DYDebugKit
#

TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = Aweme

DY_VERSION := $(shell awk -F': *' '$$1 == "Version" { print $$2; exit }' control)

DY_PACKAGE_SCHEME ?= $(if $(THEOS_PACKAGE_SCHEME),$(THEOS_PACKAGE_SCHEME),rootful)

ifeq ($(strip,$(DY_VERSION)),)
$(error Missing Version in control)
endif

ifeq ($(DY_PACKAGE_SCHEME),rootful)

unexport THEOS_PACKAGE_SCHEME
DY_PACKAGE_SUFFIX = arm-rootful

else ifeq ($(DY_PACKAGE_SCHEME),rootless)

export THEOS_PACKAGE_SCHEME = rootless
DY_PACKAGE_SUFFIX = arm64-rootless

else ifeq ($(DY_PACKAGE_SCHEME),roothide)

export THEOS_PACKAGE_SCHEME = roothide
DY_PACKAGE_SUFFIX = arm64e-roothide

else

$(error Unsupported DY_PACKAGE_SCHEME: $(DY_PACKAGE_SCHEME))

endif


include $(THEOS)/makefiles/common.mk


TWEAK_NAME = DYDebugKit

DYDebugKit_FILES = Entry.xm \
                    DYDebugCapture.m \
                    DYDebugExport.m

DYDebugKit_CFLAGS = -fobjc-arc \
                    -Wall \
                    -Wextra \
                    -Wno-unused-parameter \
                    -Wno-unused-function

DYDebugKit_FRAMEWORKS = UIKit \
                         Foundation \
                         QuartzCore \
                         CoreGraphics


export THEOS_STRICT_LOGOS = 0
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal


include $(THEOS_MAKE_PATH)/tweak.mk


clean::
	@rm -rf .theos packages


package-rootful::
	@rm -rf .theos
	@$(MAKE) all package \
		DY_PACKAGE_SCHEME=rootful \
		FINALPACKAGE=1


package-rootless::
	@rm -rf .theos
	@$(MAKE) all package \
		DY_PACKAGE_SCHEME=rootless \
		FINALPACKAGE=1


package-roothide::
	@if [ -d "$(THEOS_VENDOR_MODULE_PATH)/roothide" ] || \
	    [ -d "$(THEOS_MODULE_PATH)/roothide" ]; then \
		rm -rf .theos; \
		$(MAKE) all package \
			DY_PACKAGE_SCHEME=roothide \
			FINALPACKAGE=1; \
	elif [ "$$GITHUB_ACTIONS" = "true" ]; then \
		echo "error: roothide Theos package scheme is required in CI."; \
		exit 1; \
	else \
		echo "warning: roothide Theos package scheme not found; skipped roothide package."; \
	fi


all-packages::
	@rm -rf packages
	@mkdir -p packages

	@$(MAKE) package-rootful FINALPACKAGE=1

	@$(MAKE) package-rootless FINALPACKAGE=1

	@$(MAKE) package-roothide FINALPACKAGE=1


before-package::
ifneq ($(THEOS_PACKAGE_INSTALL_PREFIX),)
	@mkdir -p "$(_THEOS_SCHEME_STAGE)"
endif


after-package::
	@mkdir -p packages

	@DEB=$$(cat .theos/last_package 2>/dev/null || true); \
	OUT="packages/DYDebugKit_$(DY_VERSION)_$(DY_PACKAGE_SUFFIX).deb"; \
	if [ -n "$$DEB" ] && [ -f "$$DEB" ]; then \
		mv -f "$$DEB" "$$OUT"; \
	fi

	@echo "==> 成品: packages/DYDebugKit_$(DY_VERSION)_$(DY_PACKAGE_SUFFIX).deb"