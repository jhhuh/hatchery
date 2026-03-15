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

### Measured latency (final)

```
foreign import prim:       0.3 ns   (register shuffle, no stack frame)
unsafe ccall:              1.4 ns   (C ABI overhead: save/restore regs, stack align)
safe ccall:               67.0 ns   (releases GHC capability, allows GC)
hatchery (spin-wait Cmm): 349  ns   (Cmm spin, no futex_wake, cache-line RT)
hatchery (spin-wait C):   391  ns   (C spin, no futex_wake, cache-line RT)
hatchery (pre-loaded):   3105  ns   (direct futex wake/wait, no fork server)
hatchery (vm_writev):    5561  ns   (code injection + fork server relay)
hatchery (memfd):        6231  ns   (code injection + fork server relay)
```

Two spin-wait implementations available (`SpinWait` = Cmm, `SpinWaitC` = C).
Both hit ~350-400ns without core pinning. Likely includes scheduler jitter and per-iteration ccall overhead.

### Interpretation

**prim (0.3ns) vs unsafe ccall (1.4ns)**: `foreign import prim` uses the STG calling convention — arguments and results pass in GHC's own machine registers (R1, R2, ...) with no stack frame. `unsafe ccall` must transition to the C ABI (push callee-saved registers, align stack, follow System V AMD64 calling convention). The 4x gap is purely calling convention overhead. Both are negligible in absolute terms.

**safe ccall (67ns)**: The safe FFI releases the GHC capability before entering C, allowing other Haskell threads and the GC to run. Re-acquiring the capability on return involves an atomic CAS + potential scheduler interaction. The ~66ns gap over unsafe is the cost of capability release/reacquire.

**spin-wait (349ns)**: Zero syscalls on the hot path. The ~350ns is:
- Cross-process cache-line round-trip: Haskell writes `control` (core A) → worker reads it (core B) → worker writes `status` (core B) → Haskell reads it (core A). Two cache-line invalidation round-trips at ~40-80ns each on modern Intel (intra-socket), so the theoretical floor is ~80-160ns.
- Haskell-side overhead: prim call/return (Cmm) or unsafe ccall entry/exit (C), plus the seq_cst atomic reads in the spin loop. A few iterations execute before the worker's status write becomes visible.
- No core pinning (`taskset`): OS scheduler may place processes on suboptimal cores or migrate them mid-run, adding jitter.
- Per-iteration ccall: each spin poll calls `hatchery_atomic_read32` via ccall (cross-compilation-unit, no inlining), which dominates per-iteration cost on x86 where seq_cst loads are plain MOVs.

The ~350ns includes significant overhead beyond the cache-coherency floor. Core pinning and eliminating the ccall per spin iteration would likely bring this closer to the ~100-160ns theoretical minimum.

**Cmm (349ns) vs C (391ns)**: The Cmm path is ~40ns faster. `foreign import prim` avoids the C ABI transition on every `run` call. The C spin loop itself is tighter (GCC inlines the atomics), but the entry/exit overhead of `unsafe ccall` slightly outweighs this.

**pre-loaded futex (3105ns) vs spin-wait (349ns)**: The 2756ns gap is two futex syscalls. `futex_wake` on the wake side (~200ns, now eliminated in spin-wait) and `futex_wait` + wakeup latency on the Haskell wait side (~2500ns). The futex_wait path involves: syscall entry → kernel futex hash table lookup → schedule the waiter → later: wake event → context switch → syscall return.

**dispatch paths (5561-6231ns)**: These go through the fork server. The additional ~2500-3000ns over pre-loaded futex is: Haskell writes command+code over socketpair (~500ns) → fork server reads from socketpair (~200ns) → fork server injects code via pwrite/process_vm_writev (~500ns) → fork server wakes worker and waits → fork server writes response over socketpair → Haskell reads response. Two extra socketpair round-trips and code injection explain the gap.

**memfd vs vm_writev (6231 vs 5561ns)**: Similar magnitude, noise-level difference for small payloads (6 bytes). Both involve a kernel write path. Larger payloads would favor memfd (no per-page cross-process table walk).

