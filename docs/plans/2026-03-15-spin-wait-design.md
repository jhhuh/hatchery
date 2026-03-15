# Spin-Wait Mode for Pre-Loaded Workers

## Problem

Pre-loaded worker dispatch (`prepare`/`run`) currently uses futex wake/wait,
achieving ~3μs round-trip. The futex syscalls and context switch dominate
latency for trivial workloads. Target: sub-microsecond for fast workloads,
graceful fallback for slow ones.

## Design

Hybrid spin-then-futex on both sides. Spin N iterations for fast completion,
fall back to futex to avoid burning CPU on slow workloads.

### WaitStrategy Config

```haskell
data WaitStrategy
  = FutexWait           -- current behavior (pure futex)
  | SpinWait !Word32    -- spin N iterations, then futex fallback

data HatcheryConfig = HatcheryConfig
  { ...
  , waitStrategy :: !WaitStrategy  -- default: FutexWait
  }
```

Single knob controls both worker-side and Haskell-side wait behavior.
Only affects `prepare`/`run` path. One-shot `dispatch` stays futex-only.

### Worker Side (C, fork_server.c)

`worker_main` loop changes from:

```c
futex_wait(&ring->control, WORKER_IDLE);
```

To hybrid:

```c
for (;;) {
    for (int i = 0; i < spin_count; i++) {
        uint32_t ctl = atomic_load_explicit(&ring->control, memory_order_acquire);
        if (ctl != WORKER_IDLE) goto dispatch;
        __builtin_ia32_pause();
    }
    futex_wait(&ring->control, WORKER_IDLE);
}
```

`spin_count` passed via fork server argv at startup. 0 = pure futex.

### Haskell Side (Cmm via inline-cmm + Haskell outer loop)

**Cmm function** — short-lived, bounded by spin_count, never blocks:

```cmm
W64 hatchery_spin_wait(W64 ring_base, W64 spin_count) {
    W64 i = 0;
    while (i < spin_count) {
        W64 st = %acquire W32[ring_base + RING_STATUS_OFF];
        if (st == WORKER_DONE) goto done;
        if (st == WORKER_CRASHED) goto crashed;
        i = i + 1;
    }
    return (2, 0);  // not ready

done:
    W64 ec = W32[ring_base + RING_EXIT_CODE_OFF];
    %release W32[ring_base + RING_NOTIFY_OFF] = 0;
    %release W32[ring_base + RING_STATUS_OFF] = WORKER_READY;
    return (0, ec);  // success

crashed:
    return (1, 0);
}
```

**Haskell outer loop** — owns the slow path:

```haskell
runSpinWait :: PreparedWorker -> IO DispatchResult
runSpinWait pw = go
  where
    go = case hatchery_spin_wait# ringAddr spinCount of
        (# 0#, ec #) -> pure $ Completed (fromIntegral (I# ec)) Nothing
        (# 1#, _  #) -> pure $ Crashed 0
        (# _,  _  #) -> do
            c_futex_wait_safe (pwRingPtr pw) notifyOffset
            go
```

Key properties:

- Cmm is always brief (bounded by spin_count). Does not hold GHC
  capability for extended periods.
- Fast workloads caught in Cmm spin phase — sub-microsecond.
- Slow workloads fall back to futex via safe FFI — releases capability,
  allows GC.
- `%acquire` load on status: correct on x86 (free MOV) and ARM (LDAR).

### Crash Detection

Fork server is the single crash authority for all workers, including
reserved ones.

Current behavior: reserved workers' pidfds removed from epoll. Haskell
owns crash detection via `kill(pid, 0)`.

New behavior: fork server keeps pidfd in epoll for reserved workers.
On worker death:

1. Reap via `wait4`
2. Release-store `WORKER_CRASHED` to `ring->status`
3. `futex_wake(&ring->notify, 1)` — wakes Haskell if in futex fallback
4. Mark worker dead in pool state

The Haskell spin loop sees `WORKER_CRASHED` naturally. No stop flag,
no liveness syscalls from Haskell, no separate monitoring thread.

### Dispatch Paths Summary

```
                     Worker side              Haskell side
                     ──────────               ────────────
FutexWait            futex_wait (current)     ccall safe futex (current)
SpinWait N           spin N → futex_wait      Cmm spin N → Haskell futex safe
```

## Changes by File

| File | Change |
|------|--------|
| `hatchery/cbits/fork_server.c` | Worker spin loop in `worker_main`; keep pidfd in epoll for reserved workers; write `CRASHED` to ring on worker death |
| `hatchery/cbits/protocol.h` | Add `spin_count` to fork server startup config |
| `hatchery/src/Hatchery/Config.hs` | `WaitStrategy` type, add to `HatcheryConfig` |
| `hatchery/src/Hatchery/Dispatch.hs` | `run` dispatches to spin-wait path; Cmm spin function via inline-cmm; Haskell outer loop with safe futex fallback |
| `hatchery/src/Hatchery/Internal/Vfork.hs` | Pass `spin_count` to fork server argv |
| `hatchery/hatchery.cabal` | Add `inline-cmm` dependency |
| `hatchery-bench/` | Add spin-wait benchmarks |

**Not changed:** `dispatch` (one-shot path stays futex-only), wire protocol
command/response structs, `prepare`/`release` signatures, `ring_buffer.h`.

## Latency Targets

```
hatchery (pre-loaded, futex):    ~3.08 μs  (current, measured)
hatchery (spin-wait, fast path): ~0.1-0.5 μs  (target, spin completes)
hatchery (spin-wait, slow path): ~3 μs + spin overhead  (futex fallback)
```
