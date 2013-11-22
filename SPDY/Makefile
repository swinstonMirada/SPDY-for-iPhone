
CONFIGURATION ?= Release
LATEST_SDK=$(shell xcodebuild -showsdks | grep iphoneos | sed -e 's/.*iphoneos//g' | tail -n 1)


install:
	mkdir -p ../install/include/SPDY ../install/lib
	xcodebuild clean
	xcodebuild -configuration Debug install
	cp build/UninstalledProducts/libSPDY.a ../install/lib/libSPDY.a
	cp build/include/SPDY/*.h ../install/include/SPDY/

check-%:
	xcodebuild -configuration Debug -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` clean
	xcodebuild -configuration Debug -sdk iphonesimulator`echo $@ | sed -e 's/check-//'` -target SPDYTests | tee /tmp/test-logs

check: check-$(LATEST_SDK)

