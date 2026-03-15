# Hatchery Phase 1 Design — Resolved Decisions

Date: 2026-03-15
Status: Approved
Base document: `PLAN.md`

## Resolved Open Questions

### Code Injection: Both Methods

Pool-level config determines capability:

```haskell
data InjectionCapability
  = ProcessVmWritevOnly  -- code region: MAP_PRIVATE|MAP_ANONYMOUS
  | SharedMemfdOnly      -- code region: MAP_SHARED from memfd
  | BothMethods          -- code region: MAP_SHARED from memfd, either method per-dispatch
```

Per-dispatch, caller selects injection method. Mismatch with pool capability → error (no silent fallback).

**Worker setup implications:**
- `ProcessVmWritevOnly`: no memfd per worker for code region, lighter setup
- `SharedMemfdOnly` / `BothMethods`: memfd-backed MAP_SHARED code region. Both `process_vm_writev` and direct memfd writes work on the same mapping.

### Single Fork Server ELF

Fork server `fork()`s itself for workers. No separate worker binary. Workers diverge into `worker_main()` after fork.

### Raw Machine Code

Dispatched code is raw machine code at a known base address. No ELF loading, no relocation.

### LLVM Runtime Codegen

- **`hatchery-llvm`** — bridge package, depends on `hatchery` + `llvm-tf` (v16.0). Handles LLVM IR → machine code compilation, manages LLVM context/module lifecycle. No user-facing API here.
- **`trustless-ffi`** — re-exports a JIT API from `hatchery-llvm`. Users build LLVM IR via `llvm-tf`, dispatch it like any other call.
- `llvm-tf` 16.0 requires LLVM 16 C libraries (`llvmPackages_16` in nixpkgs).

### Package Dependency Graph

```
hatchery          (core sandbox, no LLVM dep)
├── hatchery-llvm (bridge: hatchery + llvm-tf)
└── trustless-ffi (user API: depends on hatchery + hatchery-llvm)
```

## Phase 1 Scope

Minimal viable path: Haskell spawns fork server, fork server spawns one worker, Haskell dispatches code, gets result. Both injection methods functional.

Build order (bottom-up):
1. `syscall.h` — raw syscall wrappers
2. `ring_buffer.h` — shared struct, futex helpers
3. `protocol.h` — command/response wire format
4. `fork_server.c` — _start, fork worker, epoll loop, dispatch handler
5. `seccomp_filter.c` — BPF filter
6. `cbits/Makefile` — musl-gcc static-PIE build
7. `vfork_helper.c` — C helper for Haskell to spawn fork server
8. `Hatchery.Internal.Memfd` — memfd_create FFI
9. `Hatchery.Internal.Vfork` — vfork+execveat wrapper
10. `Hatchery.Internal.Protocol` — command/response serialization
11. `Hatchery.Internal.Embedded` — file-embed fork server ELF
12. `Hatchery.Config` — HatcheryConfig with InjectionCapability
13. `Hatchery.Core` — withHatchery
14. `Hatchery.Dispatch` — dispatch (synchronous, single worker, both injection methods)
15. `Hatchery` — re-export module
16. Nix flake — musl-gcc, cabal, haskell deps
17. Test: dispatch `return 42` payload, verify result
