export LOGOS_DEFAULT_GENERATOR = internal

# fleXD 6.1.0 needs the iOS 26 SDK. Xcode carries it, but Theos only looks
# in its own sdks directory, so it is linked there from this file, which
# always travels with the sources.
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

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PrimeDit

# fleXD (FLEX explorer), pinned and fetched into vendor/ at build time; vendor/ is ignored by git.
FLEXD_VERSION = 6.1.0
FLEXD_DIR = vendor/fleXD
$(shell [ -d $(FLEXD_DIR)/Classes ] || git clone --quiet --depth 1 --branch $(FLEXD_VERSION) \
  https://github.com/TimOliver/fleXD.git $(FLEXD_DIR))
FLEXD_FILES := $(shell find $(FLEXD_DIR)/Classes \( -name '*.m' -o -name '*.mm' \) -not -path '*/Headers/*')
FLEXD_INCLUDES := $(addprefix -I,$(shell find $(FLEXD_DIR)/Classes -type d -not -path '*/Headers*'))

# fishhook, pinned by commit and fetched into vendor/ at build time.
FISHHOOK_COMMIT = aadc161ac3b80db07a9908851839a17ba63a9eb1
FISHHOOK_DIR = vendor/fishhook
$(shell [ -f $(FISHHOOK_DIR)/fishhook.c ] || { mkdir -p $(FISHHOOK_DIR) && for f in fishhook.c fishhook.h; do \
  curl -fsSL -o $(FISHHOOK_DIR)/$$f https://raw.githubusercontent.com/facebook/fishhook/$(FISHHOOK_COMMIT)/$$f; done; })

# PRIME_DEBUG=1 builds Debug, with the Compatibility report; a plain make
# builds Release.
PRIME_DEBUG ?= 0

$(TWEAK_NAME)_FILES = $(shell find src -name '*.x' -o -name '*.xm' -o -name '*.m' -o -name '*.mm' -o -name '*.c') \
                      $(FISHHOOK_DIR)/fishhook.c $(FLEXD_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc $(addprefix -I,$(shell find src -type d)) -Ivendor $(FLEXD_INCLUDES) \
                       -DPDT_FLEX_SOURCES=$(words $(FLEXD_FILES)) -DPRIMEDIT_DEBUG=$(PRIME_DEBUG) \
                       -Wno-module-import-in-extern-c -Wno-error \
                       -Wno-deprecated-declarations -Wno-strict-prototypes -Wno-unsupported-availability-guard \
                       -Wno-unused-function -Wno-nullability-completeness -Wno-unused-property-ivar
$(TWEAK_NAME)_CXXFLAGS = -std=gnu++11 -Wno-error
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation CoreGraphics ImageIO QuartzCore WebKit Security SceneKit QuickLook
$(TWEAK_NAME)_LIBRARIES = z sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
