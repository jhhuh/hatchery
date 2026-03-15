# Hatchery Dev Journal

## 2026-03-15 — Project initialized and Phase 1 complete

### Design decisions resolved
- Dual injection methods: `process_vm_writev` + shared memfd, per-dispatch selection
- Pool-level `InjectionCapability` config: `ProcessVmWritevOnly | SharedMemfdOnly | BothMethods`
- Single fork server ELF, workers spawned via `fork()` (not separate binaries)
- Raw machine code dispatch at known base address
- LLVM codegen via separate `hatchery-llvm` bridge package, user API in `trustless-ffi`

### Package structure
```
hatchery/          Core sandbox
hatchery-llvm/     LLVM bridge (stub, builds with llvm-tf 21 + LLVM 19)
trustless-ffi/     User API (wraps hatchery)
```

### Build system evolution
1. Started with `file-embed` + separate `make -C hatchery/cbits` step
2. Switched to TH splice that compiles fork server at Haskell compile time via `$HATCHERY_CC`
   - `Hatchery.Internal.Compile`: shells out to `$HATCHERY_CC` (musl cross-compiler) in Q monad
   - `Hatchery.Internal.Embedded`: `$(compileForkServer >>= \bs -> [| bs |])`
   - Pattern from `inline-c-cuda`: `readProcessWithExitCode` in TH, `addDependentFile` for recompilation
3. Nix flake uses `haskellPackages.shellFor` + `packageSourceOverrides` + `callHackage` overrides
   - `llvm-ffi` follows nixpkgs pattern: `LLVM = null` + `addBuildDepends [llvm.lib llvm.dev]`
   - `HATCHERY_CC` set via `preBuild` in derivation override for `nix build`
   - `HATCHERY_CC` set via `shellHook` for `nix develop`
4. `nix build .#hatchery` works end-to-end (tests disabled in sandbox — vfork+execveat blocked)

### Bugs found and fixed
1. **`PR_SET_DUMPABLE=0` blocks `process_vm_writev`**: Moved to fork server only. Workers stay dumpable.
2. **Dispatch deadlock on worker crash**: Added 100ms futex timeout + `kill(pid, 0)` liveness check.
3. **syscall.h futex signature**: `int *` → `uint32_t *`, added `#include <stdint.h>`.
4. **GHC 9.10 `BSI.withForeignPtr`**: Moved to `Foreign.ForeignPtr`.
5. **GCC 15 stack protector**: `-nostartfiles` binary has no TLS, but GCC 15 enables stack protector by default → reads `%fs:0x28` → segfault. Fixed with `-fno-stack-protector`.
6. **GCC 15 `_start` prologue**: GCC modifies RSP before inline asm could capture it. Fixed with `__attribute__((naked))` on `_start`, separate `real_start` function.

## 2026-03-15 — Dispatch hang resolved, direct dispatch API

### Root cause: `kill(pid, 0)` returns 0 for zombie processes

The "dispatch hang" was actually a **crash detection failure**, not a dispatch failure. The dispatch worked fine — code was injected and executed correctly. But when the fault tolerance test sent a UD2 instruction (intentional crash), the worker became a zombie, and `kill(pid, 0)` kept returning 0 (zombies have PID entries). The fork server looped forever thinking the worker was alive.

**Fix**: Replaced `kill(pid, 0)` with `wait4(pid, WNOHANG)` which correctly reaps zombies.

**How we found it**: strace with `-f` showed the first fork server (PID 2465073) handling dispatches correctly — all 2000+ warmup+benchmark dispatches succeeded. The hang was in the SECOND `withHatchery` (fault tolerance test, PID 2465075), which dispatched a 2-byte UD2 payload. The worker got SIGILL and died, but the fork server couldn't detect it.

### Lifecycle improvements

1. **`runInBoundThread` instead of manual bound-thread checks**: `withHatchery` now wraps the bracket in `runInBoundThread`, which works with both `-threaded` (creates bound thread if needed) and single-threaded RTS (runs directly). Removed the `-threaded` requirement.

2. **`PR_SET_PDEATHSIG=SIGKILL` on fork server**: Belt-and-suspenders with the pipe trick. Safe because `runInBoundThread` guarantees the spawning OS thread lives for the Hatchery's lifetime.

### Package restructure

- Extracted `hatchery-bench` into a separate cabal package (reduces rebuild time when only library changes)
- Bench includes both `-threaded` and single-threaded executables
- Added FFI baseline comparison (unsafe ccall, safe ccall) to bench

### `prepare`/`run`/`release` API for pre-loaded payloads

New API allows loading code once and re-running without re-injection:

```haskell
prepare :: Hatchery -> InjectionMethod -> ByteString -> IO PreparedWorker
run     :: PreparedWorker -> IO DispatchResult
release :: PreparedWorker -> IO ()
withPrepared :: Hatchery -> InjectionMethod -> ByteString -> (PreparedWorker -> IO a) -> IO a
```

Wire protocol additions: `CMD_RUN`, `CMD_RESERVE`, `CMD_RELEASE`, `RSP_WORKER_RESERVED`. Fork server tracks reserved workers and excludes them from auto-selection. Reserved workers' pidfds are removed from epoll (Haskell owns crash detection).

