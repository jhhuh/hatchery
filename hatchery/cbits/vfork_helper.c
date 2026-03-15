/* vfork_helper.c — C helper for spawning fork server from Haskell via FFI
 *
 * Compiled by GHC/cabal as a normal C file (NOT musl-gcc, NOT static-PIE).
 * Uses normal libc. Part of the Haskell binary, not the fork server.
 */

#define _GNU_SOURCE

#include <unistd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

/* AT_EMPTY_PATH may not be defined in all headers */
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

/* ── Result struct returned to Haskell ───────────────────────────────── */

struct spawn_result {
    int fork_server_pid;
    int sock_fd;        /* our end of socketpair */
    int liveness_fd;    /* write end of liveness pipe — closes when parent dies */
};

/* ── Helpers ─────────────────────────────────────────────────────────── */

static int do_memfd_create(const char *name, unsigned int flags)
{
    return (int)syscall(__NR_memfd_create, name, flags);
}

static int do_execveat(int dirfd, const char *pathname,
                       char *const argv[], char *const envp[],
                       int flags)
{
    return (int)syscall(__NR_execveat, dirfd, pathname, argv, envp, flags);
}

/* Write all bytes, retrying on short writes. Returns 0 on success, -errno on failure. */
static int write_all(int fd, const unsigned char *buf, unsigned int len)
{
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        buf += n;
        len -= (unsigned int)n;
    }
    return 0;
}

/* ── Main entry point ────────────────────────────────────────────────── */

int spawn_fork_server(
    const unsigned char *elf_data,
    unsigned int elf_size,
    int pool_size,
    int injection_cap,
    unsigned long code_region_size,
    unsigned long ring_buf_size,
    struct spawn_result *out)
{
    int memfd = -1, sv[2] = {-1, -1}, pipefd[2] = {-1, -1};
    int ret;

    /* 1. Create memfd and write the fork server ELF into it */
    memfd = do_memfd_create("fork_server", 0x0001U /* MFD_CLOEXEC */);
    if (memfd < 0)
        return -errno;

    ret = write_all(memfd, elf_data, elf_size);
    if (ret < 0)
        goto fail;

    /* 2. Create socketpair for command/response communication */
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv) < 0) {
        ret = -errno;
        goto fail;
    }

    /* 3. Create pipe for parent-liveness detection
     *    pipefd[0] = read end → fork server monitors this
     *    pipefd[1] = write end → parent keeps; closes on parent death → POLLHUP */
    if (pipe2(pipefd, O_CLOEXEC) < 0) {
        ret = -errno;
        goto fail;
    }

    /* 4. Clear CLOEXEC on fds the fork server needs to inherit:
     *    sv[1] (its end of socketpair) and pipefd[0] (read end of liveness pipe) */
    if (fcntl(sv[1], F_SETFD, 0) < 0 ||
        fcntl(pipefd[0], F_SETFD, 0) < 0) {
        ret = -errno;
        goto fail;
    }

    /* 5. Build argv for the fork server.
     *    argv[0] = "fork_server"
     *    argv[1] = sock_fd (sv[1])
     *    argv[2] = pipe_fd (pipefd[0], read end)
     *    argv[3] = pool_size
     *    argv[4] = injection_cap
     *    argv[5] = code_region_size
     *    argv[6] = ring_buf_size */
    char arg0[] = "fork_server";
    char arg1[16], arg2[16], arg3[16], arg4[16], arg5[32], arg6[32];
    snprintf(arg1, sizeof(arg1), "%d", sv[1]);
    snprintf(arg2, sizeof(arg2), "%d", pipefd[0]);
    snprintf(arg3, sizeof(arg3), "%d", pool_size);
    snprintf(arg4, sizeof(arg4), "%d", injection_cap);
    snprintf(arg5, sizeof(arg5), "%lu", code_region_size);
    snprintf(arg6, sizeof(arg6), "%lu", ring_buf_size);

    char *argv[] = { arg0, arg1, arg2, arg3, arg4, arg5, arg6, NULL };

    /* 6. vfork + execveat into the memfd */
    pid_t pid = vfork();
    if (pid < 0) {
        ret = -errno;
        goto fail;
    }

    if (pid == 0) {
        /* Child: exec into the memfd. vfork safety: only call execveat or _exit. */
        do_execveat(memfd, "", argv, NULL, AT_EMPTY_PATH);
        _exit(127);
    }

    /* 7. Parent: close fork server's ends, keep ours */
    close(sv[1]);
    close(pipefd[0]);
    close(memfd);

    out->fork_server_pid = pid;
    out->sock_fd = sv[0];
    out->liveness_fd = pipefd[1];

    return 0;

fail:
    if (memfd >= 0) close(memfd);
    if (sv[0] >= 0) close(sv[0]);
    if (sv[1] >= 0) close(sv[1]);
    if (pipefd[0] >= 0) close(pipefd[0]);
    if (pipefd[1] >= 0) close(pipefd[1]);
    return ret;
}
