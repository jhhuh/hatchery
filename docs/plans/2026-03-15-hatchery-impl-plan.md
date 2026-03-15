# Hatchery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Linux process sandbox toolkit for Haskell with microsecond dispatch latency, dual code injection methods, and LLVM JIT codegen support.

**Architecture:** A fork server (static-PIE C binary, embedded via file-embed) manages a pool of pre-spawned workers in a PID namespace. Workers execute raw machine code injected via `process_vm_writev` or shared memfd. Communication uses socketpair (control) + shared ring buffer (data). `llvm-tf` provides runtime codegen through a bridge package.

**Tech Stack:** Haskell (GHC, Cabal), C (musl-gcc, static-PIE), Linux syscalls (memfd, futex, epoll, pidfd, seccomp, clone), LLVM 16 (llvm-tf), Nix flake for reproducibility.

**Reference:** `PLAN.md` is the authoritative architecture document. `docs/plans/2026-03-15-hatchery-phase1-design.md` has resolved design decisions.

---

### Task 1: Initialize git repo and Nix flake

**Files:**
- Create: `flake.nix`
- Create: `.envrc`
- Create: `.gitignore`

**Step 1: Initialize git repo**

```bash
cd /home/jhhuh/Sync/proj/hatchery
git init
```

**Step 2: Create `.gitignore`**

```gitignore
dist-newstyle/
result
result-*
*.o
*.hi
*.dyn_o
*.dyn_hi
fork_server
worker_template
.direnv/
```

**Step 3: Create `flake.nix`**

```nix
{
  description = "hatchery - process sandbox toolkit for Haskell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        musl-pkgs = pkgs.pkgsStatic;
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Haskell
            pkgs.ghc
            pkgs.cabal-install
            pkgs.haskellPackages.file-embed

            # C (musl static-PIE)
            musl-pkgs.stdenv.cc

            # LLVM 16 (for llvm-tf)
            pkgs.llvmPackages_16.llvm

            # Dev tools
            pkgs.overmind
            pkgs.tmux

            # For assembling test payloads
            pkgs.nasm
          ];

          shellHook = ''
            export MUSL_CC="${musl-pkgs.stdenv.cc}/bin/x86_64-unknown-linux-musl-cc"
          '';
        };
      });
}
```

**Step 4: Create `.envrc`**

```
use flake
```

**Step 5: Verify flake builds**

Run: `nix develop -c bash -c 'echo "GHC: $(ghc --version)"; echo "MUSL_CC: $MUSL_CC"; echo "LLVM: $(llvm-config --version)"'`
Expected: GHC version, MUSL_CC path, LLVM 16.x version printed.

**Step 6: Commit**

```bash
git add flake.nix .envrc .gitignore PLAN.md CLAUDE.md docs/
git commit -m "init: nix flake with ghc, musl-gcc, llvm-16, cabal"
```

---

### Task 2: C headers — `syscall.h`

**Files:**
- Create: `hatchery/cbits/syscall.h`

**Step 1: Write `syscall.h`**

Raw syscall wrappers (no libc). Must cover: `write`, `read`, `mmap`, `munmap`, `exit_group`, `clone`, `clone3`, `execveat`, `memfd_create`, `futex`, `epoll_create1`, `epoll_ctl`, `epoll_wait`, `prctl`, `process_vm_writev`, `pidfd_open`, `close`, `socketpair`, `pipe2`, `waitid`, `kill`, `getpid`.

