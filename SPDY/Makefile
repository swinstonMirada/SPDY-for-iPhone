
CONFIGURATION ?= Release
CURRENT_ARCH ?= armv7
SDK_NAME ?= iphoneos7.0
PLATFORM_NAME ?= iphoneos

LATEST_SDK=$(shell xcodebuild -showsdks | grep iphoneos | sed -e 's/.*iphoneos//g' | tail -n 1)


install:
	mkdir -p ../install/include/SPDY ../install/iphoneos-lib
	xcodebuild clean
	xcodebuild -configuration $(CONFIGURATION) install
	cp build/UninstalledProducts/libSPDY.a ../install/iphoneos-lib/libSPDY.a
	cp build/include/SPDY/*.h ../install/include/SPDY/

install-macosx:
	mkdir -p ../install/include/SPDY ../install/macosx-lib
	xcodebuild clean
	xcodebuild -configuration $(CONFIGURATION) -target SPDY-MacOSX install
	cp ../build/lib/usr/local/lib/libSPDY-MacOSX.a ../install/macosx-lib/libSPDY.a
#	cp build/include/SPDY/*.h ../install/include/SPDY/

check-%:
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` clean
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` -target SPDYTests | tee /tmp/test-logs

check: check-$(LATEST_SDK)

local:
	mkdir -p ../install/include/SPDY ../install/$(PLATFORM_NAME)-lib
	xcodebuild clean 
	xcodebuild  -arch $(CURRENT_ARCH) -sdk $(SDK_NAME) -configuration $(CONFIGURATION) install
	mkdir -p ../install-$(CURRENT_ARCH)/$(PLATFORM_NAME)-lib
	mkdir -p ../install-$(CURRENT_ARCH)/include/SPDY
	pwd
	cp build/UninstalledProducts/libSPDY.a ../install-$(CURRENT_ARCH)/$(PLATFORM_NAME)-lib/libSPDY.a
	cp build/include/SPDY/*.h ../install-$(CURRENT_ARCH)/include/SPDY/
