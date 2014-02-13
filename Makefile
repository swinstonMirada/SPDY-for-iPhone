BUILD:=$(shell pwd)/build

ZLIB_BUILD ?= $(BUILD)
IPHONEOS_PKG_CONFIG_PATH=$(ZLIB_BUILD)/iphoneos-lib/pkgconfig
MACOSX_PKG_CONFIG_PATH=$(ZLIB_BUILD)/macosx-lib/pkgconfig

all: SPDY

build/lib/libSPDY.a:
	cd SPDY && make

SPDY: build/lib/libSPDY.a

clean:
	-rm -rf build

check: SPDY
	cd SPDY && make check

local:
	mkdir -p $(BUILD)/include
	cp -a build/$(PLATFORM_NAME)-$(CURRENT_ARCH)/include/* $(BUILD)/include	
	cd SPDY && make local

.PHONY: all check SPDY clean local
