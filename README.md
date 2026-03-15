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
        ├──► Worker 1         futex-suspended until dispatch
        └──► ...              PROT_RWX code region + MAP_SHARED ring buffer
```

A minimal C supervisor (~600 lines, musl static-PIE, no libc) is embedded in the Haskell binary at compile time via Template Haskell. Sandboxed execution contexts are pre-warmed so that dispatch is a memfd write + futex wake — no process spawn on the hot path.

### Measured latency (return 42 workload)

```
unsafe ccall:          <0.01 us/call
safe ccall:             0.07 us/call
hatchery (vm_writev):   5.08 us/call  (full process isolation + seccomp)
hatchery (memfd):       5.33 us/call  (full process isolation + seccomp)
```

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

## Status

Phase 1 is complete: core sandbox works end-to-end with both injection methods and crash detection. See `PLAN.md` for the full roadmap.

**Not yet implemented**: worker respawn on crash, PID namespace isolation (`CLONE_NEWPID`), dispatch timeout enforcement, LLVM codegen (stubbed).

## License

BSD-3-Clause
