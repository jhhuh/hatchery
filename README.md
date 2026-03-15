# hatchery

Process sandbox toolkit for Haskell. Pre-spawned worker pools with microsecond dispatch latency.

Workers are address-space-isolated, seccomp-filtered, and supervised. Crashes, hangs, and wild writes in foreign code cannot propagate to the host process.

## Packages

| Package | Description |
|---|---|
| **hatchery** | Core sandbox primitives — fork server, worker pool, dual code injection, ring buffer IPC |
| **hatchery-llvm** | LLVM IR to machine code bridge via `llvm-tf` |
| **trustless-ffi** | Ergonomic wrapper — foreign calls that can't crash your program |

## Architecture

```
GHC Process (Haskell)
  │
  │  socketpair (control)     pipe (parent-liveness)
  │
  └──► Fork Server            static-PIE C binary, embedded via file-embed
        │                     single-threaded, epoll-based, no libc
        │
        ├──► Worker 0         own address space, seccomp-filtered
        ├──► Worker 1         futex-suspended until dispatch
        └──► ...              PROT_RWX code region + MAP_SHARED ring buffer
```

The fork server is a minimal C binary (~600 lines, musl static-PIE, no libc dependency) embedded in the Haskell binary at compile time. It manages a pool of pre-spawned workers. Code is injected into workers via `process_vm_writev` or shared memfd, then executed by waking the worker with a futex.

**Dispatch latency**: ~3-5 microseconds (excluding code execution time).

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
# Enter dev shell
nix develop

# Build the fork server (must run before cabal build)
make -C hatchery/cbits

# Build all packages
cabal build all

# Run tests
cabal test hatchery-test
```

## Platform requirements

- Linux x86_64
- Kernel >= 5.3 (`pidfd_open`)
- Kernel >= 3.17 (`memfd_create`)

## Lifecycle guarantees

1. **Haskell dies -> fork server dies**: The fork server monitors a pipe to the parent. When the parent exits, the pipe closes, and the fork server exits.
2. **Fork server dies -> all workers die**: Workers have `PDEATHSIG=SIGKILL` set.
3. **Worker crashes -> detected**: Fork server detects via pidfd and reports `Crashed` to Haskell.

## Status

Phase 1 is complete: core sandbox works end-to-end with both injection methods. See `PLAN.md` for the full roadmap.

**Not yet implemented**: worker respawn on crash, PID namespace isolation (`CLONE_NEWPID`), dispatch timeout enforcement, LLVM codegen (stubbed).

## License

BSD-3-Clause
