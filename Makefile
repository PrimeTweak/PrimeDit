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

$(TWEAK_NAME)_FILES = $(shell find src -name '*.x' -o -name '*.xm' -o -name '*.m' -o -name '*.c')
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -Isrc -Isrc/Debug -Isrc/Features -Isrc/Settings \
                       -Wno-module-import-in-extern-c
$(TWEAK_NAME)_FRAMEWORKS = Security

include $(THEOS_MAKE_PATH)/tweak.mk
