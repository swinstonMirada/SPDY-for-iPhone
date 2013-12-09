
CONFIGURATION ?= Release
LATEST_SDK=$(shell xcodebuild -showsdks | grep iphoneos | sed -e 's/.*iphoneos//g' | tail -n 1)


install:
	mkdir -p ../install/include/SPDY ../install/lib
	xcodebuild clean
	xcodebuild -configuration $(CONFIGURATION) install
	cp build/UninstalledProducts/libSPDY.a ../install/lib/libSPDY.a
	cp build/include/SPDY/*.h ../install/include/SPDY/

check-%:
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` clean
	xcodebuild -configuration $(CONFIGURATION) -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` -target SPDYTests | tee /tmp/test-logs

check: check-$(LATEST_SDK)

framework-local:
	mkdir -p ../install/include/SPDY ../install/lib
	xcodebuild clean 
	xcodebuild  -arch $(CURRENT_ARCH) -sdk $(SDK_NAME) -configuration $(CONFIGURATION) install
	mkdir -p ../install-$(CURRENT_ARCH)/lib
	mkdir -p ../install-$(CURRENT_ARCH)/include/SPDY
	cp build/UninstalledProducts/libSPDY.a ../install-$(CURRENT_ARCH)/lib/libSPDY.a
	cp build/include/SPDY/*.h ../install-$(CURRENT_ARCH)/include/SPDY/
