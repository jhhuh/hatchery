#ifndef HATCHERY_RING_BUFFER_H
#define HATCHERY_RING_BUFFER_H

#include "ring_buffer_layout.h"
#include "syscall.h"
#include <linux/futex.h>

static inline void futex_wait(_Atomic uint32_t *addr, uint32_t expected) {
    sys_futex((uint32_t *)addr, FUTEX_WAIT, expected, 0, 0, 0);
}

static inline void futex_wake(_Atomic uint32_t *addr, int count) {
    sys_futex((uint32_t *)addr, FUTEX_WAKE, count, 0, 0, 0);
}

#endif /* HATCHERY_RING_BUFFER_H */
