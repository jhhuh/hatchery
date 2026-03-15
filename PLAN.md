# `hatchery` + `trustless-ffi`

## Package Structure

```
hatchery                        Process sandbox toolkit for Haskell
  └── trustless-ffi             Fault-isolated foreign function calls
                                (thin ergonomic layer over hatchery)
```

## Overview

**`hatchery`** is a Linux process sandbox toolkit. It manages a supervised pool of pre-spawned worker processes with microsecond dispatch latency. Workers are fully address-space-isolated, seccomp-filtered, and contained in a PID namespace. The fork server, process pool, memfd code injection, and futex-based wakeup are the core primitives — all exposed for direct use.

**`trustless-ffi`** wraps `hatchery` in an FFI-shaped API. Foreign code runs in a sandbox with the ergonomics of a normal FFI call and the guarantee that crashes, hangs, and wild writes cannot propagate to the host. Most users only see this package.

## Architecture

```
GHC Process (Haskell)
  │
  │ socketpair (Unix domain, SCM_RIGHTS for fd passing)
  │ pipe (parent-liveness detection)
  │
  └─► Fork Server (PID 1 in CLONE_NEWPID namespace)
        │   created via: vfork + execveat(memfd)
        │   static-PIE ELF, no interpreter, embedded in Haskell binary
        │   single-threaded, supervises pool via waitpid + epoll
        │
        ├─► Worker 0  (pre-spawned, suspended on futex)
        ├─► Worker 1
        ├─► Worker 2
        └─► ...
            Each worker:
              - own address space (fault isolated)
              - PROT_READ|PROT_WRITE|PROT_EXEC code region
              - MAP_SHARED ring buffer (memfd)
              - seccomp filter restricting syscalls
              - PR_SET_DUMPABLE=0
              - PDEATHSIG=SIGKILL (safe: fork server is single-threaded)
```

## Lifecycle Guarantees

1. **Haskell dies → fork server dies**: pipe trick (fd is process-scoped, immune to thread identity issues). PDEATHSIG as belt-and-suspenders (safe because `withForkServer` enforces bound-thread call site, and the vfork happens from a known OS thread).
2. **Fork server dies → all workers die**: PID namespace invariant. Fork server is PID 1; kernel kills all namespace members when PID 1 exits.
3. **Worker crashes → detected and respawned**: fork server monitors via `waitpid` in its epoll loop, spawns replacement.

## Components

### 1. `hatchery` — Haskell Library (`hatchery/src/`)

#### `Hatchery` (public API — re-exports)

```haskell
module Hatchery
  ( -- * Core
    Hatchery
  , withHatchery
  , HatcheryConfig(..)
  , defaultConfig
    -- * Dispatch
  , dispatch
  , dispatchAsync
  , DispatchResult(..)
    -- * Pool management
  , poolStatus
  , PoolInfo(..)
  ) where
```

#### `Hatchery.Config` (public API)

```haskell
module Hatchery.Config
  ( HatcheryConfig(..)
  , defaultConfig
  , SeccompProfile(..)
  , defaultSeccomp
  ) where

data HatcheryConfig = HatcheryConfig
  { poolSize       :: Int            -- ^ Number of pre-spawned workers (default: 4)
  , codeRegionSize :: Word64         -- ^ Executable region per worker (default: 4MB)
  , ringBufSize    :: Word64         -- ^ Shared ring buffer per worker (default: 1MB)
  , seccompProfile :: SeccompProfile -- ^ Syscall whitelist (default: minimal)
  , maxDispatches  :: Maybe Int      -- ^ Recycle worker after N dispatches (default: Nothing)
  , dispatchTimeout :: Maybe NominalDiffTime -- ^ Per-dispatch timeout (default: Nothing)
  }
```

#### `Hatchery.Core` (public API)

```haskell
module Hatchery.Core
  ( Hatchery
  , withHatchery
  ) where

-- | Must be called from a bound thread (enforced at runtime).
-- Embeds the fork server ELF, writes to memfd, vfork+execveat.
-- Fork server spawns worker pool in a PID namespace.
withHatchery :: HatcheryConfig -> (Hatchery -> IO a) -> IO a
```

#### `Hatchery.Dispatch` (public API)

