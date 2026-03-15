# hatchery / trustless-ffi

Trustless computation for runtime codegen. Execute JIT-compiled or foreign machine code with full process isolation and fault tolerance, at FFI-competitive latency.

Generate code at runtime with LLVM, dispatch it, and get results back — with the guarantee that crashes, hangs, and wild writes cannot propagate to the host. If foreign code segfaults, you get a `Crashed` result, not a dead process.

## Packages

| Package | Description |
|---|---|
| **hatchery** | Core sandbox primitives — process isolation, dual code injection, ring buffer IPC |
| **hatchery-bench** | Benchmarks — FFI baseline comparison, fault tolerance demo |
| **hatchery-llvm** | LLVM IR to machine code bridge via `llvm-tf` (stub) |
| **trustless-ffi** | Ergonomic wrapper — foreign calls that can't crash your program |

## Architecture

```
GHC Process (Haskell)
  │
  │  socketpair (control)     pipe (parent-liveness)
  │
  └──► Fork Server            static-PIE C binary, compiled + embedded at TH time
        │                     single-threaded, epoll-based, no libc, raw syscalls
        │
        ├──► Worker 0         own address space, seccomp-filtered
        ├──► Worker 1         spin/futex-suspended until dispatch
        └──► ...              PROT_RWX code region + MAP_SHARED ring buffer
```

A minimal C supervisor (~750 lines, musl static-PIE, no libc) is embedded in the Haskell binary at compile time via Template Haskell. Sandboxed execution contexts are pre-warmed so that dispatch is a memfd write + futex wake — no process spawn on the hot path.

### Measured latency (return 42 workload, 100k iterations)

```
foreign import prim:       0.3 ns/call  (register shuffle, no stack frame)
unsafe ccall:              1.4 ns/call  (C ABI overhead)
safe ccall:               68   ns/call  (releases GHC capability)
hatchery (spin-wait Cmm): 365  ns/call  (Cmm spin, no futex syscalls)
hatchery (spin-wait C):   370  ns/call  (C spin, GCC-inlined atomics)
hatchery (pre-loaded):   3100  ns/call  (direct futex wake/wait, no fork server)
hatchery (vm_writev):    5500  ns/call  (code injection + fork server relay)
hatchery (memfd):        5950  ns/call  (code injection + fork server relay)
```

Spin-wait (~365ns) without core pinning. Includes scheduler jitter and per-iteration ccall overhead in the spin loop.
Works with both `-threaded` and single-threaded GHC RTS.

## Quick start

```haskell
import Hatchery
import qualified Data.ByteString as BS

main :: IO ()
main = do
  -- Raw x86_64 machine code: mov eax, 42; ret
  let code = BS.pack [0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3]

  withHatchery defaultConfig $ \h -> do
    result <- dispatch h UseSharedMemfd code
    case result of
      Completed exitCode _ -> print exitCode  -- 42
      Crashed signal       -> error $ "crashed: " ++ show signal
```

Or with the higher-level `trustless-ffi` API:

```haskell
import TrustlessFFI
import qualified Data.ByteString as BS

main :: IO ()
main = do
  let code = BS.pack [0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3]

  withFFI defaultFFIConfig $ \ffi -> do
    result <- call ffi code
    case result of
      Success exitCode _ -> print exitCode
      ForeignCrash msg   -> putStrLn msg
      Timeout            -> putStrLn "timed out"
```

## Code injection methods

The pool's `InjectionCapability` determines how workers set up their code regions. Per-dispatch, you choose which method to use.

| Capability | Code region | Available methods |
|---|---|---|
| `ProcessVmWritevOnly` | `MAP_PRIVATE\|MAP_ANONYMOUS` | `UseProcessVmWritev` only |
| `SharedMemfdOnly` | `MAP_SHARED` from memfd | `UseSharedMemfd` only |
| `BothMethods` (default) | `MAP_SHARED` from memfd | Either, per-dispatch |

**`process_vm_writev`**: Cross-process memory write. Fork server writes code directly into the worker's address space. Requires workers to be dumpable (they are).

**Shared memfd**: Fork server writes code to a memfd that the worker has mapped. No cross-process write needed.

## Building

Requires Nix. The flake provides GHC, musl cross-compiler, LLVM 19, and all Haskell dependencies.

```bash
# Build library
nix build .#hatchery

# Build and run benchmarks
nix build .#hatchery-bench
result/bin/hatchery-bench

# Interactive development
nix develop -c cabal build all
```

The fork server binary is compiled at Template Haskell time via `$HATCHERY_CC` (musl cross-compiler, set automatically by the nix flake). No separate build step needed.

## Platform requirements

- Linux x86_64
- Kernel >= 5.3 (`pidfd_open`)
- Kernel >= 3.17 (`memfd_create`)

## Lifecycle guarantees

1. **Haskell dies → fork server dies**: Dual mechanism — pipe trick (process-scoped fd, POLLHUP on parent death) + `PR_SET_PDEATHSIG=SIGKILL` (safe via `runInBoundThread`).
2. **Fork server dies → all workers die**: Workers have `PDEATHSIG=SIGKILL` set.
3. **Worker crashes → detected**: Fork server detects via `wait4(WNOHANG)` and reports `Crashed` to Haskell.

## Dispatch modes

| Mode | Latency | Use case |
|---|---|---|
| `dispatch` | ~5.5 μs | One-shot: inject code + execute + return result |
| `prepare` / `run` | ~3.1 μs (futex) or ~365 ns (spin) | Pre-load code once, re-run many times |

**Spin-wait** (`SpinWait N`): Worker and Haskell spin N iterations before falling back to futex. Eliminates syscalls on the hot path. Configurable via `waitStrategy` in `HatcheryConfig`.

## Status

Phase 1 complete, Phase 2 partial. Core sandbox works end-to-end with both injection methods, crash detection, and spin-wait mode.

**Not yet implemented**: worker respawn on crash, PID namespace isolation (`CLONE_NEWPID`), dispatch timeout enforcement, LLVM codegen (stubbed), direct memfd writes for `dispatch` (would cut one-shot latency to ~3μs).

## License

BSD-3-Clause