```c
#ifndef HATCHERY_SYSCALL_H
#define HATCHERY_SYSCALL_H

#include <stdint.h>
#include <stddef.h>
#include <linux/unistd.h>

static inline long sys_call0(long n) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n) : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call1(long n, long a1) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1) : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call2(long n, long a1, long a2) {
    long ret;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2) : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call3(long n, long a1, long a2, long a3) {
    long ret;
    register long r10 __asm__("r10") = a3;
    /* r10 cannot go in "D","S","d" — must use register variable */
    (void)r10;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3)
                     : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call4(long n, long a1, long a2, long a3, long a4) {
    long ret;
    register long r10 __asm__("r10") = a4;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10)
                     : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call5(long n, long a1, long a2, long a3, long a4, long a5) {
    long ret;
    register long r10 __asm__("r10") = a4;
    register long r8 __asm__("r8") = a5;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8)
                     : "rcx", "r11", "memory");
    return ret;
}

static inline long sys_call6(long n, long a1, long a2, long a3, long a4, long a5, long a6) {
    long ret;
    register long r10 __asm__("r10") = a4;
    register long r8 __asm__("r8") = a5;
    register long r9 __asm__("r9") = a6;
    __asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a1), "S"(a2), "d"(a3), "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "memory");
    return ret;
}

/* Convenience wrappers */

#define sys_read(fd, buf, count) \
    sys_call3(__NR_read, (long)(fd), (long)(buf), (long)(count))

#define sys_write(fd, buf, count) \
    sys_call3(__NR_write, (long)(fd), (long)(buf), (long)(count))

#define sys_close(fd) \
    sys_call1(__NR_close, (long)(fd))

#define sys_mmap(addr, len, prot, flags, fd, off) \
    sys_call6(__NR_mmap, (long)(addr), (long)(len), (long)(prot), (long)(flags), (long)(fd), (long)(off))

#define sys_munmap(addr, len) \
    sys_call2(__NR_munmap, (long)(addr), (long)(len))

#define sys_exit_group(status) \
    sys_call1(__NR_exit_group, (long)(status))

#define sys_clone3(cl_args, size) \
    sys_call2(__NR_clone3, (long)(cl_args), (long)(size))

#define sys_execveat(dirfd, path, argv, envp, flags) \
    sys_call5(__NR_execveat, (long)(dirfd), (long)(path), (long)(argv), (long)(envp), (long)(flags))

#define sys_memfd_create(name, flags) \
    sys_call2(__NR_memfd_create, (long)(name), (long)(flags))

#define sys_futex(uaddr, op, val, timeout, uaddr2, val3) \
    sys_call6(__NR_futex, (long)(uaddr), (long)(op), (long)(val), (long)(timeout), (long)(uaddr2), (long)(val3))

#define sys_epoll_create1(flags) \
    sys_call1(__NR_epoll_create1, (long)(flags))

#define sys_epoll_ctl(epfd, op, fd, event) \
    sys_call4(__NR_epoll_ctl, (long)(epfd), (long)(op), (long)(fd), (long)(event))

#define sys_epoll_wait(epfd, events, maxevents, timeout) \
    sys_call4(__NR_epoll_wait, (long)(epfd), (long)(events), (long)(maxevents), (long)(timeout))

#define sys_prctl(option, arg2, arg3, arg4, arg5) \
    sys_call5(__NR_prctl, (long)(option), (long)(arg2), (long)(arg3), (long)(arg4), (long)(arg5))

#define sys_process_vm_writev(pid, lvec, liovcnt, rvec, riovcnt, flags) \
    sys_call6(__NR_process_vm_writev, (long)(pid), (long)(lvec), (long)(liovcnt), (long)(rvec), (long)(riovcnt), (long)(flags))

#define sys_pidfd_open(pid, flags) \
    sys_call2(__NR_pidfd_open, (long)(pid), (long)(flags))

#define sys_socketpair(domain, type, protocol, sv) \
    sys_call4(__NR_socketpair, (long)(domain), (long)(type), (long)(protocol), (long)(sv))

#define sys_pipe2(pipefd, flags) \
    sys_call2(__NR_pipe2, (long)(pipefd), (long)(flags))

#define sys_waitid(idtype, id, infop, options, rusage) \
    sys_call5(__NR_waitid, (long)(idtype), (long)(id), (long)(infop), (long)(options), (long)(rusage))

#define sys_kill(pid, sig) \
    sys_call2(__NR_kill, (long)(pid), (long)(sig))

#define sys_getpid() \
    sys_call0(__NR_getpid)

#define sys_fork() \
    sys_call0(__NR_fork)

#define sys_dup2(oldfd, newfd) \
    sys_call2(__NR_dup2, (long)(oldfd), (long)(newfd))

#define sys_fcntl(fd, cmd, arg) \
    sys_call3(__NR_fcntl, (long)(fd), (long)(cmd), (long)(arg))

#endif /* HATCHERY_SYSCALL_H */
```