```haskell
module Hatchery.Dispatch
  ( dispatch
  , dispatchAsync
  , DispatchResult(..)
  , DispatchError(..)
  ) where

-- | Write native code into a free worker's code region,
-- wake it via futex, wait for result on ring buffer.
dispatch :: Hatchery -> ByteString -> IO DispatchResult

-- | Async variant, returns immediately with a future.
dispatchAsync :: Hatchery -> ByteString -> IO (Async DispatchResult)

data DispatchResult
  = Completed ByteString        -- ^ Result bytes from ring buffer
  | Crashed Signal              -- ^ Worker died (already respawned)
  | TimedOut                    -- ^ Deadline exceeded

data DispatchError
  = NoAvailableWorker
  | HatcheryDead
```

#### `Hatchery.Internal.Memfd` (internal)

```haskell
module Hatchery.Internal.Memfd where

foreign import ccall "memfd_create" c_memfd_create :: CString -> CUInt -> IO CInt
foreign import ccall "fcntl"        c_fcntl_seal   :: CInt -> CInt -> CInt -> IO CInt

memfdCreate :: String -> [MemfdFlag] -> IO Fd
memfdSeal   :: Fd -> [SealFlag] -> IO ()
```

#### `Hatchery.Internal.Vfork` (internal)

```haskell
module Hatchery.Internal.Vfork where

-- vfork + execveat, implemented as a small C helper
foreign import ccall "vfork_execveat"
  c_vfork_execveat :: CInt -> CInt -> CInt -> CInt -> IO CPid
```

#### `Hatchery.Internal.Protocol` (internal)

```haskell
module Hatchery.Internal.Protocol where

-- Messages over socketpair: Haskell → fork server
data Command
  = CmdDispatch WorkerId ByteString
  | CmdStatus
  | CmdShutdown

-- Messages over socketpair: fork server → Haskell
data Response
  = RspWorkerReady WorkerId
  | RspWorkerDone WorkerId ByteString
  | RspWorkerCrashed WorkerId Signal
  | RspPoolStatus PoolInfo
```

### 2. `trustless-ffi` — User-Facing Package (`trustless-ffi/src/`)

```haskell
module TrustlessFFI
  ( -- * Setup
    FFI
  , withFFI
  , FFIConfig(..)
  , defaultFFIConfig
    -- * Calling foreign code
  , call
  , callAsync
  , CallResult(..)
    -- * Marshalling helpers
  , withArg
  , peekResult
  ) where

import qualified Hatchery

-- | Simplified config hiding pool/sandbox details
data FFIConfig = FFIConfig
  { maxConcurrent :: Int                   -- ^ default: 4
  , timeout        :: Maybe NominalDiffTime -- ^ default: 30s
  }

newtype FFI = FFI Hatchery.Hatchery

withFFI :: FFIConfig -> (FFI -> IO a) -> IO a
withFFI cfg action = Hatchery.withHatchery (toHatcheryConfig cfg) $ \h ->
    action (FFI h)

-- | Call native code. The ByteString is raw machine code.
-- Arguments and results are passed through a shared buffer.
call :: FFI -> ByteString -> ByteString -> IO CallResult

data CallResult
  = Success ByteString
  | ForeignCrash String    -- ^ Human-readable crash description
  | Timeout
```

### 3. Fork Server Binary (`hatchery/cbits/fork_server.c`)

Compiled as a static-PIE ELF with no libc dependency (or musl-static for convenience). Embedded into the Haskell binary via Template Haskell / `file-embed`.

```
hatchery/cbits/
  fork_server.c       -- main event loop (epoll on: socketpair, pipe, pidfd per worker)
  worker_template.c   -- worker _start: mmap code region, mmap ring buffer, futex_wait
  protocol.h          -- shared command/response wire format
  ring_buffer.h       -- lock-free ring buffer protocol (atomics in shared memory)
  seccomp_filter.c    -- BPF seccomp filter generation
  syscall.h           -- raw syscall wrappers (no libc)
```

#### Fork Server Main Loop (`fork_server.c`)

