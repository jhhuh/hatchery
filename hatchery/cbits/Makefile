ifdef MUSL_CC
CC := $(MUSL_CC)
endif
CFLAGS = -static-pie -nostartfiles -fPIE -Os -Wall -Werror

fork_server: fork_server.c seccomp_filter.c syscall.h ring_buffer.h protocol.h seccomp_filter.h
	$(CC) $(CFLAGS) -o $@ fork_server.c seccomp_filter.c

.PHONY: clean
clean:
	rm -f fork_server
