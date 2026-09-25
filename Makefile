export LOGOS_DEFAULT_GENERATOR = internal

# fleXD is written against the iOS 26 SDK. Xcode carries that SDK, but Theos only looks in its
# own directory, so it is linked in here rather than in the workflow: .github is hidden in Finder.
SDK_LINK := $(shell \
    if command -v xcrun >/dev/null 2>&1; then \
        mkdir -p "$(THEOS)/sdks"; \
        ln -sfn "$$(xcrun --sdk iphoneos --show-sdk-path)" \
                "$(THEOS)/sdks/iPhoneOS$$(xcrun --sdk iphoneos --show-sdk-version).sdk"; \
    fi 2>&1)

# latest picks the newest SDK Theos can see; the deployment target stays 16.0.
TARGET := iphone:clang:latest:16.0
$(info SDK link: $(if $(SDK_LINK),$(SDK_LINK),done))
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
FLEXD_FILES := $(shell find $(FLEXD_DIR)/Classes \( -name '*.m' -o -name '*.mm' \) -not -path '*/Headers/*')
FLEXD_INCLUDES := $(addprefix -I,$(shell find $(FLEXD_DIR)/Classes -type d -not -path '*/Headers*'))

$(TWEAK_NAME)_FILES = $(shell find src -name '*.x' -o -name '*.xm' -o -name '*.m' -o -name '*.c') $(FLEXD_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Isrc -Isrc/Debug -Isrc/Features -Isrc/Settings $(FLEXD_INCLUDES) \
                       -DPD_FLEX_SOURCES=$(words $(FLEXD_FILES)) -Wno-module-import-in-extern-c -Wno-error \
                       -Wno-deprecated-declarations -Wno-strict-prototypes -Wno-unsupported-availability-guard \
                       -Wno-unused-function -Wno-nullability-completeness -Wno-unused-property-ivar
$(TWEAK_NAME)_CXXFLAGS = -std=gnu++11 -Wno-error
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics ImageIO QuartzCore WebKit Security SceneKit QuickLook
$(TWEAK_NAME)_LIBRARIES = z sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