```c
void _start(void) {
    int sock_fd = atoi(argv[1]);    // socketpair to Haskell
    int pipe_fd = atoi(argv[2]);    // parent liveness pipe

    // Enter PID namespace already set up by clone flags
    // We are PID 1 here

    // Pre-spawn worker pool
    for (int i = 0; i < pool_size; i++)
        spawn_worker(i);

    // epoll loop
    int epfd = epoll_create1(0);
    epoll_add(epfd, sock_fd);       // commands from Haskell
    epoll_add(epfd, pipe_fd);       // parent liveness (POLLHUP = parent died)
    for (int i = 0; i < pool_size; i++)
        epoll_add(epfd, worker_pidfd[i]);  // worker death notifications

    for (;;) {
        int n = epoll_wait(epfd, events, MAX_EVENTS, -1);
        for (int i = 0; i < n; i++) {
            if (events[i].data.fd == pipe_fd)
                _exit(0);  // parent died, namespace cleanup is automatic
            else if (events[i].data.fd == sock_fd)
                handle_command(sock_fd);
            else
                handle_worker_death(events[i].data.fd);
        }
    }
}
```

#### Worker Template (`worker_template.c`)

```c
// Compiled as separate static-PIE ELF, also embedded in Haskell binary.
// Fork server writes this to a memfd and forks+execveats it.
// Or: fork server forks itself and the child mmaps/jumps.
// Simpler: fork server just forks (it's small), child sets up and waits.

void _start(void) {
    int ring_fd = KNOWN_RING_FD;   // inherited fd, known by convention

    // mmap executable code region
    void *code = mmap(NULL, CODE_SIZE,
                      PROT_READ | PROT_WRITE | PROT_EXEC,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

    // mmap shared ring buffer
    struct ring_buffer *ring = mmap(NULL, RING_SIZE,
                                    PROT_READ | PROT_WRITE,
                                    MAP_SHARED, ring_fd, 0);

    // install seccomp filter BEFORE accepting any code
    install_seccomp();

    // set non-dumpable
    prctl(PR_SET_DUMPABLE, 0);

    // signal readiness: write code region address to ring
    ring->code_base = (uint64_t)code;
    ring->status = WORKER_READY;

    // wait for dispatch
    while (1) {
        futex_wait(&ring->control, WORKER_IDLE);

        // Parent wrote code into `code` region and set control = WORKER_RUN
        // Execute it
        int result = ((int (*)(struct ring_buffer *))code)(ring);

        // Write result
        ring->exit_code = result;
        ring->status = WORKER_DONE;
        futex_wake(&ring->notify, 1);

        // Reset for next dispatch
        ring->control = WORKER_IDLE;
    }
}
```

### 4. Shared Data Structures

#### Ring Buffer Layout (`ring_buffer.h`)

```c
struct ring_buffer {
    // Control (cache-line aligned)
    _Alignas(64) _Atomic uint32_t control;   // futex word: IDLE/RUN/STOP
    _Alignas(64) _Atomic uint32_t notify;    // futex word: worker -> parent
    _Alignas(64) _Atomic uint32_t status;    // READY/BUSY/DONE/CRASHED

    // Worker info (written once at init)
    uint64_t code_base;          // address of executable region in worker
    uint64_t code_size;          // size of code region

    // Result (written by worker)
    int32_t  exit_code;
    uint32_t result_offset;      // offset into data[] for result
    uint32_t result_size;

    // Data region (bulk transfer)
    _Alignas(64) uint8_t data[];
};

enum worker_state {
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
```

### 5. Dispatch Sequence (Hot Path)

From Haskell, dispatching code to a worker:

```
Haskell                          Fork Server                     Worker N
  │                                  │                               │
  │ CmdDispatch(N, code_bytes)       │                               │
  │ ────────────────────────────►    │                               │
  │    (over socketpair)             │                               │
  │                                  │ process_vm_writev(            │
  │                                  │   worker_pid,                 │
  │                                  │   code_bytes,                 │
  │                                  │   worker_code_base)           │
  │                                  │ ─────────────────────────►    │
  │                                  │   (~1-2μs, memcpy across      │
  │                                  │    address spaces)            │
  │                                  │                               │
  │                                  │ ring->control = WORKER_RUN    │
  │                                  │ futex_wake(&ring->control, 1) │
  │                                  │ ─────────────────────────►    │
  │                                  │   (~1-3μs)                    │ futex returns
  │                                  │                               │ jump to code_base
  │                                  │                               │ ... executes ...
  │                                  │                               │ ring->status = DONE
  │                                  │                               │ futex_wake(notify)
  │                                  │     ◄─────────────────────────│
  │                                  │                               │
  │    RspWorkerDone(N, result)      │                               │
  │    ◄─────────────────────────    │                               │
  │                                  │                               │

Dispatch latency: ~3-5μs (excluding code execution time)
```