**Step 2: Verify it compiles (header-only, include in a trivial .c)**

Create a test file `hatchery/cbits/test_syscall.c`:
```c
#include "syscall.h"
void _start(void) { sys_exit_group(0); }
```

Run: `nix develop -c bash -c '$MUSL_CC -static-pie -nostartfiles -fPIE -Os -Wall -Werror -o /dev/null hatchery/cbits/test_syscall.c'`
Expected: compiles with no warnings.

**Step 3: Remove test file, commit**

```bash
rm hatchery/cbits/test_syscall.c
git add hatchery/cbits/syscall.h
git commit -m "feat(cbits): raw syscall wrappers for x86_64 linux"
```

---

### Task 3: C headers — `ring_buffer.h`

**Files:**
- Create: `hatchery/cbits/ring_buffer.h`

**Step 1: Write `ring_buffer.h`**

```c
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
```

**Step 2: Verify compiles**

Same pattern as Task 2: include in a trivial .c file, compile with musl-gcc, verify no warnings.

**Step 3: Commit**

```bash
git add hatchery/cbits/ring_buffer.h
git commit -m "feat(cbits): ring buffer struct with futex helpers"
```

---

### Task 4: C headers — `protocol.h`

**Files:**
- Create: `hatchery/cbits/protocol.h`

**Step 1: Write `protocol.h`**

Fixed-size command/response structs for the socketpair wire format.

```c
#ifndef HATCHERY_PROTOCOL_H
#define HATCHERY_PROTOCOL_H

#include <stdint.h>

/* Commands: Haskell -> fork server */
enum cmd_type {
    CMD_DISPATCH  = 1,  /* dispatch code to worker */
    CMD_STATUS    = 2,  /* request pool status */
    CMD_SHUTDOWN  = 3,  /* graceful shutdown */
};

struct cmd_dispatch {
    uint32_t worker_id;
    uint32_t injection_method;  /* enum injection_method */
    uint32_t code_len;
    /* code bytes follow immediately after this struct if using socketpair transport */
};

struct command {
    uint32_t type;  /* enum cmd_type */
    union {
        struct cmd_dispatch dispatch;
        /* status and shutdown have no payload */
    };
};

/* Responses: fork server -> Haskell */
enum rsp_type {
    RSP_WORKER_READY   = 1,
    RSP_WORKER_DONE    = 2,
    RSP_WORKER_CRASHED = 3,
    RSP_POOL_STATUS    = 4,
    RSP_ERROR          = 5,
};

struct rsp_worker_done {
    uint32_t worker_id;
    int32_t  exit_code;
    uint32_t result_size;
    /* result bytes follow if result_size > 0 */
};

struct rsp_worker_crashed {
    uint32_t worker_id;
    int32_t  signal;
};

struct rsp_pool_status {
    uint32_t pool_size;
    uint32_t idle_count;
    uint32_t busy_count;
    uint32_t crashed_count;
};

struct response {
    uint32_t type;  /* enum rsp_type */
    union {
        struct { uint32_t worker_id; } worker_ready;
        struct rsp_worker_done worker_done;
        struct rsp_worker_crashed worker_crashed;
        struct rsp_pool_status pool_status;
        struct { int32_t code; } error;
    };
};

#endif /* HATCHERY_PROTOCOL_H */
```

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/cbits/protocol.h
git commit -m "feat(cbits): command/response wire protocol"
```

---

### Task 5: Fork server — `fork_server.c`

**Files:**
- Create: `hatchery/cbits/fork_server.c`

This is the largest C file. It contains both the fork server `_start` and `worker_main`.

**Step 1: Write `fork_server.c`**

Core responsibilities:
- Parse fd arguments (socketpair fd, pipe fd, pool config) from argv
- Pre-spawn workers via `fork()`, each entering `worker_main()`
- Worker setup: mmap code region (anonymous or memfd-backed based on config), mmap ring buffer from inherited memfd fd, signal ready
- Worker loop: futex_wait, execute code at code_base, write result, futex_wake
- Fork server epoll loop: handle commands from socketpair, handle pipe POLLHUP (parent death), handle worker pidfd events
- Dispatch handler: for `process_vm_writev` path, write code bytes into worker code region cross-process; for memfd path, write to the memfd fd. Set ring control to RUN, futex_wake worker.
- Worker death handler: waitid, update state, respond to Haskell

The code should be the minimal working version for Phase 1 (single dispatch type, basic pool). Full implementation per `PLAN.md` architecture.

**Step 2: Compile test**

Run: `nix develop -c bash -c '$MUSL_CC -static-pie -nostartfiles -fPIE -Os -Wall -o hatchery/cbits/fork_server hatchery/cbits/fork_server.c'`
Expected: produces `fork_server` static-PIE ELF.

**Step 3: Verify it's a static PIE**

Run: `file hatchery/cbits/fork_server`
Expected: "ELF 64-bit LSB pie executable, x86-64, ... statically linked"

**Step 4: Commit**

```bash
git add hatchery/cbits/fork_server.c
git commit -m "feat(cbits): fork server with worker pool and dual injection"
```

---

### Task 6: Seccomp filter — `seccomp_filter.c` + `seccomp_filter.h`

**Files:**
- Create: `hatchery/cbits/seccomp_filter.h`
- Create: `hatchery/cbits/seccomp_filter.c`

**Step 1: Write seccomp BPF filter**

Minimal whitelist for workers: `read`, `write`, `mmap` (anonymous only), `munmap`, `exit_group`, `futex`, `clock_gettime`. Everything else → SIGKILL.

**Step 2: Verify compiles into fork_server**

**Step 3: Commit**

```bash
git add hatchery/cbits/seccomp_filter.h hatchery/cbits/seccomp_filter.c
git commit -m "feat(cbits): seccomp BPF filter for workers"
```

---

### Task 7: `cbits/Makefile`

**Files:**
- Create: `hatchery/cbits/Makefile`

**Step 1: Write Makefile**

```makefile
CC ?= $(MUSL_CC)
CFLAGS = -static-pie -nostartfiles -fPIE -Os -Wall -Werror

