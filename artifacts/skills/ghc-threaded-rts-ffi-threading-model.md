# GHC -threaded RTS: FFI and Threading Model

## Core Concepts

- **HEC (Haskell Execution Context)** = **Capability** = fixed struct in memory. Holds run queue, allocator, execution context. Count set by `-N`.
- **Task** = OS thread assigned to execute on a HEC. Tasks can be reassigned between HECs.
- **Bound thread** = Haskell thread pinned to a specific OS task (created by `forkOS` or main thread). Cannot migrate to a different OS thread.

## Safe FFI Mechanics

1. Haskell thread releases its HEC (capability)
2. OS thread (task) enters C code — can block freely
3. Another task picks up the HEC to run other Haskell threads
4. When C returns, the OS thread re-acquires a HEC

**Key guarantee** (from GHC manual): In the `-threaded` RTS, safe FFI does NOT block other Haskell threads. Only requires: (a) link with `-threaded`, (b) `foreign import` not marked `unsafe`.

In the **single-threaded** RTS (no `-threaded`), safe FFI DOES block all other Haskell threads until the call returns.

## `-N` Flag Behavior

- No `-N`: defaults to `-N1` (1 HEC)
- `-N` (no number): auto-detect = number of **hardware threads** (hyperthreads), not physical cores
- `-N⟨x⟩`: exactly x HECs

For single-threaded workloads, `-N1` is fastest. Higher `-N` adds scheduler overhead.

## `foreign import prim` vs `ccall unsafe` vs `ccall` (safe)

| Type | Releases HEC? | Stack frame? | Use for |
|---|---|---|---|
| `foreign import prim` | No | None (STG registers) | Ultra-fast, Cmm-level |
| `ccall unsafe` | No | C ABI overhead | Fast C, guaranteed non-blocking |
| `ccall` (safe, default) | Yes | C ABI + capability release | Blocking or long-running C |

## PR_SET_PDEATHSIG with -threaded

`PR_SET_PDEATHSIG` fires when the **creating OS thread** exits, not the process. With `-threaded`, vfork/fork happens on a task (OS thread). If that task is destroyed, the child gets the death signal even though the Haskell process is alive.

**Mitigation**: `runInBoundThread` pins the Haskell thread to a specific OS task for the bracket's lifetime. The task won't be destroyed while the bound thread is alive.

## References

- Marlow, "Extending the Haskell FFI with Concurrency": https://www.microsoft.com/en-us/research/wp-content/uploads/2004/09/conc-ffi.pdf
- GHC Illustrated (HEC/Task model): https://takenobu-hs.github.io/downloads/haskell_ghc_illustrated.pdf
- GHC User's Guide, RTS options: https://downloads.haskell.org/ghc/latest/docs/users_guide/runtime_control.html
- GHC User's Guide, Using Concurrent Haskell: https://downloads.haskell.org/ghc/latest/docs/users_guide/using-concurrent.html