## Build System

### Repository Layout

```
hatchery/
  hatchery.cabal
  src/
    Hatchery.hs
    Hatchery/
      Config.hs
      Core.hs
      Dispatch.hs
      Internal/
        Memfd.hs
        Vfork.hs
        Protocol.hs
        Embedded.hs
  cbits/
    fork_server.c
    worker_template.c
    protocol.h
    ring_buffer.h
    seccomp_filter.c
    syscall.h
    vfork_helper.c
    Makefile

trustless-ffi/
  trustless-ffi.cabal
  src/
    TrustlessFFI.hs
    TrustlessFFI/
      Marshal.hs
```

### Cabal Files

```cabal
-- hatchery/hatchery.cabal
cabal-version: 3.0
name:          hatchery
version:       0.1.0.0
synopsis:      Process sandbox toolkit with pre-spawned worker pools
license:       BSD-3-Clause

library
  exposed-modules:
    Hatchery
    Hatchery.Config
    Hatchery.Core
    Hatchery.Dispatch
  other-modules:
    Hatchery.Internal.Memfd
    Hatchery.Internal.Vfork
    Hatchery.Internal.Protocol
    Hatchery.Internal.Embedded
  build-depends:
    base >= 4.16 && < 5,
    bytestring,
    async,
    unix,
    file-embed
  hs-source-dirs: src
  c-sources:
    cbits/vfork_helper.c
  default-language: Haskell2010
```

```cabal
-- trustless-ffi/trustless-ffi.cabal
cabal-version: 3.0
name:          trustless-ffi
version:       0.1.0.0
synopsis:      Foreign function calls that can't crash your program
license:       BSD-3-Clause

library
  exposed-modules:
    TrustlessFFI
    TrustlessFFI.Marshal
  build-depends:
    base >= 4.16 && < 5,
    bytestring,
    async,
    hatchery
  hs-source-dirs: src
  default-language: Haskell2010
```

### Build Steps

```makefile
# hatchery/cbits/Makefile

CC = musl-gcc
CFLAGS = -static-pie -nostartfiles -fPIE -Os -Wall

fork_server: fork_server.c protocol.h ring_buffer.h seccomp_filter.c syscall.h
	$(CC) $(CFLAGS) -o $@ fork_server.c seccomp_filter.c

worker_template: worker_template.c ring_buffer.h seccomp_filter.c syscall.h
	$(CC) $(CFLAGS) -o $@ worker_template.c seccomp_filter.c

# Alternatively: single fork_server binary that fork()s workers directly
# (workers don't need a separate ELF since fork server is small)

.PHONY: clean
clean:
	rm -f fork_server worker_template
```

### Embedding

```haskell
-- hatchery/src/Hatchery/Internal/Embedded.hs
module Hatchery.Internal.Embedded where

import Data.FileEmbed (embedFile)
import Data.ByteString (ByteString)

forkServerELF :: ByteString
forkServerELF = $(embedFile "cbits/fork_server")

-- Worker template only needed if workers are separate ELFs.
-- If fork server just fork()s itself for workers, this is unnecessary.
```

## Implementation Order

### Phase 1: Minimal Viable Path

Goal: Haskell spawns a fork server, fork server spawns one worker, Haskell dispatches code, gets result.

1. **`hatchery/cbits/syscall.h`** — raw syscall wrappers: `sys_write`, `sys_read`, `sys_mmap`, `sys_exit_group`, `sys_clone`, `sys_execveat`, `sys_memfd_create`, `sys_futex`, `sys_epoll_*`, `sys_prctl`, `sys_process_vm_writev`, `sys_pidfd_open`
2. **`hatchery/cbits/ring_buffer.h`** — shared struct definition, futex helpers
3. **`hatchery/cbits/protocol.h`** — command/response wire format (keep it trivial: fixed-size structs)
4. **`hatchery/cbits/worker_template.c`** — `_start` that mmaps, installs seccomp, waits on futex, executes, reports
5. **`hatchery/cbits/fork_server.c`** — `_start` that forks one worker, enters epoll loop, handles one command type (dispatch)
6. **`hatchery/cbits/vfork_helper.c`** — C helper callable from Haskell: creates memfds, vfork, execveat
7. **`hatchery/src/Hatchery/Internal/Memfd.hs`** — Haskell FFI bindings for memfd_create, sealing
8. **`hatchery/src/Hatchery/Internal/Vfork.hs`** — Haskell wrapper around vfork_helper
9. **`hatchery/src/Hatchery/Internal/Protocol.hs`** — serialize/deserialize commands over socketpair
10. **`hatchery/src/Hatchery/Core.hs`** — `withHatchery`, bound thread check, setup, teardown
11. **`hatchery/src/Hatchery/Dispatch.hs`** — `dispatch` (synchronous, single worker)