### Known issues
- ~~**Hardcoded ring buffer offsets**~~: Resolved — see below.
- **ccall overhead in Cmm spin loop**: Each poll iteration calls `hatchery_atomic_read32` via ccall (cross-compilation-unit, no inlining). On x86 where seq_cst loads are free MOVs, the ccall overhead dominates the per-iteration cost.
- **x86_64 only**: Cmm spin uses seq_cst via C wrappers. ARM would need different treatment.
- **`dispatch` still serializes through socketpair**: Unchanged from before.
- **No core pinning in benchmarks**: ~370ns may include scheduler jitter. `taskset` pinning to same-socket cores could reveal lower floor.

## 2026-03-15 — Ring buffer offset hardcoding eliminated

### Problem

Ring buffer struct offsets were hardcoded in three places:
- `direct_helpers.c`: `#define RING_STATUS_OFF 128` etc.
- `SpinWait.hs` Cmm string: `ring_base + 128`, `ring_base + 164`, `ring_base + 64`
- `ring_buffer.h`: the struct definition (source of truth)

Adding or reordering fields required manually recalculating offsets in all three locations.

### Solution

Split `ring_buffer.h` into `ring_buffer_layout.h` (struct + enums only, no syscall.h/futex deps) and a thin `ring_buffer.h` wrapper. This enables:

1. **`direct_helpers.c`**: replaced hardcoded `#define`s with `offsetof(struct ring_buffer, field)` via `#include "ring_buffer_layout.h"`.
2. **`RingOffsets.hsc`**: new module using `hsc2hs` `#{offset struct ring_buffer, field}` to generate Haskell constants at build time.
3. **`SpinWait.hs`**: imports `RingOffsets` and splices values into the Cmm `verbatim` string via `show`.

Header split was needed because `ring_buffer.h` includes `syscall.h` (inline asm) which is incompatible with hsc2hs. `ring_buffer_layout.h` only needs `<stdint.h>` + `<stdatomic.h>`.

TH staging restriction requires offsets in a separate module from the `verbatim` splice — hence `RingOffsets.hsc` rather than putting `#{offset}` directly in `SpinWait.hsc`.

### Verified

Benchmark numbers unchanged (no regression):
```
hatchery (spin-wait Cmm): 364  ns
hatchery (spin-wait C):   365  ns
hatchery (pre-loaded):   3192  ns
hatchery (vm_writev):    5515  ns
hatchery (memfd):        5949  ns
```

### GHC -threaded RTS investigation (no bug found)

