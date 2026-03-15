/* fork_server.c — static-PIE ELF, no libc, entry at _start
 *
 * Manages a pool of sandboxed worker processes.
 * Spawned by Haskell via vfork+execveat; receives fds as argv.
 */

#include "syscall.h"
#include "ring_buffer.h"
#include "protocol.h"
#include "seccomp_filter.h"

#include <linux/mman.h>
#include <linux/prctl.h>
#include <sys/epoll.h>

/* ── Constants ───────────────────────────────────────────────────────── */

#define MAX_WORKERS     64
#define MFD_CLOEXEC     0x0001U
#define MFD_ALLOW_SEALING 0x0002U
#define PR_SET_PDEATHSIG  1
#define PR_SET_DUMPABLE    4
#define SIGKILL            9

/* iovec for process_vm_writev */
struct iovec {
    void          *iov_base;
    unsigned long  iov_len;
};

/* ── Injection capability (argv[4]) ──────────────────────────────────── */

enum injection_cap {
    CAP_PROCESS_VM_WRITEV_ONLY = 0,
    CAP_SHARED_MEMFD_ONLY      = 1,
    CAP_BOTH_METHODS            = 2,
};

/* ── Worker state ────────────────────────────────────────────────────── */

struct worker_state {
    int pid;
    int pidfd;
    int ring_fd;                /* memfd for ring buffer */
    int code_fd;                /* memfd for code region, -1 if not used */
    struct ring_buffer *ring;   /* mmap'd in fork server too, for monitoring */
    int busy;
    int reserved;               /* reserved by prepare(), excluded from auto-select */
};

/* ── Globals ─────────────────────────────────────────────────────────── */

static struct worker_state workers[MAX_WORKERS];
static int pool_size;
static int sock_fd;             /* socketpair fd (commands from Haskell) */
static int pipe_fd;             /* pipe fd (parent-liveness) */
static int injection_cap;
static unsigned long code_region_size;
static unsigned long ring_buf_size;
static int epfd;                /* epoll fd */
static int dumpable_window;     /* set after CMD_RESERVE, cleared on next command */
static unsigned int spin_count; /* spin iterations before futex fallback (0 = pure futex) */

/* ── Forward declarations ───────────────────────────────────────────── */

static void wake_and_wait(int idx);

/* ── String/memory helpers ───────────────────────────────────────────── */

static int simple_atoi(const char *s)
{
    int n = 0;
    int neg = 0;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9')
        n = n * 10 + (*s++ - '0');
    return neg ? -n : n;
}

static void simple_memset(void *dst, int c, unsigned long n)
{
    unsigned char *d = dst;
    while (n--)
        *d++ = (unsigned char)c;
}

/* ── Reliable read/write over socketpair ─────────────────────────────── */

static long read_full(int fd, void *buf, unsigned long count)
{
    unsigned long done = 0;
    while (done < count) {
        long r = sys_read(fd, (char *)buf + done, count - done);
        if (r <= 0) return r == 0 ? -(long)1 : r;
        done += (unsigned long)r;
    }
    return (long)done;
}

static long write_full(int fd, const void *buf, unsigned long count)
{
    unsigned long done = 0;
    while (done < count) {
        long r = sys_write(fd, (const char *)buf + done, count - done);
        if (r <= 0) return r == 0 ? -(long)1 : r;
        done += (unsigned long)r;
    }
    return (long)done;
}

/* ── Send a response to Haskell ──────────────────────────────────────── */

static void send_response(const struct response *rsp)
{
    write_full(sock_fd, rsp, sizeof(*rsp));
}

static void send_response_with_data(const struct response *rsp,
                                    const void *data, unsigned long len)
{
    write_full(sock_fd, rsp, sizeof(*rsp));
    if (len > 0)
        write_full(sock_fd, data, len);
}

/* ── Worker main (runs in child after fork) ──────────────────────────── */