### Phase 2: Pool and Supervision

12. Fork server spawns N workers, tracks them by index
13. `pidfd_open` per worker, add to epoll
14. `waitpid` handler: detect crash, update pool state, respawn
15. Worker selection: round-robin or first-idle
16. `dispatchAsync` in Haskell
17. Timeout support: `timer_create` or timerfd per dispatch

### Phase 3: Namespace and Hardening

18. `CLONE_NEWPID` on fork server creation (may need `CLONE_NEWUSER` if unprivileged)
19. Seccomp BPF filter on workers
20. `PR_SET_DUMPABLE=0` on fork server and workers
21. Resource limits: cgroup memory limit per worker (optional)
22. `CLONE_NEWNET` on workers to block network access (optional)

### Phase 4: trustless-ffi

23. **`trustless-ffi/src/TrustlessFFI.hs`** — `withFFI`, `call`, `callAsync`
24. **`trustless-ffi/src/TrustlessFFI/Marshal.hs`** — argument/result marshalling helpers
25. Documentation, examples, README

### Phase 5: Polish

26. Graceful shutdown protocol
27. Worker recycling (kill after N dispatches to prevent memory leaks in foreign code)
28. Monitoring / statistics (dispatch count, crash count, latency)
29. Test suite: crash recovery, timeout, concurrent dispatch, stress test

## Key Design Decisions

### Fork server spawns workers via fork(), not vfork+execveat

The fork server is small (minimal static binary), so fork() page table cost is negligible. Workers inherit the fork server's state (already-opened ring buffer fds, etc.) without needing argument passing. This avoids needing a separate worker ELF — fork server forks itself, child diverges into worker_main().

### Workers are recycled, not persistent

After each dispatch, the worker resets and waits again. But after N dispatches (configurable), the fork server kills and respawns it to prevent accumulated memory leaks from foreign code.

### No Haskell in the fork server or workers

The fork server and workers are pure C. No GHC RTS, no Haskell heap, no garbage collector. This keeps the address space minimal and avoids any interaction between foreign code and GHC internals.

### Communication: socketpair for control, ring buffer for data

Control messages (dispatch, status, shutdown) go over the Unix socketpair — reliable, ordered, supports fd passing. Bulk data (code bytes, results) goes through the shared ring buffer — zero-copy, minimal latency.

## Testing Strategy

```
hatchery/test/
  Test/Hatchery/Basic.hs        -- spawn, dispatch trivial code, get result
  Test/Hatchery/Crash.hs         -- dispatch code that segfaults, verify recovery
  Test/Hatchery/Timeout.hs       -- dispatch infinite loop, verify timeout
  Test/Hatchery/Concurrent.hs    -- dispatch to multiple workers simultaneously
  Test/Hatchery/Lifecycle.hs     -- verify cleanup on Haskell exit, fork server death
  Test/Hatchery/Seccomp.hs       -- verify blocked syscalls fail gracefully
  test-payloads/
    return42.S                   -- minimal: mov eax, 42; ret
    segfault.S                   -- mov [0], 0
    spin.S                       -- jmp $
    write_result.S               -- write bytes into ring buffer, return

trustless-ffi/test/
  Test/TrustlessFFI/Call.hs      -- call foreign code, get result
  Test/TrustlessFFI/Crash.hs     -- foreign crash → ForeignCrash, not process death
  Test/TrustlessFFI/Timeout.hs   -- timeout → Timeout, not hang
```

## Dependencies

### Build-time
- `musl-gcc` or `gcc` with `-static-pie -nostartfiles` support
- `file-embed` (Haskell, for embedding ELF binaries)

