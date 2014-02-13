BUILD:=$(shell pwd)/build

ZLIB_BUILD ?= $(BUILD)
IPHONEOS_PKG_CONFIG_PATH=$(ZLIB_BUILD)/iphoneos-lib/pkgconfig
MACOSX_PKG_CONFIG_PATH=$(ZLIB_BUILD)/macosx-lib/pkgconfig

all: SPDY

include Makefile.spdylay

build/lib/libSPDY.a: spdylay
	cd SPDY && make

SPDY: build/lib/libSPDY.a

clean:
	-rm -rf build

check: SPDY
	cd SPDY && make check

local: build/$(PLATFORM_NAME)-$(CURRENT_ARCH)/lib/libspdylay.a
	mkdir -p $(BUILD)/include
	cp -a build/$(PLATFORM_NAME)-$(CURRENT_ARCH)/include/* $(BUILD)/include	
	cd SPDY && make local

.PHONY: all check spdylay SPDY clean update-spdylay local
