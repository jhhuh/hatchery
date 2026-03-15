# `hatchery` + `trustless-ffi`

## Package Structure

```
hatchery                        Process sandbox toolkit for Haskell
  └── trustless-ffi             Fault-isolated foreign function calls
                                (thin ergonomic layer over hatchery)
hatchery-llvm                   LLVM IR → machine code bridge (stub)
```

## Overview

**`hatchery`** is a Linux process sandbox toolkit. It manages a supervised pool of pre-spawned worker processes with microsecond dispatch latency. Workers are fully address-space-isolated and seccomp-filtered. The fork server, process pool, dual code injection, and futex-based wakeup are the core primitives — all exposed for direct use.

**`trustless-ffi`** wraps `hatchery` in an FFI-shaped API. Foreign code runs in a sandbox with the ergonomics of a normal FFI call and the guarantee that crashes, hangs, and wild writes cannot propagate to the host. If foreign code segfaults, you get a `ForeignCrash` result, not a dead process.

**`hatchery-llvm`** bridges hatchery with `llvm-tf` for LLVM IR → machine code compilation. Currently a stub.

## Architecture

```
GHC Process (Haskell)
  │
  │ socketpair (SOCK_SEQPACKET, control messages)
  │ pipe (parent-liveness detection)
  │
  └─► Fork Server
        │   created via: vfork + execveat(memfd)
        │   static-PIE ELF, musl, no libc, raw syscalls
        │   compiled at TH time via $HATCHERY_CC, embedded in Haskell binary
        │   single-threaded, supervises pool via wait4 + epoll
        │
        ├─► Worker 0  (pre-spawned, suspended on futex)
        ├─► Worker 1
        └─► ...
            Each worker:
              - own address space (fault isolated)
              - PROT_READ|PROT_WRITE|PROT_EXEC code region
              - MAP_SHARED ring buffer (memfd)
              - seccomp filter restricting syscalls
              - stays dumpable (required for process_vm_writev)
              - PDEATHSIG=SIGKILL
```

## Lifecycle Guarantees

1. **Haskell dies → fork server dies**: pipe trick (fd is process-scoped, immune to thread identity issues). Fork server monitors pipe via epoll; POLLHUP = parent died → exit.
2. **Fork server dies → all workers die**: Workers have `PDEATHSIG=SIGKILL`. (PID namespace planned for Phase 3 as belt-and-suspenders.)
3. **Worker crashes → detected**: Fork server detects via `wait4(WNOHANG)` in dispatch loop and pidfd in epoll loop. Reports `Crashed` to Haskell. (Respawn not yet implemented.)

## Current Implementation

### `hatchery` — Haskell Library (`hatchery/src/`)

#### `Hatchery` (public API — re-exports)

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
  , DispatchError(..)
  ) where
```

#### `Hatchery.Config` (public API)

```haskell
data InjectionCapability
  = ProcessVmWritevOnly  -- MAP_PRIVATE|MAP_ANONYMOUS code region
  | SharedMemfdOnly      -- MAP_SHARED from memfd
  | BothMethods          -- MAP_SHARED from memfd, either method per-dispatch

data InjectionMethod
  = UseProcessVmWritev
  | UseSharedMemfd

data HatcheryConfig = HatcheryConfig
  { poolSize            :: !Int
  , codeRegionSize      :: !Word    -- default: 4MB
  , ringBufSize         :: !Word    -- default: 1MB
  , injectionCapability :: !InjectionCapability  -- default: BothMethods
  , dispatchTimeout     :: !(Maybe Double)       -- default: Nothing (not enforced yet)
  }
```

#### `Hatchery.Dispatch` (public API)

```haskell
dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult

data DispatchResult
  = Completed !Int32 !(Maybe ByteString)  -- exit code + optional result bytes
  | Crashed !Int32                         -- signal number

data DispatchError
  = NoAvailableWorker
  | HatcheryDead
  | IncompatibleInjectionMethod
```

#### Internal modules

- `Hatchery.Internal.Compile` — TH splice: shells out to `$HATCHERY_CC` at compile time, `addDependentFile` for recompilation tracking
- `Hatchery.Internal.Embedded` — `forkServerELF :: ByteString` (TH-compiled and embedded)
- `Hatchery.Internal.Vfork` — FFI to `vfork_helper.c`: creates memfd, socketpair, pipe, vfork+execveat
- `Hatchery.Internal.Protocol` — manual Ptr-based serialization matching `protocol.h` struct layouts
- `Hatchery.Internal.Memfd` — memfd_create FFI bindings

### `trustless-ffi` — User-Facing Package

```haskell
-- Implemented
withFFI :: FFIConfig -> (FFI -> IO a) -> IO a
call :: FFI -> ByteString -> IO CallResult
callAsync :: FFI -> ByteString -> IO (Async CallResult)

