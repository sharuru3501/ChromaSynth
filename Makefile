RGBASM  ?= rgbasm
RGBLINK ?= rgblink
RGBFIX  ?= rgbfix

TARGET  := build/chromasynth.gb
SRCS    := $(wildcard src/*.asm)
OBJS    := $(patsubst src/%.asm,build/%.o,$(SRCS))
INCS    := $(wildcard inc/*.inc) $(wildcard src/*.inc)

.PHONY: all clean run notetable gen

all: $(TARGET)

build/%.o: src/%.asm $(INCS) | build
	$(RGBASM) -Weverything -E -I inc/ -I src/ -o $@ $<

$(TARGET): $(OBJS)
	$(RGBLINK) -p 0xFF -m $(TARGET:.gb=.map) -n $(TARGET:.gb=.sym) -o $@ $(OBJS)
	$(RGBFIX) -v -p 0xFF -c -t CHROMASYNTH -m ROM -l 0x33 -n 0 $@

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

run: $(TARGET)
	open -a SameBoy $(TARGET)

clean:
	rm -rf build