static void __attribute__((noreturn)) worker_main(int ring_fd, int code_fd,
                                                   unsigned long cr_size,
                                                   unsigned long rb_size)
{
    /* PR_SET_PDEATHSIG: die if fork server dies */
    sys_prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);

    /* mmap ring buffer from memfd */
    struct ring_buffer *ring = sys_mmap(0, rb_size,
                                        PROT_READ | PROT_WRITE,
                                        MAP_SHARED, ring_fd, 0);
    if ((long)ring < 0)
        sys_exit_group(100);

    /* mmap code region */
    void *code_base;
    if (code_fd >= 0) {
        /* Shared memfd mode */
        code_base = sys_mmap(0, cr_size,
                             PROT_READ | PROT_WRITE | PROT_EXEC,
                             MAP_SHARED, code_fd, 0);
    } else {
        /* process_vm_writev mode: private anonymous */
        code_base = sys_mmap(0, cr_size,
                             PROT_READ | PROT_WRITE | PROT_EXEC,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    }
    if ((long)code_base < 0)
        sys_exit_group(101);

    /* Close inherited fds we no longer need */
    sys_close(ring_fd);
    if (code_fd >= 0)
        sys_close(code_fd);

    /* NOTE: Workers must stay dumpable — PR_SET_DUMPABLE=0 would block
     * process_vm_writev from the fork server. The fork server itself is
     * set non-dumpable (see fork_server_main). Seccomp is the primary
     * sandbox for workers. */

    /* Publish code region address in ring buffer */
    ring->code_base = (uint64_t)(unsigned long)code_base;
    ring->code_size = (uint64_t)cr_size;

    /* Install seccomp filter BEFORE accepting any code */
    install_seccomp_filter();

    /* Signal ready */
    atomic_store_explicit(&ring->status, WORKER_READY, memory_order_release);
    futex_wake(&ring->status, 1);

    /* Worker loop */
    for (;;) {
        /* Phase 1: spin */
        unsigned int spins = spin_count;
        uint32_t ctl;
        for (unsigned int i = 0; i < spins; i++) {
            ctl = atomic_load_explicit(&ring->control,
                                        memory_order_acquire);
            if (ctl == WORKER_RUN) goto run;
            if (ctl == WORKER_STOP) sys_exit_group(0);
            __builtin_ia32_pause();
        }

        /* Phase 2: futex fallback */
        ctl = atomic_load_explicit(&ring->control,
                                    memory_order_acquire);
        if (ctl == WORKER_IDLE) {
            futex_wait(&ring->control, WORKER_IDLE);
            continue;
        }
        if (ctl == WORKER_STOP)
            sys_exit_group(0);

    run:
        /* ctl == WORKER_RUN */
        atomic_store_explicit(&ring->status, WORKER_BUSY,
                              memory_order_release);

        /* Execute code at code_base */
        typedef int (*code_fn)(void);
        code_fn fn = (code_fn)code_base;
        int result = fn();

        /* Write result */
        ring->exit_code = (int32_t)result;
        ring->result_offset = 0;
        ring->result_size = 0;

        /* Reset control and set status to DONE */
        atomic_store_explicit(&ring->control, WORKER_IDLE,
                              memory_order_release);
        atomic_store_explicit(&ring->status, WORKER_DONE,
                              memory_order_release);

        /* Wake parent */
        atomic_store_explicit(&ring->notify, 1, memory_order_release);
        futex_wake(&ring->notify, 1);
    }
}

/* ── Fork server: spawn workers ──────────────────────────────────────── */