Benchmark appeared to "hang" with `-threaded` and no explicit `-N` flag. Investigated via strace (`-f` with full syscall tracing, 870k lines) and reviewed GHC RTS threading model (Marlow's "Extending the Haskell FFI with Concurrency" paper, GHC manual, takenobu-hs GHC illustrated PDF).

**What we explored:**
- GHC RTS threading model: HEC (capability) = fixed struct holding execution context; Task = OS thread assigned to a HEC. Tasks can be reassigned. Safe FFI releases the HEC so other tasks can pick it up.
- `PR_SET_PDEATHSIG` tracks the creating **thread**, not process — relevant for fork server lifetime with `-threaded`. `runInBoundThread` in `withHatchery` keeps the vforking OS thread alive for the bracket's duration, so PDEATHSIG is safe.
- Safe FFI in `-threaded` does NOT block other Haskell threads (confirmed by GHC manual: "it is only necessary to use the -threaded option when linking your program, and to make sure the foreign import is not marked unsafe").
- `fdReadBuf`/`fdWriteBuf` from `System.Posix.IO` are safe FFI — raw blocking `read()`/`write()`, not using GHC's I/O manager.
- `-N` without argument picks up hardware thread count (hyperthreads), not physical cores.

**Conclusion:** No bug. The benchmark takes ~15s with `-threaded` default (implicit `-N1`), and even longer with `-N` (all cores — more HEC scheduler overhead for single-threaded workload). The test timeout was 10s. All configurations complete correctly:

| Config | Time |
|---|---|
| `-threaded +RTS -N1` | ~8s |
| `-threaded` (no flags, implicit `-N1`) | ~15s |
| `-threaded +RTS -N` (all cores) | ~15s |
| `-threaded +RTS -N2` | ~15s |
| non-threaded | ~15s |

**References for future sessions:**
- Marlow's FFI concurrency paper: https://www.microsoft.com/en-us/research/wp-content/uploads/2004/09/conc-ffi.pdf
- GHC illustrated (HEC/Task/capability model): https://takenobu-hs.github.io/downloads/haskell_ghc_illustrated.pdf
- `-keep-tmp-files` GHC flag to inspect `inline-cmm` generated `.cmm` files (but note: `inline-cmm` explicitly `removeFile`s the `.cmm` after compilation — would need to patch the library to keep them)

## 2026-03-15 — Direct dispatch: fork server bypassed entirely

### Design

Went further than originally planned. Instead of just writing code to memfd and sending a lightweight command to the fork server, we removed the fork server from the dispatch path entirely:

1. `withHatchery` reserves ALL workers via `CMD_RESERVE` at startup
2. `pidfd_getfd` + `mmap` for each worker's ring buffer and code memfd
3. Idle workers tracked by `MVar [Word32]` on the Haskell side
4. `dispatch` = take idle worker → memcpy code to memfd → wake worker → wait → return to idle
5. Fork server is now lifecycle-only: spawn workers, detect crashes via pidfd epoll, shutdown

`prepare`/`run`/`release` also simplified: `prepare` takes from the same MVar pool, writes code, runs once, sets `spin_mode`. `release` returns to pool. `PreparedWorker` now wraps `WorkerMapping`.

### Bugs found and fixed

1. **MVar deadlock**: `newMVar []` in acquire + `putMVar` in `reserveAllWorkers` → deadlock. Fixed: `newEmptyMVar`.
2. **spin_mode race**: Setting `spin_mode=1` at startup causes `c_wake_worker_spin` (no futex_wake) to miss workers that fell back to `futex_wait`. Fixed: `dispatch` always uses `c_wake_worker` (futex_wake). Only `prepare` sets `spin_mode` after a successful initial run. `run` uses spin-wake.
3. **Crash detection hang**: `c_wait_worker` only checked for `WORKER_DONE`, not `WORKER_CRASHED`. Crashed workers (zombies) passed `kill(pid, 0)` check → infinite loop with 100ms futex timeout. Fixed: added `WORKER_CRASHED` status check.

### Measured latency

```
foreign import prim:          0.3 ns
unsafe ccall:                 1.3 ns
safe ccall:                  72   ns
hatchery (dispatch futex):  3410  ns   (direct memfd write + futex wake/wait)
hatchery (dispatch spin):    691  ns   (direct memfd write + spin-wait)
hatchery (pre-loaded):      3162  ns   (no code write, futex wake/wait)
hatchery (spin-wait Cmm):    428  ns   (no code write, Cmm spin)
hatchery (spin-wait C):      399  ns   (no code write, C spin)
```

**Before → After**:
- dispatch (futex): ~5500ns → 3410ns (**-38%**)
- dispatch (spin): N/A → 691ns (**new — 8x faster than old dispatch**)
- pre-loaded/spin-wait: unchanged (same mechanism as before)

### Interpretation

**dispatch spin (691ns)**: The ~260ns gap over pre-loaded spin-wait (428ns) is the per-call memcpy + code_len write. This is the cost of code injection on a hot path — negligible for real workloads.

**dispatch futex (3410ns)**: The ~250ns gap over pre-loaded futex (3162ns) is the same memcpy overhead. The big win vs old dispatch (~5500ns) is eliminating the fork server relay (two socketpair round-trips + code serialization).

### What simplified

- `Dispatch.hs`: 294 lines → 168 lines. Removed all fork-server protocol interaction (pidfd_getfd, mmap, CMD_RESERVE, CMD_DISPATCH, CMD_RELEASE).
- `dispatch` and `prepare`/`run` now share the same underlying mechanism (`runDirect`).
- Fork server no longer on the hot path.
- `PreparedWorker` simplified: wraps `WorkerMapping` from pool (no separate mmap lifecycle).

## Next steps for following sessions

### Following sessions (Phase 2 completion)

2. **Worker respawn** — When a worker crashes, fork server spawns a replacement via `fork()`. Update pool state. Straightforward since fork server already monitors all workers' pidfds via epoll.

3. **ResourceT integration** — `ResourceT`-compatible API for flat `allocate`/`release` of sandbox-backed foreign functions. Avoids bracket nesting for plugins, JIT, REPL use cases.

### Later (Phase 3+)

4. **`CLONE_NEWPID`** — Fork server as PID 1 in a PID namespace.
5. **Timeout enforcement** — timerfd per dispatch, integrated with epoll.
6. **TH compile pattern extraction** — `compileForkServer` TH pattern as standalone package.
