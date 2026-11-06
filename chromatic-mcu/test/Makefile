# Host test of the MCU link protocol core against tools/chromatic_link_ref.py. No ESP32 needed.
CC ?= cc
CFLAGS = -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -g

vectors.txt: gen_vectors.py ../../tools/chromatic_link_ref.py
	python3 gen_vectors.py > $@

test_proto: test_proto.c ../src/chlink_proto.c ../src/chlink_proto.h
	$(CC) $(CFLAGS) -o $@ test_proto.c ../src/chlink_proto.c

chl_cli: chl_cli.c ../src/chlink_proto.c ../src/chlink_proto.h
	$(CC) $(CFLAGS) -o $@ chl_cli.c ../src/chlink_proto.c

check: vectors.txt test_proto chl_cli
	./test_proto vectors.txt

asan: vectors.txt
	$(CC) $(CFLAGS) -fsanitize=address,undefined -o test_proto_asan test_proto.c ../src/chlink_proto.c
	./test_proto_asan vectors.txt

clean:
	rm -f test_proto test_proto_asan chl_cli vectors.txt
