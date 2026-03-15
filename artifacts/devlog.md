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
hatchery/          Core sandbox (working, tested)
hatchery-llvm/     LLVM bridge (stub — llvm-ffi build issue, see below)
trustless-ffi/     User API (working, wraps hatchery)
```

### Implementation completed
- C layer: syscall.h, ring_buffer.h, protocol.h, fork_server.c (584 lines), seccomp_filter.c, Makefile
- Haskell layer: all 8 modules compile (Config, Core, Dispatch, Internal.{Memfd,Vfork,Protocol,Embedded}, re-exports)
- Integration test: return42 payload dispatched via both injection methods, passes
- Nix flake: GHC 9.10.3, musl cross-compiler, LLVM 18, nasm, cabal

### Bugs found and fixed
1. **`PR_SET_DUMPABLE=0` blocks `process_vm_writev`**: Even same-UID processes can't use `process_vm_writev` on a non-dumpable target. Removed from worker setup; seccomp is the primary sandbox.
2. **Dispatch deadlock on worker crash**: Fork server's `handle_dispatch` used indefinite `futex_wait` on notify word. If worker crashed, nobody woke the futex → deadlock. Fixed with 100ms futex timeout + `kill(pid, 0)` liveness check.
3. **syscall.h futex signature**: Used `int *` but ring_buffer.h passes `uint32_t *`. Fixed to `uint32_t *` and added `#include <stdint.h>`.
4. **GHC 9.10 `BSI.withForeignPtr`**: Moved to `Foreign.ForeignPtr` in newer GHC. Fixed import.

### Known issues
- **llvm-ffi build failure**: `llvm-ffi` (transitive dep of `llvm-tf`) fails against LLVM 18 — `LLVMGEPNoWrapFlags` undeclared. Both `hatchery-llvm` and `trustless-ffi` have `llvm-tf` dependency temporarily commented out. Options: use LLVM 17, patch llvm-ffi, or call LLVM C API directly.
- **No PID namespace isolation yet**: Phase 1 fork server is spawned with regular `vfork+execveat`, not `clone3(CLONE_NEWPID)`. Phase 3 task.
- **4096-byte code buffer in fork_server.c**: `handle_dispatch` uses stack-allocated buffer, caps code size. Needs dynamic allocation or mmap for larger payloads.
- **No worker respawn**: When a worker crashes, it's marked dead but not respawned. Phase 2 task.
