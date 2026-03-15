ifdef MUSL_CC
CC := $(MUSL_CC)
endif
CFLAGS = -static-pie -nostartfiles -fPIE -Os -Wall -Werror

fork_server: fork_server.c syscall.h ring_buffer.h protocol.h
	$(CC) $(CFLAGS) -o $@ fork_server.c

.PHONY: clean
clean:
	rm -f fork_server