data CallResult
  = Success !Int32 !(Maybe ByteString)
  | ForeignCrash !String
  | Timeout  -- listed but not enforced yet
```

`TrustlessFFI.Marshal` provides basic LE encode/decode for Int32, Int64, ByteString.

### Fork Server Binary (`hatchery/cbits/`)

Single C file (`fork_server.c`) containing both fork server and worker logic. Workers are created via `fork()` — child diverges into `worker_main()`. No separate worker binary.

```
fork_server.c       -- _start (naked) → real_start → fork_server_main (epoll loop)
                       worker_main (fork'd child: mmap, seccomp, futex loop)
                       handle_dispatch, handle_status, handle_worker_death
seccomp_filter.c    -- BPF seccomp filter: allows read/write/mmap/munmap/rt_sigreturn/futex/clock_gettime/exit_group
protocol.h          -- command/response wire format (16-byte command, 20-byte response)
ring_buffer.h       -- shared struct with cache-line-aligned atomics, futex helpers
syscall.h           -- raw x86_64 syscall wrappers
vfork_helper.c      -- C helper for Haskell FFI: memfd_create, socketpair, pipe, vfork+execveat
Makefile            -- standalone build (alternative to TH path, useful for debugging)
```

### Dispatch Sequence (Hot Path)

```
Haskell                          Fork Server                     Worker N
  │                                  │                               │
  │ CmdDispatch(N, code_bytes)       │                               │
  │ ────────────────────────────►    │                               │
  │    (over socketpair)             │                               │
  │                                  │ pwrite(code_fd) or            │
  │                                  │ process_vm_writev(worker_pid) │
  │                                  │ ─────────────────────────►    │
  │                                  │                               │
  │                                  │ ring->control = WORKER_RUN    │
  │                                  │ futex_wake(&ring->control, 1) │
  │                                  │ ─────────────────────────►    │
  │                                  │                               │ futex returns
  │                                  │                               │ jump to code_base
  │                                  │                               │ ... executes ...
  │                                  │                               │ ring->status = DONE
  │                                  │                               │ futex_wake(notify)
  │                                  │     ◄─────────────────────────│
  │                                  │                               │
  │    RspWorkerDone(N, result)      │                               │
  │    ◄─────────────────────────    │                               │
  │                                  │                               │

Measured dispatch latency: ~5-6μs (excluding code execution time)
```

### Latency Reference (measured, same `return 42` workload)

```
unsafe ccall:              <0.01 us/call
safe ccall:                ~0.08 us/call
hatchery (pre-loaded):     ~3.08 us/call  (direct futex, no fork server relay)
hatchery (vm_writev):      ~5.23 us/call  (code injection every dispatch)
hatchery (memfd):          ~5.96 us/call  (code injection every dispatch)
hatchery (spin-wait):       TBD          (theoretical: ~0.1-0.5 us, zero syscalls)
```

**TODO**: Measure `foreign import prim` baseline. Implement spin-wait mode for latency-critical pre-loaded workers.

## Implementation Status

### Phase 1: Minimal Viable Path — DONE

All core primitives working end-to-end: fork server spawn, worker pool, dual injection, dispatch, crash detection.

### Phase 2: Pool and Supervision — PARTIAL

| Item | Status |
|------|--------|
| N workers with configurable pool size | ✓ |
| pidfd_open per worker, add to epoll | ✓ |
| Crash detection (wait4 in dispatch loop) | ✓ |
| First-idle worker selection | ✓ |
| Worker respawn after crash | ✗ |
| `dispatchAsync` | ✗ |
| Timeout support (timerfd) | ✗ |

### Phase 3: Namespace and Hardening — PARTIAL

| Item | Status |
|------|--------|
| Seccomp BPF filter on workers | ✓ |
| `PR_SET_DUMPABLE=0` on fork server | ✓ |
| `CLONE_NEWPID` on fork server | ✗ |
| Cgroup memory limits per worker | ✗ |
| `CLONE_NEWNET` on workers | ✗ |

### Phase 4: trustless-ffi — SCAFFOLDED

| Item | Status |
|------|--------|
| `withFFI`, `call`, `callAsync` | ✓ (callAsync is trivial async wrapper) |
| `TrustlessFFI.Marshal` | ✓ (basic LE encode/decode) |
| Timeout enforcement | ✗ (field exists, not wired) |

### Phase 5: Polish — NOT STARTED

| Item | Status |
|------|--------|
| Graceful shutdown protocol | ✗ (CmdShutdown exists but untested) |
| Worker recycling (kill after N dispatches) | ✗ |
| Monitoring / statistics | ✗ |
| Test suite (crash, timeout, concurrent, stress) | ✗ (bench binary covers basic + crash) |

## Architecture Decisions (Resolved)

1. **Fork server spawns workers via fork(), not separate ELF**: Fork server is small, fork() CoW cost is negligible. Workers inherit ring buffer fds. Single C file contains both server and worker logic.

2. **Dual injection methods**: `process_vm_writev` (cross-process write, no setup) and shared memfd (fork server writes to fd, worker sees via mapping). Configurable per-pool and per-dispatch.

3. **TH compile, not file-embed**: Fork server is compiled at TH time via `$HATCHERY_CC` (musl cross-compiler). `addDependentFile` tracks C source dependencies for recompilation. No separate build step needed.

4. **Workers stay dumpable**: `PR_SET_DUMPABLE=0` would block `process_vm_writev`. Workers are protected by seccomp instead. Fork server is non-dumpable.

5. **Raw machine code at known base**: Workers execute `int fn(void)` at the code region base address. No ELF loading, no relocation. Simplest possible dispatch.

## Architecture Decisions (Open)

1. **Direct memfd writes from Haskell**: Current `dispatch` still serializes code bytes through the socketpair. `prepare` already uses `pidfd_getfd` to get the memfds — extending `dispatch` to write directly to the code memfd would eliminate the socketpair payload overhead for one-shot dispatches too.

2. **Worker respawn strategy**: Simple fork() from fork server? Or snapshot a "template" worker and clone it? Fork is simplest for Phase 2.

3. **Timeout mechanism**: timerfd per dispatch? SIGALRM? Futex with timeout? timerfd is cleanest (integrates with epoll).

4. **Spin-wait mode for pre-loaded workers**: Replace futex wake/wait with spin-loops on both sides (worker spins on `control`, Haskell spins on `status`). Zero syscalls on the hot path — latency drops to cache-line invalidation time (~100-500ns). Tradeoff: burns a CPU core per spinning side. Offer as opt-in mode for latency-critical workloads. Worker side: `while (atomic_load(control) == IDLE) { _mm_pause(); }`. Haskell side: `while (atomic_load(status) != DONE) { _mm_pause(); }`.

5. **ResourceT integration for runtime foreign function registration**: The bracket-based `withPrepared` forces nesting. A `ResourceT` API would let users register sandbox-backed foreign functions flat — natural for applications that discover or compile foreign code dynamically (plugins, JIT, REPL). Each `prepare` returns a key; all are auto-released at scope exit. This effectively gives `foreign import ccall` semantics at runtime: prepare a function once, call it many times, release when done — but with process isolation.

   ```haskell
   runResourceT $ do
     (run42, _) <- allocate (prepare h UseSharedMemfd code42) release
     (runFib, _) <- allocate (prepare h UseSharedMemfd codeFib) release
     -- Use like regular functions; auto-released at scope exit
     liftIO $ do
       a <- run run42
       b <- run runFib
       ...
   ```

## Platform Requirements

- Linux x86_64
- Kernel >= 5.3 (`pidfd_open`)
- Kernel >= 3.17 (`memfd_create`)
- GCC with `-static-pie -nostartfiles` support
- musl cross-compiler (provided by nix flake)

## Future Directions

### Package Hierarchy

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

Combine ghc-fastboot's zero-cost closure transport with hatchery's process isolation to evaluate arbitrary Haskell thunks in a sandbox.

```haskell
safeEvaluate :: SafeEval -> a -> IO (Either EvalFailure a)
```

Architecture: parent freezes thunk → writes to shared memfd → wakes worker (full GHC RTS instance, same binary) → worker thaws, evaluates, freezes result → parent thaws result. Zero relocation on same-binary. RTS scheduler tick control enables timeout enforcement and progress observation.

### `fastboot-distributed` — HPC Closure Distribution

ghc-fastboot's snapshot format as wire format for distributing Haskell data across clusters. Same-binary zero-relocation property means receiving node just maps pages — live closures immediately. RDMA, shared filesystem, or network transport. Demand paging via CoW means cost is proportional to working set, not data size.
