RGBASM  ?= rgbasm
RGBLINK ?= rgblink
RGBFIX  ?= rgbfix

TARGET  := build/chromasynth.gb
SRCS    := $(wildcard src/*.asm)
OBJS    := $(patsubst src/%.asm,build/%.o,$(SRCS))
INCS    := $(wildcard inc/*.inc) $(wildcard src/*.inc)

.PHONY: all clean run notetable gen check-bridge check-mcu firmware

all: $(TARGET)

build/%.o: src/%.asm $(INCS) | build
	$(RGBASM) -Weverything -E -I inc/ -I src/ -o $@ $<

$(TARGET): $(OBJS)
	$(RGBLINK) -p 0xFF -m $(TARGET:.gb=.map) -n $(TARGET:.gb=.sym) -o $@ $(OBJS)
	$(RGBFIX) -v -p 0xFF -c -t CHROMASYNTH -m MBC5+RAM+BATTERY -r 2 -l 0x33 -n 0 $@

build:
	mkdir -p build

# Regenerate src/notetable.inc (committed; only needed when changing the range)
notetable:
	python3 tools/gen_notetable.py > src/notetable.inc

# Regenerate all committed data includes
gen:
	python3 tools/gen_notetable.py > src/notetable.inc
	python3 tools/gen_font.py > src/font.inc
	python3 tools/gen_waves.py > src/waves.inc
	python3 tools/gen_tempo.py > src/tempo.inc
	python3 tools/gen_divs.py > src/divs.inc
	python3 tools/gen_pattern.py > src/pattern.inc
	python3 tools/gen_bend.py > src/bend.inc
	python3 tools/gen_bridge_vectors.py

# Bridge tests that need no emulator and no ESP32: the Python model, then the C core against its golden traces
# ESP32-S3 firmware (needs ESP-IDF in ~/esp/esp-idf, or IDF_PATH set)
firmware:
	cd firmware && . $${IDF_PATH:-$$HOME/esp/esp-idf}/export.sh > /dev/null && idf.py build

check-bridge:
	python3 tools/test_bridge_ref.py
	make -C firmware/test test asan syntax lib

# The MCU-side link protocol core (chromatic-mcu/src/chlink_proto.c) against the Python reference. No ESP32 needed.
check-mcu:
	make -C chromatic-mcu/test check asan

run: $(TARGET)
	open -a SameBoy $(TARGET)

clean:
	rm -rf build