### Runtime
- Linux >= 5.3 (pidfd_open)
- Linux >= 3.17 (memfd_create)
- Linux >= 5.9 (clone3 with CLONE_NEWPID + CLONE_NEWUSER unprivileged)
- x86_64 (initially; the architecture affects seccomp BPF and syscall numbers)

### Haskell (hatchery)
- `base >= 4.16`
- `bytestring`
- `async`
- `unix`
- `file-embed`

### Haskell (trustless-ffi)
- `base >= 4.16`
- `bytestring`
- `async`
- `hatchery`

## Open Questions

1. **Worker code format**: Raw machine code (simplest) vs minimal ELF (relocatable) vs position-independent shellcode? Raw machine code at a known base address is simplest for phase 1.

2. **process_vm_writev vs shared memfd for code injection**: `process_vm_writev` requires no setup in the worker but needs `CAP_SYS_PTRACE` or same-UID. Shared memfd for the code region avoids this — fork server writes code into a memfd that the worker already has mapped as executable. The memfd approach is cleaner.

3. **Single fork server ELF vs separate worker ELF**: If the fork server just forks itself and the child jumps to `worker_main()`, we only need one ELF. If workers need a completely different memory layout, separate ELFs via `vfork+execveat(worker_memfd)` from the fork server. Start with single ELF.

4. **Nix integration**: Build the musl-static C components via a Nix derivation, integrate with the Haskell build via `cabal2nix` or `haskell.nix`. The C build is self-contained and reproducible.

## Future Directions: The Ecosystem

### Package Hierarchy

`hatchery` is the foundation of a broader ecosystem for safe, high-performance Haskell computation:

```
hatchery                    Process sandbox toolkit (this package)
ghc-fastboot                Zero-cost closure graph serialization (exists)
  │
  ├── trustless-ffi         Fault-isolated foreign function calls
  │                         Workers are minimal C stubs
  │                         Dispatch: raw machine code via memfd + futex
  │
  ├── trustless-eval        Sandboxed Haskell thunk evaluation
  │                         Workers are full GHC RTS instances
  │                         Dispatch: freeze closure → thaw in worker → evaluate → freeze result
  │
  └── fastboot-distributed  Closure graph distribution for HPC
                            RDMA / shared-filesystem transport
                            Demand-paged, zero-relocation on same-binary clusters
```

### `trustless-eval` — Sandboxed Haskell Evaluation

The key insight: combine ghc-fastboot's zero-cost closure transport with hatchery's process isolation to evaluate arbitrary Haskell thunks in a sandbox.

**User-facing API:**

```haskell
module TrustlessEval
  ( SafeEval
  , withSafeEval
  , safeEvaluate
  , safeEvaluateNF
  ) where

data EvalFailure
  = EvalCrashed Signal     -- segfault, undefined, error
  | EvalTimedOut           -- infinite loop detected via tick control
  | EvalOutOfMemory        -- cgroup limit hit

-- Evaluate any thunk in a sandbox. If it crashes, loops, or OOMs,
-- you get a Left. The parent is never affected.
safeEvaluate :: SafeEval -> a -> IO (Either EvalFailure a)
```

**Architecture:**

```
Parent (GHC)                         Worker (GHC RTS, same binary)
  │                                      │
  │ freeze(thunk) → snapshot             │
  │ write snapshot to shared memfd       │
  │ futex_wake                           │
  │ ────────────────────────────────►   │
  │                                      │ mremap snapshot → fixed VA
  │                                      │ init bdescrs
  │                                      │ root = thaw(snapshot)
  │                                      │ result = evaluate(root)
  │                                      │ freeze(result) → ring buffer
  │    ◄────────────────────────────     │ futex_wake
  │                                      │
  │ thaw(result) → Haskell value         │
```

Same binary on parent and worker means **zero relocation** — all pointers in the snapshot are already correct. Freeze is a closure graph walk (ghc-fastboot). Thaw is mremap + bdescr init (~microseconds). The entire round trip for dispatching a thunk is dominated by evaluation time, not transport.

**Worker pool via frozen template:**

1. At startup, spawn one worker via `vfork` + `execveat` (same binary, `--worker` flag)
2. Worker initializes GHC RTS, loads base libraries, reaches idle state
3. Fork server `fork()`s this initialized worker to fill the pool — CoW means all workers share the template's physical pages until they diverge
4. Each worker only allocates new pages when it evaluates its dispatched thunk

