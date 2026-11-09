RGBASM  ?= rgbasm
RGBLINK ?= rgblink
RGBFIX  ?= rgbfix

# Public build (default): 32 KB ROM, 32 KB battery SRAM, save slots in SRAM banks 0-3.
# `make card`: the maintainer's EMS 64M Smart Card, where LSDj owns SRAM banks 0-11: slots in banks 12-15, 128 KB SRAM.
BUILD     ?= build
SLOT_BANK0 ?= 0
SRAM_CODE ?= 3
CGB_FLAG  ?= -C            # public build: Game Boy Color only (the patterns live in the GBC's switchable work RAM banks; a DMG has only one)
ifeq ($(SLOT_BANK0),0)
EXTRA_AS  :=
else
EXTRA_AS  := -D SLOT_BANK0=$(SLOT_BANK0)
endif
TARGET  := $(BUILD)/chromasynth.gb
SRCS    := $(wildcard src/*.asm)
OBJS    := $(patsubst src/%.asm,$(BUILD)/%.o,$(SRCS))
INCS    := $(wildcard inc/*.inc) $(wildcard src/*.inc)

.PHONY: all card clean run notetable gen check-bridge check-mcu check-usb-bridge firmware

all: $(TARGET)

card:
	$(MAKE) BUILD=build-card SLOT_BANK0=12 SRAM_CODE=4 CGB_FLAG=-c

$(BUILD)/%.o: src/%.asm $(INCS) | $(BUILD)
	$(RGBASM) -Weverything -E $(EXTRA_AS) -I inc/ -I src/ -o $@ $<

$(TARGET): $(OBJS)
	$(RGBLINK) -p 0xFF -m $(TARGET:.gb=.map) -n $(TARGET:.gb=.sym) -o $@ $(OBJS)
	$(RGBFIX) -v -p 0xFF $(CGB_FLAG) -t CHROMASYNTH -m MBC5+RAM+BATTERY -r $(SRAM_CODE) -l 0x33 -n 0 $@

$(BUILD):
	mkdir -p $(BUILD)

# Regenerate src/notetable.inc (committed; only needed when changing the range)
notetable:
	python3 tools/gen_notetable.py > src/notetable.inc

# Regenerate all committed data includes
gen:
	python3 tools/gen_notetable.py > src/notetable.inc
	python3 tools/gen_lowbit.py > src/lowbit.inc
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

# The Mac helper for wired MIDI (tools/chromasynth_usb_bridge.swift): compile and run its MIDI -> console line self test.
check-usb-bridge:
	tools/test_usb_bridge.sh

run: $(TARGET)
	open -a SameBoy $(TARGET)

clean:
	rm -rf build build-card