static int spawn_worker(int idx)
{
    struct worker_state *w = &workers[idx];

    /* Create ring buffer memfd */
    int rfd = (int)sys_memfd_create("ring", MFD_CLOEXEC);
    if (rfd < 0) return rfd;

    /* Set ring buffer size via ftruncate (fcntl F_SETFL won't work; use write) */
    /* ftruncate = __NR_ftruncate (77) — add inline call */
    {
        long ret = sys_call2(77 /*__NR_ftruncate*/, (long)rfd,
                             (long)ring_buf_size);
        if (ret < 0) { sys_close(rfd); return (int)ret; }
    }

    /* Create code memfd if needed */
    int cfd = -1;
    if (injection_cap == CAP_SHARED_MEMFD_ONLY ||
        injection_cap == CAP_BOTH_METHODS) {
        cfd = (int)sys_memfd_create("code", MFD_CLOEXEC);
        if (cfd < 0) { sys_close(rfd); return cfd; }
        long ret = sys_call2(77, (long)cfd, (long)code_region_size);
        if (ret < 0) { sys_close(rfd); sys_close(cfd); return (int)ret; }
    }

    /* mmap ring buffer in fork server for monitoring */
    struct ring_buffer *ring = sys_mmap(0, ring_buf_size,
                                         PROT_READ | PROT_WRITE,
                                         MAP_SHARED, rfd, 0);
    if ((long)ring < 0) {
        sys_close(rfd);
        if (cfd >= 0) sys_close(cfd);
        return -1;
    }

    /* Initialize ring buffer */
    simple_memset(ring, 0, ring_buf_size);

    /* Clear MFD_CLOEXEC so children inherit the fds */
    sys_fcntl(rfd, 2 /*F_SETFD*/, 0);
    if (cfd >= 0)
        sys_fcntl(cfd, 2 /*F_SETFD*/, 0);

    long pid = sys_fork();
    if (pid < 0) {
        sys_munmap(ring, ring_buf_size);
        sys_close(rfd);
        if (cfd >= 0) sys_close(cfd);
        return (int)pid;
    }
    if (pid == 0) {
        /* Child: close socketpair and pipe, enter worker_main */
        sys_close(sock_fd);
        sys_close(pipe_fd);
        worker_main(rfd, cfd, code_region_size, ring_buf_size);
        /* noreturn */
    }

    /* Parent: close child's copies (they inherited via fork) */
    /* We keep rfd and cfd open for monitoring/injection */

    /* Open pidfd for the worker */
    int pfd = (int)sys_pidfd_open((int)pid, 0);

    w->pid = (int)pid;
    w->pidfd = pfd;
    w->ring_fd = rfd;
    w->code_fd = cfd;
    w->ring = ring;
    w->busy = 0;

    /* Wait for worker to become READY */
    for (;;) {
        uint32_t st = atomic_load_explicit(&ring->status,
                                            memory_order_acquire);
        if (st == WORKER_READY)
            break;
        futex_wait(&ring->status, st);
    }

    return 0;
}

/* ── Find first idle worker ──────────────────────────────────────────── */

static int find_idle_worker(void)
{
    for (int i = 0; i < pool_size; i++) {
        if (!workers[i].busy && !workers[i].reserved && workers[i].pid > 0) {
            uint32_t st = atomic_load_explicit(&workers[i].ring->status,
                                                memory_order_acquire);
            if (st == WORKER_READY || st == WORKER_DONE)
                return i;
        }
    }
    return -1;
}

/* ── Handle dispatch command ─────────────────────────────────────────── */

static void handle_dispatch(const struct command *cmd)
{
    const struct cmd_dispatch *d = &cmd->dispatch;
    int idx;

    if (d->worker_id == (uint32_t)-1) {
        /* Auto-select idle worker */
        idx = find_idle_worker();
    } else {
        idx = (int)d->worker_id;
        if (idx < 0 || idx >= pool_size || workers[idx].pid <= 0)
            idx = -1;
    }

    /* Read code bytes from socketpair */
    uint8_t code_buf[4096];
    unsigned long code_len = d->code_len;
    if (code_len > sizeof(code_buf))
        code_len = sizeof(code_buf);

    if (code_len > 0) {
        long r = read_full(sock_fd, code_buf, code_len);
        if (r < 0) return;
    }

    if (idx < 0) {
        struct response rsp;
        simple_memset(&rsp, 0, sizeof(rsp));
        rsp.type = RSP_ERROR;
        rsp.error.code = -1;  /* no idle worker */
        send_response(&rsp);
        return;
    }

    struct worker_state *w = &workers[idx];

    /* Inject code */
    int method = (int)d->injection_method;
    if (method == INJECT_PROCESS_VM_WRITEV) {
        /* Write code into worker's code region via process_vm_writev */
        struct iovec local  = { code_buf, code_len };
        struct iovec remote = { (void *)(unsigned long)w->ring->code_base,
                                code_len };
        sys_process_vm_writev(w->pid, &local, 1, &remote, 1, 0);
    } else {
        /* Write code into the code memfd (worker sees via shared mapping) */
        /* Seek to beginning: use pwrite via lseek+write — simpler: just
         * lseek(fd,0,SEEK_SET) then write. But we have no lseek wrapper.
         * Use pwrite64 syscall (18) directly. */
        sys_call4(18 /*__NR_pwrite64*/, (long)w->code_fd,
                  (long)code_buf, (long)code_len, 0L);
    }

    /* Update ring buffer dispatch info */
    w->ring->injection_method = (uint32_t)method;
    w->ring->code_len = (uint32_t)code_len;
    w->busy = 1;

    wake_and_wait(idx);
}

