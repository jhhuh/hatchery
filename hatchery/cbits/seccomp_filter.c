/* seccomp_filter.c — BPF seccomp filter for sandboxed workers */

#include "syscall.h"

#include <stdint.h>

/* ── Seccomp / prctl constants ───────────────────────────────────────── */

#define SECCOMP_MODE_FILTER   2
#define SECCOMP_RET_ALLOW     0x7fff0000
#define SECCOMP_RET_KILL_PROCESS 0x80000000U
#define PR_SET_NO_NEW_PRIVS   38
#define PR_SET_SECCOMP        22

/* ── BPF instruction macros ──────────────────────────────────────────── */

#define BPF_LD   0x00
#define BPF_W    0x00
#define BPF_ABS  0x20
#define BPF_JMP  0x05
#define BPF_JEQ  0x10
#define BPF_K    0x00
#define BPF_RET  0x06

#define BPF_STMT(code, k) \
    { (unsigned short)(code), 0, 0, (unsigned int)(k) }
#define BPF_JUMP(code, k, jt, jf) \
    { (unsigned short)(code), (unsigned char)(jt), (unsigned char)(jf), (unsigned int)(k) }

/* ── BPF structs ─────────────────────────────────────────────────────── */

struct sock_filter {
    uint16_t code;
    uint8_t  jt;
    uint8_t  jf;
    uint32_t k;
};

struct sock_fprog {
    unsigned short      len;
    struct sock_filter *filter;
};

/* offsetof(struct seccomp_data, nr) == 0 */
#define SECCOMP_DATA_NR_OFFSET 0

/* ── Allowed syscall numbers (x86_64) ────────────────────────────────── */
/*
 *  read          0
 *  write         1
 *  mmap          9
 *  munmap       11
 *  rt_sigreturn 15
 *  futex       202
 *  clock_gettime 228
 *  exit_group  231
 */

#define NUM_ALLOWED 8

static struct sock_filter filter_insns[] = {
    /* [0] Load syscall number */
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR_OFFSET),

    /* [1..8] Check each allowed syscall; jump to ALLOW if match */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,   0, NUM_ALLOWED, 0), /* read */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,   1, NUM_ALLOWED - 1, 0), /* write */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,   9, NUM_ALLOWED - 2, 0), /* mmap */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,  11, NUM_ALLOWED - 3, 0), /* munmap */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,  15, NUM_ALLOWED - 4, 0), /* rt_sigreturn */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 202, NUM_ALLOWED - 5, 0), /* futex */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 228, NUM_ALLOWED - 6, 0), /* clock_gettime */
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 231, NUM_ALLOWED - 7, 0), /* exit_group */

    /* [9] Default: kill process */
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),

    /* [10] Allow */
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
};

/* ── Public API ──────────────────────────────────────────────────────── */

int install_seccomp_filter(void)
{
    struct sock_fprog prog = {
        .len    = sizeof(filter_insns) / sizeof(filter_insns[0]),
        .filter = filter_insns,
    };

    /* Required before installing a seccomp filter */
    if (sys_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0)
        return -1;

    if (sys_prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER,
                  (unsigned long)&prog, 0, 0) < 0)
        return -1;

    return 0;
}