fork_server: fork_server.c seccomp_filter.c syscall.h ring_buffer.h protocol.h seccomp_filter.h
	$(CC) $(CFLAGS) -o $@ fork_server.c seccomp_filter.c

.PHONY: clean
clean:
	rm -f fork_server
```

**Step 2: Build via Makefile**

Run: `nix develop -c make -C hatchery/cbits`
Expected: `fork_server` binary produced.

**Step 3: Commit**

```bash
git add hatchery/cbits/Makefile
git commit -m "feat(cbits): makefile for static-PIE fork server"
```

---

### Task 8: Haskell scaffolding — `cabal.project`, `hatchery.cabal`

**Files:**
- Create: `cabal.project`
- Create: `hatchery/hatchery.cabal`
- Create: `hatchery/src/Hatchery.hs` (stub)

**Step 1: Write `cabal.project`**

```
packages:
  hatchery/
```

**Step 2: Write `hatchery/hatchery.cabal`**

Per PLAN.md specification. Include `c-sources: cbits/vfork_helper.c`. Add `file-embed` dependency.

**Step 3: Write stub `Hatchery.hs`**

```haskell
module Hatchery where
```

**Step 4: Verify cabal can parse the project**

Run: `nix develop -c cabal build hatchery --dry-run`
Expected: dependency resolution succeeds.

**Step 5: Commit**

```bash
git add cabal.project hatchery/hatchery.cabal hatchery/src/Hatchery.hs
git commit -m "feat: haskell scaffolding with cabal project"
```

---

### Task 9: `vfork_helper.c` — C helper for spawning fork server

**Files:**
- Create: `hatchery/cbits/vfork_helper.c`

**Step 1: Write `vfork_helper.c`**

C function callable from Haskell FFI:
- Creates memfd, writes fork server ELF into it, seals it
- Creates socketpair (AF_UNIX, SOCK_SEQPACKET)
- Creates pipe for parent-liveness detection
- `vfork()` + `execveat(memfd_fd, "", ...)` with `AT_EMPTY_PATH`
- Returns: fork server PID, socketpair fd, pipe fd

```c
#include <sys/socket.h>
#include <sys/mman.h>
#include <linux/memfd.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