/* ── Wake worker and wait for completion ──────────────────────────────── */

static void wake_and_wait(int idx)
{
    struct worker_state *w = &workers[idx];

    /* Signal worker to run */
    atomic_store_explicit(&w->ring->control, WORKER_RUN,
                          memory_order_release);
    futex_wake(&w->ring->control, 1);

    /* Wait for worker completion (poll ring buffer status) */
    for (;;) {
        uint32_t st = atomic_load_explicit(&w->ring->status,
                                            memory_order_acquire);
        if (st == WORKER_DONE)
            break;
        if (st == WORKER_CRASHED || w->pid <= 0) {
            goto crashed;
        }
        /* Check if worker process has exited (kill returns 0 for zombies) */
        {
            int wstatus;
            long wret = sys_call4(61 /*__NR_wait4*/, (long)w->pid,
                                  (long)&wstatus, 1 /*WNOHANG*/, 0L);
            if (wret > 0 || wret == -10 /*ECHILD*/) {
                goto crashed;
            }
        }
        /* Wait on notify futex with timeout (100ms) to recheck liveness */
        uint32_t nv = atomic_load_explicit(&w->ring->notify,
                                            memory_order_acquire);
        if (nv == 0) {
            struct { long tv_sec; long tv_nsec; } ts = { 0, 100000000L };
            sys_futex((uint32_t *)&w->ring->notify, 0 /*FUTEX_WAIT*/, 0,
                      &ts, 0, 0);
        }
    }

    /* Reset notify */
    atomic_store_explicit(&w->ring->notify, 0, memory_order_release);
    w->busy = 0;

    /* Send result */
    {
        struct response rsp;
        simple_memset(&rsp, 0, sizeof(rsp));
        rsp.type = RSP_WORKER_DONE;
        rsp.worker_done.worker_id = (uint32_t)idx;
        rsp.worker_done.exit_code = w->ring->exit_code;
        rsp.worker_done.result_size = w->ring->result_size;

        if (w->ring->result_size > 0) {
            send_response_with_data(&rsp,
                                    w->ring->data + w->ring->result_offset,
                                    w->ring->result_size);
        } else {
            send_response(&rsp);
        }
    }

    /* Reset worker status for next dispatch */
    atomic_store_explicit(&w->ring->status, WORKER_READY,
                          memory_order_release);
    return;

crashed:
    {
        struct response rsp;
        simple_memset(&rsp, 0, sizeof(rsp));
        rsp.type = RSP_WORKER_CRASHED;
        rsp.worker_crashed.worker_id = (uint32_t)idx;
        rsp.worker_crashed.signal = 0;
        send_response(&rsp);
        w->busy = 0;
        w->reserved = 0;
        w->pid = 0;
    }
}

/* ── Handle run command (re-run pre-loaded code) ─────────────────────── */

static void handle_run(const struct command *cmd)
{
    int idx = (int)cmd->run.worker_id;
    if (idx < 0 || idx >= pool_size || workers[idx].pid <= 0) {
        struct response rsp;
        simple_memset(&rsp, 0, sizeof(rsp));
        rsp.type = RSP_ERROR;
        rsp.error.code = -1;
        send_response(&rsp);
        return;
    }

    workers[idx].busy = 1;
    wake_and_wait(idx);
}

