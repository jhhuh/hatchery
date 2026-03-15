/* direct_helpers.c — C helpers for direct Haskell↔worker dispatch
 *
 * Compiled by GHC/cabal as normal C (NOT musl-gcc).
 * Provides futex, pidfd_getfd, mmap wrappers callable from Haskell FFI.
 */

#define _GNU_SOURCE
#include <sys/syscall.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <signal.h>
#include <linux/futex.h>
#include <time.h>

/* Ring buffer offsets (must match ring_buffer.h) */
#define RING_CONTROL_OFF    0
#define RING_NOTIFY_OFF    64
#define RING_STATUS_OFF   128
#define RING_EXIT_CODE_OFF 216
#define RING_RESULT_OFF_OFF 220
#define RING_RESULT_SIZE_OFF 224
#define RING_DATA_OFF      256

/* Worker states */
#define WORKER_IDLE  0
#define WORKER_RUN   1
#define WORKER_READY 1
#define WORKER_DONE  3

int hatchery_pidfd_getfd(int pidfd, int targetfd)
{
    return (int)syscall(438 /*__NR_pidfd_getfd*/, pidfd, targetfd, 0);
}

int hatchery_pidfd_open(int pid)
{
    return (int)syscall(434 /*__NR_pidfd_open*/, pid, 0);
}

void *hatchery_mmap_ring(int fd, unsigned long size)
{
    return mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
}

int hatchery_munmap_ring(void *addr, unsigned long size)
{
    return munmap(addr, size);
}

/* Wake worker: store WORKER_RUN in control, futex_wake */
void hatchery_wake_worker(void *ring_base)
{
    uint32_t *control = (uint32_t *)((char *)ring_base + RING_CONTROL_OFF);
    __atomic_store_n(control, WORKER_RUN, __ATOMIC_RELEASE);
    syscall(__NR_futex, control, FUTEX_WAKE, 1, NULL, NULL, 0);
}

/* Wait for worker completion. Returns:
 *  0 = done (exit_code written to *out_exit_code)
 * -1 = worker crashed/dead  */
int hatchery_wait_worker(void *ring_base, int worker_pid, int *out_exit_code)
{
    uint32_t *status = (uint32_t *)((char *)ring_base + RING_STATUS_OFF);
    uint32_t *notify = (uint32_t *)((char *)ring_base + RING_NOTIFY_OFF);

    for (;;) {
        uint32_t st = __atomic_load_n(status, __ATOMIC_ACQUIRE);
        if (st == WORKER_DONE) {
            int32_t *ec = (int32_t *)((char *)ring_base + RING_EXIT_CODE_OFF);
            *out_exit_code = *ec;

            /* Reset for next run */
            __atomic_store_n(notify, 0, __ATOMIC_RELEASE);
            __atomic_store_n(status, WORKER_READY, __ATOMIC_RELEASE);
            return 0;
        }

        /* Check if worker is still alive */
        if (kill(worker_pid, 0) < 0)
            return -1;

        /* Wait on notify with 100ms timeout */
        uint32_t nv = __atomic_load_n(notify, __ATOMIC_ACQUIRE);
        if (nv == 0) {
            struct timespec ts = { 0, 100000000L };
            syscall(__NR_futex, notify, FUTEX_WAIT, 0, &ts, NULL, 0);
        }
    }
}

/* Safe futex wait on notify field with 100ms timeout.
 * Intended for safe FFI call (releases GHC capability during wait). */
int hatchery_futex_wait_safe(void *ring_base)
{
    uint32_t *notify = (uint32_t *)((char *)ring_base + RING_NOTIFY_OFF);
    uint32_t nv = __atomic_load_n(notify, __ATOMIC_ACQUIRE);
    if (nv == 0) {
        struct timespec ts = { 0, 100000000L };
        syscall(__NR_futex, notify, FUTEX_WAIT, 0, &ts, NULL, 0);
    }
    return 0;
}

/* Seq_cst atomic helpers for Cmm spin loop */
uint32_t hatchery_atomic_read32(void *addr)
{
    return __atomic_load_n((uint32_t *)addr, __ATOMIC_SEQ_CST);
}

void hatchery_atomic_write32(void *addr, uint32_t val)
{
    __atomic_store_n((uint32_t *)addr, val, __ATOMIC_SEQ_CST);
}

/* Read result_size from ring buffer */
uint32_t hatchery_result_size(void *ring_base)
{
    uint32_t *rs = (uint32_t *)((char *)ring_base + RING_RESULT_SIZE_OFF);
    return *rs;
}

/* Get pointer to result data in ring buffer */
void *hatchery_result_data(void *ring_base)
{
    uint32_t *ro = (uint32_t *)((char *)ring_base + RING_RESULT_OFF_OFF);
    return (char *)ring_base + RING_DATA_OFF + *ro;
}