struct fork_server_fds {
    int pid;
    int sock_fd;    /* our end of socketpair */
    int pipe_rd;    /* our end of liveness pipe (we hold read end; fork server holds write end... actually reversed) */
};

/* Returns 0 on success, -errno on failure */
int spawn_fork_server(
    const unsigned char *elf_data,
    unsigned int elf_size,
    int pool_size,
    int injection_capability,  /* 0=vm_writev, 1=memfd, 2=both */
    struct fork_server_fds *out
);
```

**Step 2: Verify compiles with cabal**

Run: `nix develop -c cabal build hatchery`
Expected: compiles (even though Haskell side is stub).

**Step 3: Commit**

```bash
git add hatchery/cbits/vfork_helper.c
git commit -m "feat(cbits): vfork helper for spawning fork server from Haskell"
```

---

### Task 10: `Hatchery.Internal.Embedded`

**Files:**
- Create: `hatchery/src/Hatchery/Internal/Embedded.hs`

**Step 1: Write Embedded.hs**

```haskell
module Hatchery.Internal.Embedded (forkServerELF) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)

forkServerELF :: ByteString
forkServerELF = $(embedFile "cbits/fork_server")
```

**Step 2: Build the fork_server binary first, then verify TH embedding works**

Run: `nix develop -c bash -c 'make -C hatchery/cbits && cabal build hatchery'`
Expected: compiles — Template Haskell embeds the fork_server binary.

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Internal/Embedded.hs
git commit -m "feat: embed fork server ELF via Template Haskell"
```

---

### Task 11: `Hatchery.Internal.Memfd`

**Files:**
- Create: `hatchery/src/Hatchery/Internal/Memfd.hs`

**Step 1: Write Memfd.hs**

FFI bindings for `memfd_create` and `fcntl` sealing. Used by the Haskell side to create memfds for ring buffers and (in BothMethods/SharedMemfdOnly mode) code regions.

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Internal/Memfd.hs
git commit -m "feat: memfd_create and sealing FFI bindings"
```

---

### Task 12: `Hatchery.Internal.Vfork`

**Files:**
- Create: `hatchery/src/Hatchery/Internal/Vfork.hs`

**Step 1: Write Vfork.hs**

Haskell wrapper around `spawn_fork_server` from `vfork_helper.c`. Uses FFI `ccall` to invoke it, passing the embedded ELF bytes and config.

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Internal/Vfork.hs
git commit -m "feat: Haskell FFI wrapper for vfork+execveat"
```

---

### Task 13: `Hatchery.Internal.Protocol`

**Files:**
- Create: `hatchery/src/Hatchery/Internal/Protocol.hs`

**Step 1: Write Protocol.hs**

Serialize/deserialize `Command` and `Response` types matching `protocol.h` wire format. Use `Data.ByteString` and manual binary packing (no cereal/binary dependency needed for fixed-size structs).

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Internal/Protocol.hs
git commit -m "feat: command/response protocol serialization"
```

---

### Task 14: `Hatchery.Config`

**Files:**
- Create: `hatchery/src/Hatchery/Config.hs`

**Step 1: Write Config.hs**

```haskell
module Hatchery.Config
  ( HatcheryConfig(..)
  , defaultConfig
  , InjectionCapability(..)
  , InjectionMethod(..)
  ) where

data InjectionCapability
  = ProcessVmWritevOnly
  | SharedMemfdOnly
  | BothMethods
  deriving (Show, Eq)

data InjectionMethod
  = UseProcessVmWritev
  | UseSharedMemfd
  deriving (Show, Eq)

data HatcheryConfig = HatcheryConfig
  { poolSize            :: Int
  , codeRegionSize      :: Word
  , ringBufSize         :: Word
  , injectionCapability :: InjectionCapability
  , dispatchTimeout     :: Maybe Double  -- seconds
  }

