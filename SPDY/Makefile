
CONFIGURATION ?= Release
CURRENT_ARCH ?= armv7
SDK_NAME ?= iphoneos7.0
PLATFORM_NAME ?= iphoneos

LATEST_SDK=$(shell xcodebuild -showsdks | grep iphoneos | sed -e 's/.*iphoneos//g' | tail -n 1)


install:
	mkdir -p $(BUILD)/install/include $(BUILD)/install/iphoneos-lib
	xcodebuild SYMROOT=$(BUILD) DSTROOT=$(BUILD) -configuration $(CONFIGURATION) install
	cp $(BUILD)/UninstalledProducts/libSPDY.a $(BUILD)/install/iphoneos-lib/libSPDY.a

install-macosx:
	mkdir -p $(BUILD)/install/include $(BUILD)/install/macosx-lib
	xcodebuild SYMROOT=$(BUILD) DSTROOT=$(BUILD) -configuration $(CONFIGURATION) -target SPDY-MacOSX install
	cp $(BUILD)/usr/local/lib/libSPDY-MacOSX.a $(BUILD)/install/macosx-lib/libSPDY.a

check-%:
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` clean 
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` -target SPDYTests | tee /tmp/test-logs

check: check-$(LATEST_SDK)

local:
	mkdir -p $(BUILD)/install/include $(BUILD)/install/$(PLATFORM_NAME)-lib
	xcodebuild  -arch $(CURRENT_ARCH) -sdk $(SDK_NAME) -configuration $(CONFIGURATION) install SYMROOT=$(BUILD) DSTROOT=$(BUILD) 
	mkdir -p $(BUILD)/install-$(CURRENT_ARCH)/$(PLATFORM_NAME)-lib
	mkdir -p $(BUILD)/install-$(CURRENT_ARCH)/include
	pwd
	cp $(BUILD)/UninstalledProducts/libSPDY.a $(BUILD)/install-$(CURRENT_ARCH)/$(PLATFORM_NAME)-lib/libSPDY.a
	cp -a $(BUILD)/include/* $(BUILD)/install-$(CURRENT_ARCH)/include