/* ── Handle reserve command ──────────────────────────────────────────── */

static void handle_reserve(const struct command *cmd)
{
    int idx;
    uint32_t wid = cmd->reserve_release.worker_id;

    if (wid == (uint32_t)-1) {
        idx = find_idle_worker();
    } else {
        idx = (int)wid;
        if (idx < 0 || idx >= pool_size || workers[idx].pid <= 0)
            idx = -1;
    }

    struct response rsp;
    simple_memset(&rsp, 0, sizeof(rsp));

    if (idx < 0) {
        rsp.type = RSP_ERROR;
        rsp.error.code = -1;
        send_response(&rsp);
        return;
    }

    workers[idx].reserved = 1;

    /* Keep pidfd in epoll — fork server writes CRASHED to ring on death */

    /* Temporarily set dumpable so Haskell can pidfd_getfd our memfds */
    sys_prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);

    rsp.type = RSP_WORKER_RESERVED;
    rsp.worker_reserved.worker_id = (uint32_t)idx;
    rsp.worker_reserved.ring_fd = workers[idx].ring_fd;
    rsp.worker_reserved.code_fd = workers[idx].code_fd;
    rsp.worker_reserved.worker_pid = workers[idx].pid;
    send_response(&rsp);
    dumpable_window = 1;  /* restored to non-dumpable on next command */
}

/* ── Handle release command ──────────────────────────────────────────── */

static void handle_release(const struct command *cmd)
{
    int idx = (int)cmd->reserve_release.worker_id;
    if (idx >= 0 && idx < pool_size) {
        workers[idx].reserved = 0;
        /* pidfd already in epoll — no re-add needed */
    }
}

/* ── Handle status command ───────────────────────────────────────────── */

static void handle_status(void)
{
    struct response rsp;
    simple_memset(&rsp, 0, sizeof(rsp));
    rsp.type = RSP_POOL_STATUS;
    rsp.pool_status.pool_size = (uint32_t)pool_size;

    uint32_t idle = 0, busy = 0, crashed = 0;
    for (int i = 0; i < pool_size; i++) {
        if (workers[i].pid <= 0) { crashed++; continue; }
        if (workers[i].busy) busy++; else idle++;
    }
    rsp.pool_status.idle_count = idle;
    rsp.pool_status.busy_count = busy;
    rsp.pool_status.crashed_count = crashed;
    send_response(&rsp);
}

/* ── Handle worker death (pidfd became readable) ─────────────────────── */

static void handle_worker_death(int pidfd)
{
    for (int i = 0; i < pool_size; i++) {
        if (workers[i].pidfd == pidfd) {
            /* Write CRASHED to ring buffer (Haskell spin loop sees this) */
            atomic_store_explicit(&workers[i].ring->status,
                                  WORKER_CRASHED, memory_order_release);
            /* Wake Haskell if in futex fallback */
            futex_wake(&workers[i].ring->notify, 1);

            /* Only send socketpair response for non-reserved workers */
            if (!workers[i].reserved) {
                struct response rsp;
                simple_memset(&rsp, 0, sizeof(rsp));
                rsp.type = RSP_WORKER_CRASHED;
                rsp.worker_crashed.worker_id = (uint32_t)i;
                rsp.worker_crashed.signal = SIGKILL;
                send_response(&rsp);
            }

            sys_close(workers[i].pidfd);
            workers[i].pidfd = -1;
            workers[i].pid = 0;
            workers[i].busy = 0;
            return;
        }
    }
}

/* ── Main epoll loop ─────────────────────────────────────────────────── */