defaultConfig :: HatcheryConfig
defaultConfig = HatcheryConfig
  { poolSize            = 4
  , codeRegionSize      = 4 * 1024 * 1024  -- 4MB
  , ringBufSize         = 1024 * 1024       -- 1MB
  , injectionCapability = BothMethods
  , dispatchTimeout     = Nothing
  }
```

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Config.hs
git commit -m "feat: HatcheryConfig with InjectionCapability"
```

---

### Task 15: `Hatchery.Core`

**Files:**
- Create: `hatchery/src/Hatchery/Core.hs`

**Step 1: Write Core.hs**

`withHatchery` function:
- Check bound thread (`rtsSupportsBoundThreads`, `isCurrentThreadBound`)
- Call `spawnForkServer` from `Hatchery.Internal.Vfork`
- Return `Hatchery` handle (holds socketpair fd, config, worker state MVar)
- Cleanup: send CMD_SHUTDOWN, close fds, wait for fork server to exit

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Core.hs
git commit -m "feat: withHatchery lifecycle management"
```

---

### Task 16: `Hatchery.Dispatch`

**Files:**
- Create: `hatchery/src/Hatchery/Dispatch.hs`

**Step 1: Write Dispatch.hs**

`dispatch` function:
- Takes `Hatchery`, `InjectionMethod`, `ByteString` (code bytes)
- Validates injection method against pool's `InjectionCapability`
- Sends `CmdDispatch` over socketpair
- Waits for `RspWorkerDone` or `RspWorkerCrashed`
- Returns `DispatchResult`

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery/Dispatch.hs
git commit -m "feat: dispatch with dual injection method support"
```

---

### Task 17: `Hatchery` re-export module

**Files:**
- Modify: `hatchery/src/Hatchery.hs`

**Step 1: Write re-export module**

```haskell
module Hatchery
  ( -- * Core
    Hatchery
  , withHatchery
  , HatcheryConfig(..)
  , defaultConfig
  , InjectionCapability(..)
  , InjectionMethod(..)
    -- * Dispatch
  , dispatch
  , DispatchResult(..)
  ) where

import Hatchery.Config
import Hatchery.Core
import Hatchery.Dispatch
```

**Step 2: Verify full library compiles**

Run: `nix develop -c bash -c 'make -C hatchery/cbits && cabal build hatchery'`
Expected: clean compile.

**Step 3: Commit**

```bash
git add hatchery/src/Hatchery.hs
git commit -m "feat: Hatchery re-export module"
```

---

### Task 18: Test payload — `return42.S`

**Files:**
- Create: `hatchery/test-payloads/return42.S`
- Create: `hatchery/test-payloads/Makefile`

**Step 1: Write test payload**

```asm
; return42.S — minimal test: return 42 via ring buffer
; Called as: int (*code)(struct ring_buffer *ring)
; ring pointer is in rdi
BITS 64
    mov dword [rdi + RESULT_OFFSET], 0    ; result_offset = 0
    mov dword [rdi + RESULT_SIZE], 4      ; result_size = 4
    mov dword [rdi + DATA_OFFSET], 42     ; data[0..3] = 42
    mov eax, 0                            ; exit_code = 0
    ret
```

(Offsets will be computed from `ring_buffer.h` struct layout.)

**Step 2: Assemble**

Run: `nix develop -c nasm -f bin -o hatchery/test-payloads/return42.bin hatchery/test-payloads/return42.S`

**Step 3: Commit**

```bash
git add hatchery/test-payloads/
git commit -m "test: return42 assembly payload"
```

---

### Task 19: Integration test — dispatch return42

**Files:**
- Create: `hatchery/test/Main.hs`
- Modify: `hatchery/hatchery.cabal` (add test-suite)

**Step 1: Write test**

