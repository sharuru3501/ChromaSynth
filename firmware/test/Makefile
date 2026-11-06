# Host tests for the bridge core (no ESP32 needed):  make -C firmware/test
CC      ?= cc
CFLAGS  := -std=c11 -Wall -Wextra -Wpedantic -Werror -g -I../core
SRCS    := test_core.c ../core/bridge_core.c ../core/bridge_core.h

.PHONY: test asan vectors syntax lib clean

EXT := $(if $(filter Darwin,$(shell uname -s)),dylib,so)

test: test_core
	./test_core vectors.txt

# the same tests under AddressSanitizer + UBSan
asan: $(SRCS)
	$(CC) $(CFLAGS) -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -o test_core_asan test_core.c ../core/bridge_core.c
	./test_core_asan vectors.txt

test_core: $(SRCS)
	$(CC) $(CFLAGS) -O2 -o $@ test_core.c ../core/bridge_core.c

# Type-check the ESP-IDF glue (main/*.c) with a host compiler and hand-made stub headers.
# This catches mistakes in OUR code; it cannot prove that the ESP-IDF/TinyUSB calls exist
# (that needs `idf.py build`, see docs/FIRMWARE.md).
syntax:
	$(CC) -std=gnu11 -Wall -Wextra -Werror -fsyntax-only -Istubs -I../core -I../main ../main/main.c ../main/usb_midi.c ../main/link.c
	$(CC) -std=gnu11 -Wall -Wextra -Werror -fsyntax-only -Istubs -I../core -I../main -DLINK_USE_BITBANG_OVERRIDE ../main/link.c -include bitbang_override.h
	@echo "glue type-checks against the stubs (SPI and bit-bang link drivers)"

# The C core as a shared library, for tools/headless_midi_test.py (ROM <-> C core in the emulator)
lib: libbridge.$(EXT)

libbridge.$(EXT): lib_shim.c ../core/bridge_core.c ../core/bridge_core.h
	$(CC) -std=c11 -O2 -fPIC -shared -I../core -o $@ lib_shim.c ../core/bridge_core.c

# regenerate the golden traces from the Python reference model
vectors:
	python3 ../../tools/gen_bridge_vectors.py

clean:
	rm -rf test_core test_core_asan test_core.dSYM test_core_asan.dSYM libbridge.dylib libbridge.so
