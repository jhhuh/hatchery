/* syscall.h — raw x86_64 Linux syscall wrappers, no libc dependency */
#ifndef HATCHERY_SYSCALL_H
#define HATCHERY_SYSCALL_H

#include <linux/types.h>

/* ── Syscall numbers (x86_64) ─────────────────────────────────────── */

#define __NR_read              0
#define __NR_write             1
#define __NR_close             3
#define __NR_mmap              9
#define __NR_munmap            11
#define __NR_dup2              33
#define __NR_getpid            39
#define __NR_fork              57
#define __NR_execveat          322
#define __NR_clone3            435
#define __NR_exit_group        231
#define __NR_futex             202
#define __NR_epoll_create1     291
#define __NR_epoll_ctl         233
#define __NR_epoll_wait        232
#define __NR_prctl             157
#define __NR_process_vm_writev 311
#define __NR_pidfd_open        434
#define __NR_socketpair        53
#define __NR_pipe2             293
#define __NR_waitid            247
#define __NR_kill              62
#define __NR_memfd_create      319
#define __NR_fcntl             72

/* ── Inline syscall primitives ────────────────────────────────────── */
/*
 * x86_64 syscall ABI:
 *   nr  → rax
 *   args → rdi, rsi, rdx, r10, r8, r9
 *   ret  → rax
 *   clobbers: rcx, r11
 */

static inline long sys_call0(long nr)
{
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call1(long nr, long a0)
{
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call2(long nr, long a0, long a1)
{
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call3(long nr, long a0, long a1, long a2)
{
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call4(long nr, long a0, long a1, long a2, long a3)
{
    register long r10 __asm__("r10") = a3;
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call5(long nr, long a0, long a1, long a2, long a3,
                              long a4)
{
    register long r10 __asm__("r10") = a3;
    register long r8  __asm__("r8")  = a4;
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8)
        : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call6(long nr, long a0, long a1, long a2, long a3,
                              long a4, long a5)
{
    register long r10 __asm__("r10") = a3;
    register long r8  __asm__("r8")  = a4;
    register long r9  __asm__("r9")  = a5;
    long ret;
    __asm__ volatile("syscall"
        : "=a"(ret)
        : "a"(nr), "D"(a0), "S"(a1), "d"(a2), "r"(r10), "r"(r8), "r"(r9)
        : "rcx", "r11", "memory");
    return ret;
}

/* ── Convenience wrappers ─────────────────────────────────────────── */

static inline long sys_read(int fd, void *buf, unsigned long count)
{
    return sys_call3(__NR_read, fd, (long)buf, (long)count);
}

static inline long sys_write(int fd, const void *buf, unsigned long count)
{
    return sys_call3(__NR_write, fd, (long)buf, (long)count);
}

static inline long sys_close(int fd)
{
    return sys_call1(__NR_close, fd);
}

static inline void *sys_mmap(void *addr, unsigned long len, int prot,
                              int flags, int fd, long off)
{
    return (void *)sys_call6(__NR_mmap, (long)addr, (long)len,
                             (long)prot, (long)flags, (long)fd, off);
}

static inline long sys_munmap(void *addr, unsigned long len)
{
    return sys_call2(__NR_munmap, (long)addr, (long)len);
}

static inline void __attribute__((noreturn)) sys_exit_group(int status)
{
    sys_call1(__NR_exit_group, status);
    __builtin_unreachable();
}

static inline long sys_clone3(void *cl_args, unsigned long size)
{
    return sys_call2(__NR_clone3, (long)cl_args, (long)size);
}

static inline long sys_execveat(int dirfd, const char *pathname,
                                 char *const argv[], char *const envp[],
                                 int flags)
{
    return sys_call5(__NR_execveat, (long)dirfd, (long)pathname,
                     (long)argv, (long)envp, (long)flags);
}

static inline long sys_memfd_create(const char *name, unsigned int flags)
{
    return sys_call2(__NR_memfd_create, (long)name, (long)flags);
}

static inline long sys_futex(int *uaddr, int op, int val,
                              const void *timeout, int *uaddr2, int val3)
{
    return sys_call6(__NR_futex, (long)uaddr, (long)op, (long)val,
                     (long)timeout, (long)uaddr2, (long)val3);
}

static inline long sys_epoll_create1(int flags)
{
    return sys_call1(__NR_epoll_create1, flags);
}

static inline long sys_epoll_ctl(int epfd, int op, int fd, void *event)
{
    return sys_call4(__NR_epoll_ctl, (long)epfd, (long)op, (long)fd,
                     (long)event);
}

static inline long sys_epoll_wait(int epfd, void *events, int maxevents,
                                   int timeout)
{
    return sys_call4(__NR_epoll_wait, (long)epfd, (long)events,
                     (long)maxevents, (long)timeout);
}

static inline long sys_prctl(int option, unsigned long a2, unsigned long a3,
                              unsigned long a4, unsigned long a5)
{
    return sys_call5(__NR_prctl, (long)option, a2, a3, a4, a5);
}

static inline long sys_process_vm_writev(int pid, const void *lvec,
                                          unsigned long liovcnt,
                                          const void *rvec,
                                          unsigned long riovcnt,
                                          unsigned long flags)
{
    return sys_call6(__NR_process_vm_writev, (long)pid, (long)lvec,
                     (long)liovcnt, (long)rvec, (long)riovcnt, (long)flags);
}

static inline long sys_pidfd_open(int pid, unsigned int flags)
{
    return sys_call2(__NR_pidfd_open, (long)pid, (long)flags);
}

static inline long sys_socketpair(int domain, int type, int protocol,
                                   int sv[2])
{
    return sys_call4(__NR_socketpair, (long)domain, (long)type,
                     (long)protocol, (long)sv);
}

static inline long sys_pipe2(int pipefd[2], int flags)
{
    return sys_call2(__NR_pipe2, (long)pipefd, (long)flags);
}

static inline long sys_waitid(int idtype, int id, void *infop, int options,
                               void *rusage)
{
    return sys_call5(__NR_waitid, (long)idtype, (long)id, (long)infop,
                     (long)options, (long)rusage);
}

static inline long sys_kill(int pid, int sig)
{
    return sys_call2(__NR_kill, (long)pid, (long)sig);
}

static inline long sys_getpid(void)
{
    return sys_call0(__NR_getpid);
}

static inline long sys_fork(void)
{
    return sys_call0(__NR_fork);
}

static inline long sys_dup2(int oldfd, int newfd)
{
    return sys_call2(__NR_dup2, (long)oldfd, (long)newfd);
}

static inline long sys_fcntl(int fd, int cmd, long arg)
{
    return sys_call3(__NR_fcntl, (long)fd, (long)cmd, arg);
}

#endif /* HATCHERY_SYSCALL_H */