```haskell
module Main where

import Hatchery
import qualified Data.ByteString as BS

main :: IO ()
main = do
  payload <- BS.readFile "test-payloads/return42.bin"
  withHatchery defaultConfig $ \h -> do
    result <- dispatch h UseProcessVmWritev payload
    case result of
      Completed bs -> do
        putStrLn $ "Got result: " ++ show bs
        -- expect 4 bytes encoding 42
      Crashed sig -> error $ "Worker crashed with signal " ++ show sig
      TimedOut -> error "Timed out"

    -- Test memfd injection too
    result2 <- dispatch h UseSharedMemfd payload
    case result2 of
      Completed bs -> putStrLn $ "Memfd result: " ++ show bs
      _ -> error "Memfd dispatch failed"

  putStrLn "All tests passed"
```

**Step 2: Add test-suite to cabal file**

**Step 3: Run test**

Run: `nix develop -c bash -c 'make -C hatchery/cbits && cabal test hatchery'`
Expected: "All tests passed"

**Step 4: Commit**

```bash
git add hatchery/test/ hatchery/hatchery.cabal
git commit -m "test: integration test dispatching return42 via both injection methods"
```

---

### Task 20: `trustless-ffi` scaffolding

**Files:**
- Modify: `cabal.project` (add `trustless-ffi/` and `hatchery-llvm/`)
- Create: `trustless-ffi/trustless-ffi.cabal`
- Create: `trustless-ffi/src/TrustlessFFI.hs`
- Create: `hatchery-llvm/hatchery-llvm.cabal`
- Create: `hatchery-llvm/src/Hatchery/LLVM.hs` (stub)

**Step 1: Create all three packages' scaffolding**

`trustless-ffi` depends on `hatchery` + `hatchery-llvm`.
`hatchery-llvm` depends on `hatchery` + `llvm-tf`.

**Step 2: Verify cabal resolves all packages**

Run: `nix develop -c cabal build all --dry-run`

**Step 3: Commit**

```bash
git add cabal.project trustless-ffi/ hatchery-llvm/
git commit -m "feat: trustless-ffi and hatchery-llvm package scaffolding"
```

---

### Task 21: `hatchery-llvm` — LLVM IR to machine code

**Files:**
- Create: `hatchery-llvm/src/Hatchery/LLVM.hs`

**Step 1: Write LLVM bridge**

Uses `llvm-tf` to:
- Build LLVM module from user-provided IR construction
- Run LLVM optimization passes
- Compile to machine code bytes (`ByteString`)
- Manage LLVM context lifecycle

Key function:
```haskell
compileToMachineCode :: LLVM.Module -> IO ByteString
```

**Step 2: Verify compiles**

**Step 3: Commit**

```bash
git add hatchery-llvm/src/
git commit -m "feat(hatchery-llvm): LLVM IR to machine code compilation"
```

---

### Task 22: `trustless-ffi` — User-facing API with JIT

**Files:**
- Create: `trustless-ffi/src/TrustlessFFI.hs`
- Create: `trustless-ffi/src/TrustlessFFI/Marshal.hs`

**Step 1: Write TrustlessFFI.hs**

```haskell
module TrustlessFFI
  ( FFI, withFFI, FFIConfig(..), defaultFFIConfig
  , call, callAsync, CallResult(..)
  , callLLVM  -- JIT path via hatchery-llvm
  ) where
```

Wraps `Hatchery` with simpler config, provides `call` (raw machine code) and `callLLVM` (LLVM IR → compile → dispatch).

**Step 2: Write Marshal.hs**

Helpers for marshalling arguments/results through the ring buffer data region.

**Step 3: Verify compiles**

Run: `nix develop -c cabal build all`

**Step 4: Commit**

```bash
git add trustless-ffi/src/
git commit -m "feat(trustless-ffi): user-facing API with JIT support"
```

---

### Task 23: Dev journal init

**Files:**
- Create: `artifacts/devlog.md`

**Step 1: Initialize devlog**

```markdown
# Hatchery Dev Journal

## 2026-03-15 — Project initialized

- Design approved: dual injection (process_vm_writev + shared memfd), per-dispatch selection, pool-level capability config
- Package structure: hatchery (core) → hatchery-llvm (bridge) → trustless-ffi (user API)
- LLVM codegen via llvm-tf 16.0
- Nix flake with musl-gcc, GHC, LLVM 16, cabal
```

**Step 2: Commit**

```bash
git add artifacts/
git commit -m "docs: initialize dev journal"
```
