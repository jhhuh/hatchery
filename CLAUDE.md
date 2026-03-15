# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Phase 1 complete. Core sandbox works end-to-end (spawn → dispatch → result). LLVM integration stubbed (llvm-ffi build issue). See `artifacts/devlog.md` for known issues and history.

## What This Is

**hatchery** — Linux process sandbox toolkit for Haskell. Pre-spawned worker pool with microsecond dispatch. Workers are address-space-isolated, seccomp-filtered.

**hatchery-llvm** — Bridge: hatchery + llvm-tf. LLVM IR → machine code. Currently a stub.

**trustless-ffi** — Ergonomic wrapper. Foreign code can't crash your program.

## Build Commands

```bash
# Build fork server (must run before cabal build)
nix develop -c make -C hatchery/cbits

# Build all Haskell packages
nix develop -c cabal build all

# Run integration test (requires fork server built first)
nix develop -c cabal test hatchery-test

# Assemble test payloads
nix develop -c nasm -f bin -o hatchery/test-payloads/return42.bin hatchery/test-payloads/return42.asm

# Clean fork server binary
nix develop -c make -C hatchery/cbits clean
```

The fork server binary (`hatchery/cbits/fork_server`) must exist before `cabal build hatchery` — it's embedded via Template Haskell (`file-embed`).

## Architecture

```
GHC Process → socketpair/pipe → Fork Server (static-PIE C, embedded in binary)
                                   ├─► Worker 0 (futex-suspended, seccomp-filtered)
                                   ├─► Worker 1
                                   └─► ...
```

- **Fork server** (`cbits/fork_server.c`): Pure C, static-PIE ELF (musl), single-threaded epoll loop. Spawns workers via `fork()`.
- **Workers**: Own address space, PROT_RWX code region, MAP_SHARED ring buffer (memfd), seccomp filter. Execute injected machine code as `int fn(void)`.
- **Communication**: socketpair for control, ring buffer for data. Futex for synchronization.
- **Lifecycle**: Parent death → pipe EOF → fork server exits. Worker crash detected via pidfd + `kill(pid, 0)` liveness check.

## Package Layout

```
hatchery/          Core sandbox (Haskell library + C fork server)
  src/             Hatchery.{Config,Core,Dispatch}, Internal.{Memfd,Vfork,Protocol,Embedded}
  cbits/           fork_server.c, syscall.h, ring_buffer.h, protocol.h, seccomp_filter.{c,h}, vfork_helper.c
  test/            Integration test
  test-payloads/   Assembly test payloads (.asm → .bin)
hatchery-llvm/     LLVM bridge (stub)
trustless-ffi/     User-facing API
  src/             TrustlessFFI, TrustlessFFI.Marshal
```

## Dual Injection Methods

Pool config (`InjectionCapability`) determines worker code region setup:
- `ProcessVmWritevOnly` — MAP_PRIVATE|MAP_ANONYMOUS code region
- `SharedMemfdOnly` — MAP_SHARED from memfd
- `BothMethods` — MAP_SHARED from memfd, either method per-dispatch

Per-dispatch `InjectionMethod`: `UseProcessVmWritev | UseSharedMemfd`. Mismatch → error.

## Key Gotchas

- **PR_SET_DUMPABLE=0 blocks process_vm_writev** — intentionally omitted from workers
- **Fork server binary must exist before `cabal build`** — Template Haskell embeds it
- **`withHatchery` requires bound thread** — use `-threaded` GHC flag, call from main or `forkOS`
- **4096-byte code buffer in fork_server.c** — limits injected code size (Phase 1 limitation)
- **No worker respawn yet** — crashed workers are marked dead, not replaced (Phase 2)
- **No PID namespace yet** — fork server runs without CLONE_NEWPID (Phase 3)
