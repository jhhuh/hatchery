#ifndef HATCHERY_RING_BUFFER_H
#define HATCHERY_RING_BUFFER_H

#include <stdint.h>
#include <stdatomic.h>
#include "syscall.h"
#include <linux/futex.h>

enum worker_control {
    WORKER_IDLE  = 0,
    WORKER_RUN   = 1,
    WORKER_STOP  = 2,
};

enum worker_status {
    WORKER_INIT    = 0,
    WORKER_READY   = 1,
    WORKER_BUSY    = 2,
    WORKER_DONE    = 3,
    WORKER_CRASHED = 4,
};

enum injection_method {
    INJECT_PROCESS_VM_WRITEV = 0,
    INJECT_SHARED_MEMFD      = 1,
};

struct ring_buffer {
    /* Control (cache-line aligned) */
    _Alignas(64) _Atomic uint32_t control;   /* futex word: IDLE/RUN/STOP */
    _Alignas(64) _Atomic uint32_t notify;    /* futex word: worker -> parent */
    _Alignas(64) _Atomic uint32_t status;    /* READY/BUSY/DONE/CRASHED */

    /* Worker info (written once at init) */
    uint64_t code_base;          /* address of executable region in worker */
    uint64_t code_size;          /* size of code region */

    /* Dispatch info (written by fork server per dispatch) */
    uint32_t injection_method;   /* which method was used */
    uint32_t code_len;           /* actual length of injected code */

    /* Spin mode: set by fork server when worker is reserved + spin_count > 0.
     * Worker skips futex_wake on notify when set. */
    uint32_t spin_mode;

    /* Result (written by worker) */
    int32_t  exit_code;
    uint32_t result_offset;      /* offset into data[] for result */
    uint32_t result_size;

    /* Data region (bulk transfer) */
    _Alignas(64) uint8_t data[];
};

static inline void futex_wait(_Atomic uint32_t *addr, uint32_t expected) {
    sys_futex((uint32_t *)addr, FUTEX_WAIT, expected, 0, 0, 0);
}

static inline void futex_wake(_Atomic uint32_t *addr, int count) {
    sys_futex((uint32_t *)addr, FUTEX_WAKE, count, 0, 0, 0);
}

#endif /* HATCHERY_RING_BUFFER_H */
