BUILD:=$(shell pwd)/build
IPHONEOS_PKG_CONFIG_PATH=$(BUILD)/iphoneos-lib/pkgconfig
MACOSX_PKG_CONFIG_PATH=$(BUILD)/macosx-lib/pkgconfig

all: SPDY

include Makefile.spdylay
include Makefile.zlib

build/lib/libSPDY.a: spdylay
	cd SPDY && make

SPDY: build/lib/libSPDY.a


clean:
	-rm -rf build

check: SPDY
	cd SPDY && make check

local: build/$(CURRENT_ARCH)/lib/libspdylay.a
	mkdir -p $(BUILD)/include
	cp -a build/$(CURRENT_ARCH)/include/* $(BUILD)/include	
	cd SPDY && make local

.PHONY: all check spdylay zlib SPDY clean update-spdylay local
