BUILD:=$(shell pwd)/build

all: SPDY

SPDY: 
	cd SPDY && make install-macosx
	cd SPDY && make install

clean:
	-rm -rf build

check: SPDY
	cd SPDY && make check

local:
	mkdir -p $(BUILD)/include
	cd SPDY && make local

.PHONY: all check SPDY clean local