**RTS scheduler tick control:**

GHC's scheduler yields at tick boundaries (`context_switch` flag). External control of the tick enables:

- **Timeout enforcement**: worker hasn't produced a result after N ticks → kill, respawn. More precise than wall-clock timeout because it measures evaluation work, not I/O wait.
- **Deterministic stepping**: disable RTS timer (`+RTS -V0`), trigger ticks externally via `SIGVTALRM`. The parent becomes the scheduler — single-step evaluation of Haskell thunks in an isolated process.
- **Progress observation**: at each tick boundary the heap is in a consistent state (not mid-GC, not mid-allocation). Worker can report progress to the ring buffer. Parent observes evaluation in real time.
- **Preemptive resource control**: inspect heap size at tick boundaries, kill before OOM rather than after.

**What doesn't exist elsewhere:**

- Cloud Haskell: remote evaluation, but no fault isolation
- Safe Haskell: type-level restrictions, but no process-level sandboxing
- GHC Compact Regions: contiguous closure storage, but no thunks, no functions, no cross-process transport
- `trustless-eval`: actual process-level fault isolation for arbitrary Haskell evaluation, with ghc-fastboot making closure transport essentially free

### `fastboot-distributed` — HPC Closure Distribution

ghc-fastboot's snapshot format is a natural wire format for distributing Haskell data structures across a cluster.

**The cost advantage:**

```
Traditional:  build structure → serialize ($$) → send → deserialize ($$) → use
ghc-fastboot: build structure → freeze (μs)  → send → thaw (μs)         → use
```

For multi-GB data structures — sparse matrices, graph structures, ASTs, lookup tables — serialization cost dominates. ghc-fastboot eliminates it.

**Same-binary, zero-relocation property:**

If all nodes run the same binary, every snapshot pointer is already correct at the target VA. No relocation pass, no symbol resolution. The receiving node just maps the pages and they're live closures.

**Demand paging:**

`MAP_PRIVATE` with CoW means sending a 10GB snapshot to a node that only touches partition 3 results in only partition 3's pages being faulted in. Physical cost is proportional to working set, not data size.

**Transport paths:**

- **RDMA**: freeze on one node, RDMA write pages directly into remote node's pre-registered memory region. Thaw is just bdescr init — the pages are already in place. Zero copy end to end.
- **Shared filesystem** (Lustre/GPFS/BeeGFS): freeze to shared file, all nodes mmap the same file. Kernel page cache provides sharing. Ideal for read-heavy workloads on shared data.
- **Network**: fallback for non-RDMA clusters. Send snapshot bytes over TCP/IB verbs, receiver mmaps into memfd, thaws.

**Coordinator/worker topology:**

```
Coordinator (Haskell)
  │
  │ freeze(large_dataset) → snapshot
  │
  ├─► Node 0: thaw, evaluate partition 0, freeze(result)
  ├─► Node 1: thaw, evaluate partition 1, freeze(result)
  ├─► Node 2: thaw, evaluate partition 2, freeze(result)
  └─► ...
      │
      └─► Coordinator: thaw all results, combine
```

Each node runs hatchery for local process management (supervision, crash recovery). The distributed layer handles snapshot transport and partition assignment.

### Collaborative Evaluation (Speculative)

Multiple worker processes share a frozen image (`MAP_PRIVATE`, CoW). Each evaluates different thunks within the same closure graph. Results are communicated via `IND` (indirection) closures pointing into shared regions. The fixed VA property means cross-process pointers work without coordination.

This enables speculative parallel evaluation: dispatch the same thunk to multiple workers with different evaluation strategies, take the first result, kill the rest. Or partition a large lazy structure across workers, each forcing a different region.

### Relationship Between Packages

```
                    ┌──────────────┐
                    │  ghc-fastboot │  closure freeze/thaw
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │   hatchery   │  process sandbox + pool
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
     ┌────────┴───┐ ┌─────┴──────┐ ┌───┴──────────────┐
     │trustless-ffi│ │trustless-eval│ │fastboot-distributed│
     │ C code only │ │ Haskell eval │ │ HPC clusters       │
     └─────────────┘ └─────────────┘ └────────────────────┘
```

`hatchery` provides the process lifecycle, isolation, and dispatch primitives. `ghc-fastboot` provides the data transport. The three leaf packages compose them for different use cases, sharing the same foundation.
