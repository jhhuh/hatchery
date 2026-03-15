# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

Phase 1 complete. Core sandbox works end-to-end (spawn → dispatch → result → crash detection). LLVM integration stubbed (llvm-ffi build issue). See `artifacts/devlog.md` for history.

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
GHC Process → socketpair/pipe → Fork Server (static-PIE C, embedded in binary)
                                   ├─► Worker 0 (futex-suspended, seccomp-filtered)
                                   ├─► Worker 1
                                   └─► ...
```

- **Fork server** (`cbits/fork_server.c`): Pure C, static-PIE ELF (musl), no libc, raw syscalls (`syscall.h`). Single-threaded epoll loop. Spawns workers via `fork()`. Entry point: `_start` (naked) → `real_start` (parses argc/argv for fd numbers and config).
- **Workers**: Own address space, PROT_RWX code region, MAP_SHARED ring buffer (memfd), seccomp filter. Execute injected machine code as `int fn(void)`.
- **Communication**: socketpair for commands (`protocol.h` structs, 16-byte command / 20-byte response), ring buffer for data + synchronization. Futex for worker wake/notify.
- **Lifecycle**: Parent death → pipe EOF → fork server exits. Worker crash detected via pidfd + `kill(pid, 0)` liveness check.
- **Haskell spawn path**: `Core.withHatchery` → `Vfork.spawnForkServer` (FFI to `vfork_helper.c`) → `execveat` of the embedded ELF via memfd.

### Wire protocol

Command/response are fixed-size C structs sent over the socketpair. Code bytes follow `CMD_DISPATCH` inline. `Hatchery.Internal.Protocol` must match `protocol.h` exactly (enum values, struct layouts, field offsets). The Haskell side uses manual `Ptr` arithmetic, not `Storable` instances for the protocol structs.

## Dual Injection Methods

Pool config (`InjectionCapability`) determines worker code region setup:
- `ProcessVmWritevOnly` — MAP_PRIVATE|MAP_ANONYMOUS code region
- `SharedMemfdOnly` — MAP_SHARED from memfd
- `BothMethods` — MAP_SHARED from memfd, either method per-dispatch

Per-dispatch `InjectionMethod`: `UseProcessVmWritev | UseSharedMemfd`. Mismatch → error.

## Key Gotchas

- **`$HATCHERY_CC` must be set** — TH compilation fails without it. The nix flake sets it automatically.
- **PR_SET_DUMPABLE=0 blocks process_vm_writev** — intentionally omitted from workers
- **`withHatchery` requires bound thread** — use `-threaded` GHC flag, call from main or `forkOS`
- **4096-byte code buffer in fork_server.c** — limits injected code size (Phase 1 limitation)
- **`-fno-stack-protector` required** — GCC 15 enables stack protector by default, but `-nostartfiles` binary has no TLS → segfault on `%fs:0x28` access
- **`_start` must be `naked`** — GCC 15 adds prologue that corrupts RSP before inline asm can capture it
- **No worker respawn yet** — crashed workers are marked dead, not replaced (Phase 2)
- **No PID namespace yet** — fork server runs without CLONE_NEWPID (Phase 3)