### Direct Haskell↔worker dispatch

For `PreparedWorker.run`, Haskell communicates directly with the worker via mmap'd ring buffer + futex, bypassing the fork server entirely:

1. Fork server sends `ring_fd`, `code_fd`, `worker_pid` in `RSP_WORKER_RESERVED`
2. Haskell duplicates fds via `pidfd_getfd` (requires fork server temporarily dumpable)
3. Haskell mmaps the ring buffer
4. `run`: `atomic_store(control=RUN)` → `futex_wake` → `futex_wait(notify)` → read result

`PR_SET_DUMPABLE=0` is restored on the fork server after the `pidfd_getfd` window (next command closes it).

### Measured latency (return 42 workload)

```
unsafe ccall:              <0.01 us/call
safe ccall:                ~0.08 us/call
hatchery (pre-loaded):     ~3.08 us/call  (direct futex, no fork server relay)
hatchery (vm_writev):      ~5.23 us/call  (code injection every dispatch)
hatchery (memfd):          ~5.96 us/call  (code injection every dispatch)
```

Both `-threaded` and single-threaded RTS work. Single-threaded is slightly faster (~5.1μs vs ~5.6μs for dispatch).

### Known issues
- **No PID namespace isolation**: Phase 3 task.
- **4096-byte code buffer in fork_server.c**: Caps injected code size.
- **No worker respawn**: Crashed workers not replaced.
- **Crash signal not reported**: `Crashed` result always has signal=0. Fork server's `wake_and_wait` doesn't capture the actual signal from `wait4`.
- **`dispatch` still serializes code through socketpair**: Original design intended Haskell to write directly to code memfd. `prepare` path already has the fds — `dispatch` could do the same.

## 2026-03-15 — Spin-wait mode implemented

### Design

Hybrid spin-then-futex on both sides:
- **Worker side**: spin N iterations on `control` with `__builtin_ia32_pause()`, then fall back to `futex_wait`. Controlled by `spin_count` passed via fork server argv.
- **Haskell side**: Cmm spin loop via `inline-cmm` (`foreign import prim`), bounded by spin_count. Returns to Haskell for safe FFI futex_wait fallback (releases GHC capability, allows GC).
- **Crash detection**: Fork server keeps pidfd in epoll for reserved workers. On worker death, writes `WORKER_CRASHED` to `ring->status` and wakes futex. Haskell spin loop sees it naturally.

### Config

```haskell
data WaitStrategy = FutexWait | SpinWait !Word32
-- SpinWait 10000 = spin 10k iterations before futex fallback
```

### Cmm details

- GHC Cmm `%acquire`/`%release` only support `W_` (machine word), not `bits32`. Used plain `bits32` loads/stores which are correct on x86_64 (TSO provides natural acquire/release). ARM would need `W_` loads with masking.
- `inline-cmm`'s `[cmm|...|]` quasiquoter only parses single return type. Used `verbatim` + manual `foreign import prim` for the two-return-value function.
- `#include "Cmm.h"` needed for `W_` macro; `W32` macro doesn't expand in memory access expressions, so used `bits32` directly.

### Measured latency

```
unsafe ccall:              <0.01 us/call
safe ccall:                ~0.07 us/call
hatchery (pre-loaded):     ~3.22 us/call  (direct futex, no fork server relay)
hatchery (spin-wait):      ~0.50 us/call  (Cmm spin, N=10000)
hatchery (vm_writev):      ~5.50 us/call  (code injection every dispatch)
hatchery (memfd):          ~5.52 us/call  (code injection every dispatch)
```

Spin-wait is **6.4x faster** than futex for the pre-loaded path.

### Known issues
- **x86_64 only**: Cmm spin uses plain loads (correct on x86 TSO). ARM needs `%acquire`/`%release` with `W_` and masking.
- **No pause instruction in Cmm**: The Cmm spin loop doesn't emit `PAUSE` (x86 hint for spin-wait loops). GHC Cmm has no intrinsic for it. Could add via inline asm in future.
- **`dispatch` still serializes through socketpair**: Unchanged from before.

## Next steps for following sessions

### Immediate (Phase 2 completion)

1. **Direct memfd writes for `dispatch`** — Extend the `pidfd_getfd` + mmap pattern from `prepare` to regular `dispatch`. Eliminate code serialization through the socketpair entirely. Socketpair carries only control signals.

2. **ResourceT integration** — Add `ResourceT`-compatible API for flat registration of runtime foreign functions. Avoids bracket nesting for applications that discover/compile code dynamically (plugins, JIT, REPL).

3. **Worker respawn** — When a worker crashes, fork server spawns a replacement via `fork()`. Update pool state, re-add pidfd to epoll.

### Later (Phase 3+)

4. **`CLONE_NEWPID`** — Fork server as PID 1 in a PID namespace. Belt-and-suspenders for worker cleanup.
5. **Timeout enforcement** — timerfd per dispatch, integrated with epoll.
6. **TH compile pattern extraction** — The `compileForkServer` TH pattern (env var compiler + `addDependentFile` + `readProcessWithExitCode` in Q monad) is reusable. Consider extracting as a standalone package (`th-compile-embed` or similar).
