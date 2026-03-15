# Direct Dispatch: Bypass Fork Server on Hot Path

## Goal

Cut one-shot `dispatch` latency from ~5500ns to ~500ns (spin-wait) or ~3200ns (futex) by removing the fork server from the dispatch path entirely. Haskell writes code and wakes workers directly.

## Current Path

```
Haskell → [CMD_DISPATCH + code bytes over socketpair] → Fork Server → [inject code] → [wake worker] → [wait] → [RSP_WORKER_DONE over socketpair] → Haskell
```

Two socketpair round-trips + code injection + fork server relay = ~5500ns.

## New Path

```
Haskell → [memcpy code to mmap'd memfd] → [control=RUN via ring buffer] → [spin/futex wait] → [read result from ring buffer]
```

No socketpair. No fork server relay. Same mechanism as `prepare`/`run`, with code write prepended.

## Design

### Startup

`withHatchery` reserves all workers via N × `CMD_RESERVE`. Each returns `(worker_id, ring_fd, code_fd, worker_pid)`. Haskell duplicates fds via `pidfd_getfd`, mmaps each worker's ring buffer and code region. Maintains an idle set as `MVar [WorkerId]`.

Fork server keeps pidfd in epoll for all reserved workers — crash detection still works (writes `WORKER_CRASHED` to ring→status, wakes futex).

### Dispatch

1. Take worker from `MVar [WorkerId]` (blocks if none idle)
2. `memcpy` code to mmap'd code region
3. Set `ring->control = WORKER_RUN`
4. Wait via spin-wait (Cmm) or futex — reuses existing `run` implementation
5. Read result from ring buffer
6. Return worker to idle set (or discard if crashed)

### Capability Restriction

`dispatch` requires `SharedMemfdOnly` or `BothMethods` — needs memfd to mmap. `ProcessVmWritevOnly` errors at dispatch time. Users with that config use `prepare`/`run` instead.

### Crash Handling

Fork server detects worker death via pidfd epoll, writes `WORKER_CRASHED` to ring→status. Haskell's wait loop (spin or futex) already handles this. Crashed workers are removed from idle set permanently (no respawn yet).

### Wire Protocol

No new commands. Reuses `CMD_RESERVE` / `CMD_RELEASE` / `CMD_SHUTDOWN`. `CMD_DISPATCH` remains in protocol for backward compat but is no longer used by the default `dispatch` path.

### Cleanup

`withHatchery` bracket release: munmap all ring buffers and code regions, close duplicated fds, `CMD_RELEASE` all workers, then `CMD_SHUTDOWN`.

## Expected Latency

| Mode | Before | After |
|---|---|---|
| dispatch (spin-wait) | N/A | ~500ns |
| dispatch (futex) | ~5500ns | ~3200ns |
| prepare/run (spin) | ~365ns | unchanged |
| prepare/run (futex) | ~3100ns | unchanged |

## Files to Modify

- **Core.hs**: Reserve all workers at startup, pidfd_getfd + mmap, maintain `MVar [WorkerId]` idle set
- **Dispatch.hs**: `dispatch` uses direct path (write code + run) instead of socketpair
- **direct_helpers.c**: Add `hatchery_write_code` (memcpy to mmap'd code region)
- **Config.hs**: Validate that `dispatch` rejects `ProcessVmWritevOnly`

## What Simplifies

- Fork server is no longer on the dispatch hot path
- `dispatch` and `prepare`/`run` share the same underlying mechanism
- Potential future: unify `dispatch` and `prepare`/`run` into a single code path