static void __attribute__((noreturn)) fork_server_main(void)
{
    /* Spawn workers */
    for (int i = 0; i < pool_size; i++) {
        int ret = spawn_worker(i);
        if (ret < 0)
            sys_exit_group(10 + i);

        /* Notify Haskell that worker is ready */
        struct response rsp;
        simple_memset(&rsp, 0, sizeof(rsp));
        rsp.type = RSP_WORKER_READY;
        rsp.worker_ready.worker_id = (uint32_t)i;
        send_response(&rsp);
    }

    /* Fork server: non-dumpable by default. Temporarily set dumpable
     * in handle_reserve so Haskell can pidfd_getfd our memfds. */
    sys_prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);

    /* Create epoll */
    epfd = (int)sys_epoll_create1(0);
    if (epfd < 0)
        sys_exit_group(50);

    /* Add socketpair fd */
    {
        struct epoll_event ev;
        ev.events = EPOLLIN;
        ev.data.fd = sock_fd;
        sys_epoll_ctl(epfd, EPOLL_CTL_ADD, sock_fd, &ev);
    }

    /* Add pipe fd (parent liveness) */
    {
        struct epoll_event ev;
        ev.events = EPOLLIN | EPOLLHUP;
        ev.data.fd = pipe_fd;
        sys_epoll_ctl(epfd, EPOLL_CTL_ADD, pipe_fd, &ev);
    }

    /* Add worker pidfds */
    for (int i = 0; i < pool_size; i++) {
        if (workers[i].pidfd >= 0) {
            struct epoll_event ev;
            ev.events = EPOLLIN;
            ev.data.fd = workers[i].pidfd;
            sys_epoll_ctl(epfd, EPOLL_CTL_ADD, workers[i].pidfd, &ev);
        }
    }

    /* Event loop */
    struct epoll_event events[16];
    for (;;) {
        long n = sys_epoll_wait(epfd, events, 16, -1);
        if (n < 0) continue;  /* EINTR */

        for (long i = 0; i < n; i++) {
            int fd = events[i].data.fd;
            uint32_t ev = events[i].events;

            if (fd == pipe_fd) {
                /* Parent died */
                sys_exit_group(0);
            }

            if (fd == sock_fd) {
                if (ev & (EPOLLHUP | EPOLLERR))
                    sys_exit_group(0);

                struct command cmd;
                long r = read_full(sock_fd, &cmd, sizeof(cmd));
                if (r <= 0)
                    sys_exit_group(0);

                /* Close dumpable window after Haskell has done pidfd_getfd */
                if (dumpable_window) {
                    sys_prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
                    dumpable_window = 0;
                }

                switch (cmd.type) {
                case CMD_DISPATCH:
                    handle_dispatch(&cmd);
                    break;
                case CMD_RUN:
                    handle_run(&cmd);
                    break;
                case CMD_RESERVE:
                    handle_reserve(&cmd);
                    break;
                case CMD_RELEASE:
                    handle_release(&cmd);
                    break;
                case CMD_STATUS:
                    handle_status();
                    break;
                case CMD_SHUTDOWN:
                    sys_exit_group(0);
                    break;
                }
                continue;
            }

            /* Must be a worker pidfd */
            if (ev & EPOLLIN)
                handle_worker_death(fd);
        }
    }
}

/* ── Entry point ─────────────────────────────────────────────────────── */

__attribute__((noreturn, used)) void real_start(unsigned long *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);

    if (argc < 8)
        sys_exit_group(1);

    sock_fd          = simple_atoi(argv[1]);
    pipe_fd          = simple_atoi(argv[2]);
    pool_size        = simple_atoi(argv[3]);
    injection_cap    = simple_atoi(argv[4]);
    code_region_size = (unsigned long)simple_atoi(argv[5]);
    ring_buf_size    = (unsigned long)simple_atoi(argv[6]);
    spin_count       = (unsigned int)simple_atoi(argv[7]);

    if (pool_size <= 0 || pool_size > MAX_WORKERS)
        sys_exit_group(2);

    /* Die if parent thread exits (belt-and-suspenders with pipe trick).
     * Safe because Haskell side uses runInBoundThread, so the OS thread
     * that vfork'd us stays alive for the Hatchery's lifetime. */
    sys_prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0);
    if (ring_buf_size < sizeof(struct ring_buffer))
        sys_exit_group(3);

    fork_server_main();
}

/* naked _start: capture RSP before the compiler adds a prologue */
__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile(
        "mov %%rsp, %%rdi\n"  /* pass original sp as first arg */
        "call real_start\n"
        ::: "memory"
    );
}
