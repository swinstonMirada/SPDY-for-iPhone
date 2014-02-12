BUILD:=$(shell pwd)/build
PKG_CONFIG_PATH=$(BUILD)/lib/pkgconfig

all: SPDY

define build_ios_spdylay
	@echo "Building spdylay for sdk $(1) arch $(2)"
	cd spdylay && ../ios-configure -p "$(BUILD)/$(1)-$(2)" -k $(PKG_CONFIG_PATH) $(1)-$(2) --with-xml-prefix=/unkonwn
	cd spdylay/lib && make install
endef

spdylay/configure: spdylay/configure.ac build/lib/libz.a
	cd spdylay && autoreconf -i && automake && autoconf
	touch spdylay/configure

build/iphoneos-armv7/lib/libspdylay.a: spdylay/configure ios-configure
	$(call build_ios_spdylay,iphoneos,armv7)

build/iphoneos-armv7s/lib/libspdylay.a: spdylay/configure ios-configure
	$(call build_ios_spdylay,iphoneos,armv7s)

build/iphoneos-arm64/lib/libspdylay.a: spdylay/configure ios-configure
	$(call build_ios_spdylay,iphoneos,arm64)

build/iphonesimulator-i386/lib/libspdylay.a: spdylay/configure ios-configure
	$(call build_ios_spdylay,iphonesimulator,i386)

build/iphonesimulator-x86_64/lib/libspdylay.a: spdylay/configure ios-configure
	$(call build_ios_spdylay,iphonesimulator,x86_64)

#build/native/lib/libspdylay.a: spdylay/configure
#	cd spdylay && ./configure --prefix="$(BUILD)/native"
#	cd spdylay && make install


build/lib/libspdylay.a: build/iphoneos-armv7s/lib/libspdylay.a build/iphoneos-armv7/lib/libspdylay.a build/iphoneos-arm64/lib/libspdylay.a build/iphonesimulator-i386/lib/libspdylay.a build/iphonesimulator-x86_64/lib/libspdylay.a
	lipo -create $^ -output $@
	mkdir -p $(BUILD)/include
	cp -r build/iphoneos-armv7/include/* $(BUILD)/include

spdylay: build/lib/libspdylay.a


define build_ios_libz
	@echo "Building libz for sdk $(1) arch $(2)"
	cd zlib && PLATFORM=$(1) ARCH=$(2) ROOTDIR=$(BUILD)/$(1)-$(2) ./build-zlib.sh
endef

build/iphonesimulator-i386/lib/libz.a: zlib/build-zlib.sh
	$(call build_ios_libz,iphonesimulator,i386)

build/iphonesimulator-x86_64/lib/libz.a: zlib/build-zlib.sh
	$(call build_ios_libz,iphonesimulator,x86_64)

#build/native/lib/libz.a: zlib/build-native-zlib.sh
#	cd zlib && ROOTDIR=$(BUILD)/native ./build-native-zlib.sh

build/iphoneos-armv7/lib/libz.a: zlib/build-zlib.sh
	$(call build_ios_libz,iphoneos,armv7)

build/iphoneos-armv7s/lib/libz.a: zlib/build-zlib.sh
	$(call build_ios_libz,iphoneos,armv7s)

build/iphoneos-arm64/lib/libz.a: zlib/build-zlib.sh
	$(call build_ios_libz,iphoneos,arm64)

build/lib/libz.a: build/iphonesimulator-i386/lib/libz.a build/iphonesimulator-x86_64/lib/libz.a build/iphoneos-armv7/lib/libz.a build/iphoneos-armv7s/lib/libz.a build/iphoneos-arm64/lib/libz.a
	-mkdir -p build/lib/pkgconfig
	lipo -create $^ -output $@
	sed -e 's,prefix=\(.*\)/armv7,prefix=\1,g' build/iphoneos-armv7/lib/pkgconfig/zlib.pc > build/lib/pkgconfig/zlib.pc

zlib: build/lib/libz.a


build/lib/libSPDY.a: build/lib/libspdylay.a
	cd SPDY && make

SPDY: build/lib/libSPDY.a


clean:
	-rm -r build

update-spdylay:
	cd spdylay && git pull
	-rm build/lib/libspdylay.* build/{armv7s,armv7,arm64,i386,x86_64}/lib/libspdylay.*


check: SPDY
	cd SPDY && make check


local: build/$(CURRENT_ARCH)/lib/libspdylay.a
	mkdir -p $(BUILD)/include
	cp -a build/$(CURRENT_ARCH)/include/* $(BUILD)/include	
	cd SPDY && make local

.PHONY: all check spdylay zlib SPDY clean update-spdylay local
