
all: SPDY

SPDY: 
	echo "build is $(BUILD)"
	export BUILD=$(BUILD) ; cd SPDY && make install-macosx
	export BUILD=$(BUILD) ; cd SPDY && make install

clean:
	-rm -rf build

check: SPDY
	cd SPDY && make check

local:
	mkdir -p $(BUILD)/include
	export BUILD=$(BUILD) ; cd SPDY && make local

.PHONY: all check SPDY clean local
