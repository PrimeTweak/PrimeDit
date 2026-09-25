export LOGOS_DEFAULT_GENERATOR = internal

TARGET := iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = RedditApp Reddit

ARCHS = arm64

ifeq ($(SIDELOADED),1)
  export MODULES = jailed
  CODESIGN_IPA = 0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PrimeDit

# fleXD (FLEX explorer), pinned and fetched into vendor/ at build time; vendor/ is ignored by git.
FLEXD_VERSION = 6.1.0
FLEXD_DIR = vendor/fleXD
$(shell [ -d $(FLEXD_DIR)/Classes ] || git clone --quiet --depth 1 --branch $(FLEXD_VERSION) \
  https://github.com/TimOliver/fleXD.git $(FLEXD_DIR))
FLEXD_FILES := $(shell find $(FLEXD_DIR)/Classes -path $(FLEXD_DIR)/Classes/Headers -prune -o \
  \( -name '*.m' -o -name '*.mm' -o -name '*.c' \) -print)
FLEXD_INCLUDES := $(addprefix -I,$(shell find $(FLEXD_DIR)/Classes -path $(FLEXD_DIR)/Classes/Headers -prune -o \
  -type d -print))

$(TWEAK_NAME)_FILES = $(shell find src -name '*.x' -o -name '*.xm' -o -name '*.m' -o -name '*.c') $(FLEXD_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Isrc -Isrc/Debug -Isrc/Features -Isrc/Settings $(FLEXD_INCLUDES) \
                       -DPD_FLEX_SOURCES=$(words $(FLEXD_FILES)) -Wno-module-import-in-extern-c -Wno-error \
                       -Wno-deprecated-declarations -Wno-strict-prototypes -Wno-unsupported-availability-guard
$(TWEAK_NAME)_FRAMEWORKS = Security UIKit CoreGraphics ImageIO QuartzCore WebKit SceneKit QuickLook
$(TWEAK_NAME)_LIBRARIES = z sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
