# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Phase 1 complete, Phase 2 partial. Core sandbox works end-to-end. Fork server bypassed entirely on dispatch hot path — Haskell writes code directly to mmap'd memfd and wakes workers via ring buffer. One-shot dispatch: ~691ns (spin-wait) / ~3410ns (futex). Pre-loaded run: ~428ns (spin) / ~3162ns (futex). LLVM integration stubbed (llvm-ffi build issue). See `artifacts/devlog.md` for history.

## What This Is

**hatchery** — Linux process sandbox toolkit for Haskell. Pre-spawned worker pool with microsecond dispatch. Workers are address-space-isolated, seccomp-filtered.

**hatchery-llvm** — Bridge: hatchery + llvm-tf. LLVM IR → machine code. Currently a stub.

**trustless-ffi** — Ergonomic wrapper. Foreign code can't crash your program.

## Build Commands

Two build modes — use the right one for the task:

### Interactive development (`nix develop -c cabal ...`)

For fast iteration during active development. Uses cabal's incremental builds.

```bash
nix develop -c cabal build all
nix develop -c cabal build hatchery       # single package
```

### Full / release builds (`nix build`)

For verifying the complete build, running tests, or producing binaries for testing/benchmarking. Always use `nix build` for these — never `nix develop -c cabal test/bench`.

```bash
nix build .#hatchery
nix build .#hatchery-llvm
nix build .#trustless-ffi
```

**Note**: Tests are disabled (`dontCheck`) in the nix build. Hatchery uses `vfork`, `execveat`, `clone`, `memfd_create`, seccomp, and pidfds — all blocked by the nix-daemon's build sandbox. Tests must be run outside the nix sandbox (e.g. directly via the built binary or in `nix develop`).

### Other commands

```bash
# Build fork server standalone (alternative to TH path, useful for debugging)
nix develop -c make -C hatchery/cbits

# Assemble test payloads
nix develop -c nasm -f bin -o hatchery/test-payloads/return42.bin hatchery/test-payloads/return42.asm
```

### Fork server build path

The fork server ELF is compiled **at TH time** by `Hatchery.Internal.Compile`, which shells out to `$HATCHERY_CC` (musl cross-compiler). The flake sets this env var automatically. The `cbits/Makefile` is an alternative standalone build path for debugging. Either way, the fork server ends up embedded in the Haskell binary via `Hatchery.Internal.Embedded`.

## Architecture

```
GHC Process ──mmap'd memfd──► Worker 0 (spin/futex-suspended, seccomp-filtered)
     │                        Worker 1
     │ socketpair/pipe         ...
     └──► Fork Server         lifecycle only: spawn, crash detect, shutdown
```

- **Fork server** (`cbits/fork_server.c`): Pure C, static-PIE ELF (musl), no libc, raw syscalls (`syscall.h`). Single-threaded epoll loop. Spawns workers via `fork()`. Not on the dispatch hot path — only handles lifecycle (spawn, crash detection via pidfd epoll, shutdown).
- **Workers**: Own address space, PROT_RWX code region, MAP_SHARED ring buffer (memfd), seccomp filter. Execute injected machine code as `int fn(void)`.
- **Dispatch path**: At startup, all workers are reserved and their ring buffers + code memfds are mmap'd into Haskell. `dispatch` writes code directly to mmap'd memfd, sets `control=RUN` in ring buffer, waits via spin or futex. No socketpair on the hot path.
- **Communication**: Ring buffer for control + synchronization (`ring_buffer_layout.h`). Socketpair used only at startup (CMD_RESERVE) and shutdown (CMD_SHUTDOWN). Field offsets generated at build time via `hsc2hs` (`RingOffsets.hsc`) and `offsetof()` (`direct_helpers.c`).
- **Idle tracking**: `MVar [Word32]` on Haskell side. Workers taken/returned per dispatch.
- **Lifecycle**: Parent death → pipe EOF → fork server exits. Worker crash detected via pidfd epoll (fork server writes `WORKER_CRASHED` to ring buffer status).
- **Haskell spawn path**: `Core.withHatchery` → `Vfork.spawnForkServer` (FFI to `vfork_helper.c`) → `execveat` of the embedded ELF via memfd.

### Wire protocol

Command/response are fixed-size C structs sent over the socketpair. Only used at startup (`CMD_RESERVE`) and shutdown (`CMD_SHUTDOWN`). `CMD_DISPATCH` exists in protocol but is no longer used by the default dispatch path. `Hatchery.Internal.Protocol` must match `protocol.h` exactly (enum values, struct layouts, field offsets).

## Injection Capability

Pool config (`InjectionCapability`) determines worker code region setup:
- `ProcessVmWritevOnly` — MAP_PRIVATE|MAP_ANONYMOUS code region. **`dispatch` not supported** (requires memfd). Use `prepare`/`run` only.
- `SharedMemfdOnly` — MAP_SHARED from memfd
- `BothMethods` — MAP_SHARED from memfd (default)

`dispatch` always writes code directly to the mmap'd memfd. The `InjectionMethod` parameter is kept for API compatibility but ignored.

## Key Gotchas

- **`$HATCHERY_CC` must be set** — TH compilation fails without it. The nix flake sets it automatically.
- **PR_SET_DUMPABLE=0 blocks process_vm_writev** — intentionally omitted from workers
- **`withHatchery` uses `runInBoundThread`** — works with both `-threaded` (creates bound thread if needed) and single-threaded RTS (runs directly)
- **4096-byte code buffer in fork_server.c** — limits injected code size (Phase 1 limitation)
- **`-fno-stack-protector` required** — GCC 15 enables stack protector by default, but `-nostartfiles` binary has no TLS → segfault on `%fs:0x28` access
- **`_start` must be `naked`** — GCC 15 adds prologue that corrupts RSP before inline asm can capture it
- **`dispatch` always uses futex_wake** — workers may be in futex_wait between dispatches, so `dispatch` can't use spin-wake. The spin optimization is on the Haskell wait side only. `prepare`/`run` use spin-wake after the first successful futex-waked run.
- **`dispatch` requires memfd capability** — `ProcessVmWritevOnly` config errors on `dispatch`. Use `SharedMemfdOnly` or `BothMethods` (default).
- **No worker respawn yet** — crashed workers are marked dead, not replaced (Phase 2)
- **No PID namespace yet** — fork server runs without CLONE_NEWPID (Phase 3)
