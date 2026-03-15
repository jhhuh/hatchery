# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Pre-implementation. `PLAN.md` is the authoritative design document — read it fully before any architectural decisions. No source code exists yet.

## What This Is

**hatchery** — A Linux process sandbox toolkit for Haskell. Manages a supervised pool of pre-spawned worker processes with microsecond dispatch latency. Workers are address-space-isolated, seccomp-filtered, and contained in a PID namespace.

**trustless-ffi** — Ergonomic wrapper over hatchery that makes foreign code execution feel like a normal FFI call, with the guarantee that crashes/hangs/wild writes can't propagate to the host.

## Architecture (must-know)

```
GHC Process → socketpair/pipe → Fork Server (static-PIE C, PID 1 in CLONE_NEWPID)
                                   ├─► Worker 0 (futex-suspended, seccomp-filtered)
                                   ├─► Worker 1
                                   └─► ...
```

- **Fork server**: Pure C, static-PIE ELF (musl, no libc dependency), embedded in Haskell binary via `file-embed`. Single-threaded, epoll-based. Spawns workers via `fork()` (not separate ELFs).
- **Workers**: Own address space, PROT_RWX code region, MAP_SHARED ring buffer (memfd), seccomp filter. Wake via futex, execute injected machine code, report via ring buffer.
- **Communication**: socketpair for control (commands/responses), shared ring buffer for bulk data (code bytes, results). ~3-5μs dispatch latency.
- **Lifecycle**: Haskell dies → pipe EOF → fork server exits → PID namespace kills all workers. Worker crash → waitpid → respawn.

## Two-Package Layout

```
hatchery/          Core sandbox primitives (Haskell library + C fork server)
  src/             Haskell: Hatchery.{Config,Core,Dispatch}, Internal.{Memfd,Vfork,Protocol,Embedded}
  cbits/           C: fork_server.c, worker_template.c, protocol.h, ring_buffer.h, seccomp_filter.c, syscall.h, vfork_helper.c
trustless-ffi/     User-facing FFI wrapper (Haskell only, depends on hatchery)
  src/             TrustlessFFI, TrustlessFFI.Marshal
```

## Build System

- C components: `musl-gcc -static-pie -nostartfiles -fPIE -Os` (see `hatchery/cbits/Makefile`)
- Haskell: Cabal 3.0, multi-package. `hatchery.cabal` includes `cbits/vfork_helper.c` as c-sources
- Fork server ELF embedded via Template Haskell (`file-embed`)
- Nix flake required (per project rules). C build should be a Nix derivation

## Platform Requirements

- Linux only (x86_64 initially)
- Kernel ≥ 5.9 for unprivileged `CLONE_NEWPID + CLONE_NEWUSER` via clone3
- Kernel ≥ 5.3 for `pidfd_open`
- Kernel ≥ 3.17 for `memfd_create`

## Implementation Order

Follow the phased plan in `PLAN.md`. Phase 1 (minimal viable path) builds bottom-up: syscall wrappers → ring buffer → protocol → worker → fork server → Haskell FFI bindings → Core → Dispatch.

## Key Design Constraints

- Fork server and workers are **pure C** — no GHC RTS, no Haskell heap
- `withHatchery` must be called from a **bound thread** (enforced at runtime)
- Workers execute **raw machine code** at a known base address (not ELF, not relocatable)
- Fork server uses `fork()` for workers (not vfork+execveat) — it's small enough that page table cost is negligible
