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

### CURRENT BLOCKER: Dispatch hang

**Symptom**: Fork server starts, worker spawns, but dispatched code never completes. Fork server polls `futex_wait(notify, 0, 100ms timeout)` + `kill(pid, 0)` in a loop — worker is alive but stuck.

**What works**: Fork server binary runs (no more segfault). Worker process spawns. `nix build .#hatchery` compiles the library.

**What doesn't work**: Worker never sets ring buffer status to WORKER_DONE after code dispatch. Happens with and without seccomp.

**Debugging done**:
- Confirmed via strace: fork server enters dispatch, writes code via process_vm_writev, wakes worker futex, then polls notify futex — worker never wakes/completes
- The earlier test (`cabal test hatchery-test`) was passing before the flake restructuring (commit `56568a6`). The flake changed from `mkShell` to `shellFor` around `83e3ec3`.
- Both `-static-pie` and `-static -no-pie` produce working binaries (post stack-protector fix) that start and enter epoll loop, but dispatch coordination fails

**Likely cause**: The worker's futex wait/wake or code execution path has an issue. Possibly:
- Worker never receives the futex wake (futex address mismatch between fork server and worker?)
- Worker wakes but crashes during code execution (seccomp or code region issue)
- Ring buffer mmap not shared correctly between fork server and worker

**Next step**: Add `sys_write(2, ...)` debug prints to worker_main in fork_server.c to trace exactly where the worker gets stuck (before/after futex_wait, before/after code execution).

### Known issues
- **No PID namespace isolation**: Phase 3 task.
- **4096-byte code buffer in fork_server.c**: Caps injected code size. Phase 2.
- **No worker respawn**: Crashed workers not replaced. Phase 2.
- **Benchmark not yet run**: Blocked by dispatch hang.
- **README latency claims**: "~3-5μs" is from design estimate, not measured.
