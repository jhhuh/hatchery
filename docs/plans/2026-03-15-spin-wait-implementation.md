# Spin-Wait Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add hybrid spin-then-futex dispatch for pre-loaded workers, targeting sub-microsecond latency on fast workloads.

**Architecture:** Worker spins N iterations on `control` then falls back to futex. Haskell side does the same via inline-cmm Cmm spin + safe FFI futex outer loop. Fork server monitors reserved workers for crash detection.

**Tech Stack:** C (fork_server.c), GHC Cmm via inline-cmm, Haskell FFI

---

### Task 1: Add `WaitStrategy` to Config

**Files:**
- Modify: `hatchery/src/Hatchery/Config.hs`

**Step 1: Add the WaitStrategy type and config field**

```haskell
-- Add after InjectionMethod definition:

-- | Wait strategy for pre-loaded worker dispatch.
data WaitStrategy
  = FutexWait           -- ^ Pure futex wake/wait (current behavior, default)
  | SpinWait !Word32    -- ^ Spin N iterations, then fall back to futex
  deriving (Show, Eq)
```

Add to `HatcheryConfig`:

```haskell
data HatcheryConfig = HatcheryConfig
  { poolSize            :: !Int
  , codeRegionSize      :: !Word
  , ringBufSize         :: !Word
  , injectionCapability :: !InjectionCapability
  , dispatchTimeout     :: !(Maybe Double)
  , waitStrategy        :: !WaitStrategy         -- NEW
  } deriving (Show, Eq)
```

Add to `defaultConfig`:

```haskell
defaultConfig = HatcheryConfig
  { ...
  , waitStrategy        = FutexWait
  }
```

Export `WaitStrategy(..)` from `Hatchery.Config` and re-export from `Hatchery`.

**Step 2: Add `import Data.Word (Word32)` if not already imported**

**Step 3: Build to verify**

Run: `nix build .#hatchery`
Expected: compilation errors in downstream modules that pattern-match on `HatcheryConfig` — that's expected, we fix those next.

**Step 4: Fix downstream pattern matches**

Any module that constructs or destructures `HatcheryConfig` needs the new field. Check `Core.hs` — `withHatchery` passes config to `spawnForkServer`, no pattern match issue there. The bench constructs configs with `defaultConfig { ... }` — record update syntax, no breakage.

Run: `nix build .#hatchery`
Expected: PASS

**Step 5: Commit**

```bash
git add hatchery/src/Hatchery/Config.hs hatchery/src/Hatchery.hs
git commit -m "feat: add WaitStrategy type to HatcheryConfig"
```

---

### Task 2: Pass spin_count to fork server via argv

**Files:**
- Modify: `hatchery/cbits/vfork_helper.c:62-155` (spawn_fork_server)
- Modify: `hatchery/cbits/fork_server.c:697-722` (real_start, argv parsing)
- Modify: `hatchery/src/Hatchery/Internal/Vfork.hs` (add spin_count param)
- Modify: `hatchery/src/Hatchery/Core.hs:43-55` (pass spin_count to spawnForkServer)

**Step 1: Add argv[7] = spin_count to vfork_helper.c**

In `spawn_fork_server`, add a new parameter `unsigned int spin_count` and pass it as `argv[7]`:

```c
int spawn_fork_server(
    const unsigned char *elf_data,
    unsigned int elf_size,
    int pool_size,
    int injection_cap,
    unsigned long code_region_size,
    unsigned long ring_buf_size,
    unsigned int spin_count,           // NEW
    struct spawn_result *out)
{
    ...
    char arg7[16];                     // NEW
    snprintf(arg7, sizeof(arg7), "%u", spin_count);  // NEW

    char *argv[] = { arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7, NULL };  // add arg7
    ...
}
```

**Step 2: Parse argv[7] in fork_server.c real_start**

```c
static unsigned int spin_count;  // new global, after ring_buf_size

__attribute__((noreturn, used)) void real_start(unsigned long *sp)
{
    int argc = (int)sp[0];
    char **argv = (char **)(sp + 1);

    if (argc < 8)          // was 7
        sys_exit_group(1);

    sock_fd          = simple_atoi(argv[1]);
    pipe_fd          = simple_atoi(argv[2]);
    pool_size        = simple_atoi(argv[3]);
    injection_cap    = simple_atoi(argv[4]);
    code_region_size = (unsigned long)simple_atoi(argv[5]);
    ring_buf_size    = (unsigned long)simple_atoi(argv[6]);
    spin_count       = (unsigned int)simple_atoi(argv[7]);  // NEW
    ...
}
```

**Step 3: Update Haskell FFI binding in Vfork.hs**

Add `CUInt` parameter to `c_spawn_fork_server` and `spawnForkServer`:

```haskell
foreign import ccall "spawn_fork_server"
  c_spawn_fork_server
    :: Ptr Word8 -> CUInt -> CInt -> CInt -> CULong -> CULong
    -> CUInt             -- spin_count (NEW)
    -> Ptr SpawnResult -> IO CInt

spawnForkServer :: ByteString -> Int -> Int -> Word -> Word
               -> Word32        -- spin_count (NEW)
               -> IO SpawnResult
spawnForkServer elf poolSz injCap crSize rbSize spinCount =
  BSU.unsafeUseAsCStringLen elf $ \(ptr, len) ->
    alloca $ \outPtr -> do
      ret <- c_spawn_fork_server
        (castPtr ptr) (fromIntegral len)
        (fromIntegral poolSz) (fromIntegral injCap)
        (fromIntegral crSize) (fromIntegral rbSize)
        (fromIntegral spinCount)   -- NEW
        outPtr
      ...
```

**Step 4: Pass spin_count from Core.hs**

In `withHatchery`, extract spin count from config and pass to `spawnForkServer`:

```haskell
    acquire = do
      let sc = case waitStrategy cfg of
                 FutexWait    -> 0
                 SpinWait n   -> n
      sr <- spawnForkServer
        forkServerELF
        (poolSize cfg)
        (injCapToInt (injectionCapability cfg))
        (codeRegionSize cfg)
        (ringBufSize cfg)
        sc                    -- NEW
      ...
```

Add `import Data.Word (Word32)` and import `WaitStrategy(..)` from `Hatchery.Config`.

**Step 5: Build to verify**

Run: `nix build .#hatchery`
Expected: PASS (spin_count flows through but isn't used in worker_main yet)

**Step 6: Commit**

```bash
git add hatchery/cbits/vfork_helper.c hatchery/cbits/fork_server.c \
        hatchery/src/Hatchery/Internal/Vfork.hs hatchery/src/Hatchery/Core.hs
git commit -m "feat: pass spin_count from HatcheryConfig through to fork server"
```

---

### Task 3: Worker-side hybrid spin loop

**Files:**
- Modify: `hatchery/cbits/fork_server.c:178-212` (worker_main loop)

**Step 1: Add spin loop before futex in worker_main**

Replace the worker loop (lines 179-212) with:

```c
    /* Worker loop */
    for (;;) {
        /* Phase 1: spin */
        unsigned int spins = spin_count;  /* global from argv[7] */
        for (unsigned int i = 0; i < spins; i++) {
            uint32_t ctl = atomic_load_explicit(&ring->control,
                                                 memory_order_acquire);
            if (ctl == WORKER_RUN) goto run;
            if (ctl == WORKER_STOP) sys_exit_group(0);
            __builtin_ia32_pause();
        }

        /* Phase 2: futex fallback */
        {
            uint32_t ctl = atomic_load_explicit(&ring->control,
                                                 memory_order_acquire);
            if (ctl == WORKER_IDLE) {
                futex_wait(&ring->control, WORKER_IDLE);
                continue;
            }
            if (ctl == WORKER_STOP)
                sys_exit_group(0);
        }

    run:
        /* ctl == WORKER_RUN */
        atomic_store_explicit(&ring->status, WORKER_BUSY,
                              memory_order_release);

        /* Execute code at code_base */
        typedef int (*code_fn)(void);
        code_fn fn = (code_fn)code_base;
        int result = fn();

        /* Write result */
        ring->exit_code = (int32_t)result;
        ring->result_offset = 0;
        ring->result_size = 0;

        /* Reset control and set status to DONE */
        atomic_store_explicit(&ring->control, WORKER_IDLE,
                              memory_order_release);
        atomic_store_explicit(&ring->status, WORKER_DONE,
                              memory_order_release);

        /* Wake parent */
        atomic_store_explicit(&ring->notify, 1, memory_order_release);
        futex_wake(&ring->notify, 1);
    }
```

When `spin_count == 0` (FutexWait), the spin loop body never executes — falls straight through to futex. Backwards compatible.

**Step 2: Build to verify**

Run: `nix build .#hatchery`
Expected: PASS

**Step 3: Commit**

```bash
git add hatchery/cbits/fork_server.c
git commit -m "feat: hybrid spin-then-futex loop in worker_main"
```

---

### Task 4: Fork server crash detection for reserved workers

**Files:**
- Modify: `hatchery/cbits/fork_server.c:479-517` (handle_reserve)
- Modify: `hatchery/cbits/fork_server.c:558-580` (handle_worker_death)

**Step 1: Keep pidfd in epoll for reserved workers**

In `handle_reserve` (line 504-506), remove the `EPOLL_CTL_DEL` call:

```c
    /* OLD: Remove worker's pidfd from epoll — Haskell owns crash detection now */
    /* if (workers[idx].pidfd >= 0)
        sys_epoll_ctl(epfd, 2, workers[idx].pidfd, 0); */

    /* NEW: Keep pidfd in epoll — fork server writes CRASHED to ring on death */
```

**Step 2: Update handle_worker_death to handle reserved workers**

Currently `handle_worker_death` sends `RSP_WORKER_CRASHED` over the socketpair. For reserved workers, we should NOT send this response (Haskell isn't listening for it on reserved workers). Instead, just write `CRASHED` to the ring buffer and wake the futex:

```c
static void handle_worker_death(int pidfd)
{
    for (int i = 0; i < pool_size; i++) {
        if (workers[i].pidfd == pidfd) {
            /* Write CRASHED to ring buffer (Haskell spin loop sees this) */
            atomic_store_explicit(&workers[i].ring->status,
                                  WORKER_CRASHED, memory_order_release);
            /* Wake Haskell if in futex fallback */
            futex_wake(&workers[i].ring->notify, 1);

            /* Only send socketpair response for non-reserved workers */
            if (!workers[i].reserved) {
                struct response rsp;
                simple_memset(&rsp, 0, sizeof(rsp));
                rsp.type = RSP_WORKER_CRASHED;
                rsp.worker_crashed.worker_id = (uint32_t)i;
                rsp.worker_crashed.signal = SIGKILL;
                send_response(&rsp);
            }

            sys_close(workers[i].pidfd);
            workers[i].pidfd = -1;
            workers[i].pid = 0;
            workers[i].busy = 0;
            return;
        }
    }
}
```

**Step 3: Update handle_release to NOT re-add pidfd (it's already there)**

In `handle_release` (lines 528-534), the pidfd is already in epoll, so remove the `EPOLL_CTL_ADD`:

```c
static void handle_release(const struct command *cmd)
{
    int idx = (int)cmd->reserve_release.worker_id;
    if (idx >= 0 && idx < pool_size) {
        workers[idx].reserved = 0;
        /* pidfd already in epoll — no need to re-add */
    }
}
```

**Step 4: Build to verify**

Run: `nix build .#hatchery`
Expected: PASS

**Step 5: Commit**

```bash
git add hatchery/cbits/fork_server.c
git commit -m "feat: fork server monitors reserved workers, writes CRASHED to ring"
```

---

### Task 5: Haskell-side Cmm spin loop via inline-cmm

**Files:**
- Modify: `hatchery/hatchery.cabal` (add inline-cmm dependency)
- Create: `hatchery/src/Hatchery/Internal/SpinWait.hs`
- Modify: `hatchery/src/Hatchery/Dispatch.hs:187-202` (run function)

**Step 1: Add inline-cmm to hatchery.cabal**

In the `library` section `build-depends`, add `inline-cmm`:

```cabal
  build-depends:
    base >= 4.16 && < 5,
    bytestring,
    async,
    unix,
    template-haskell,
    process,
    directory,
    inline-cmm
```

**Step 2: Create Hatchery.Internal.SpinWait module**

```haskell
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE UnliftedFFITypes #-}

module Hatchery.Internal.SpinWait
  ( spinWait
  ) where

import GHC.Exts (Int#, Word#, Addr#, addr2Int#, int2Addr#, plusAddr#,
                 word2Int#, int2Word#)
import GHC.Word (Word32(..))
import GHC.Int (Int32(..))
import Foreign.Ptr (Ptr, ptrToWordPtr, wordPtrToPtr)
import Foreign.C.Types (CInt(..))
import Data.Bits ((.&.))
import Language.Haskell.Inline.Cmm

-- Ring buffer offsets (must match ring_buffer.h / direct_helpers.c)
-- control: offset 0     (cache line 0)
-- notify:  offset 64    (cache line 1)
-- status:  offset 128   (cache line 2)
-- exit_code: offset 216

include "\"Cmm.h\""

[cmm|
W64 hatchery_spin_wait(W64 ring_base, W64 spin_count) {
    W64 status_addr;
    W64 i;
    W32 st;

    status_addr = ring_base + 128;

    i = 0;
again:
    if (i >= spin_count) goto exhausted;

    st = %acquire W32[status_addr];
    if (st == 3) goto done;     /* WORKER_DONE = 3 */
    if (st == 4) goto crashed;  /* WORKER_CRASHED = 4 */

    i = i + 1;
    goto again;

done:
    W64 ec;
    ec = %relaxed W32[ring_base + 216];     /* exit_code */

    /* Reset notify and status for next run */
    %release W32[ring_base + 64] = 0;       /* notify = 0 */
    %release W32[status_addr] = 1;          /* status = WORKER_READY */

    return (0, ec);

crashed:
    return (1, 0);

exhausted:
    return (2, 0);
}
|]

-- | Spin on ring buffer status. Returns:
--   (0, exit_code) — worker completed
--   (1, _)         — worker crashed
--   (2, _)         — spins exhausted, caller should futex-wait and retry
spinWait :: Ptr () -> Word32 -> (Int, Int32)
spinWait ringPtr spinCount =
    let addr = fromIntegral (ptrToWordPtr ringPtr)
        sc   = fromIntegral spinCount
        !(# tag, ec #) = hatchery_spin_wait#
                            (int2Addr# (word2Int# (int2Word# (case addr of I64# i -> i))))
                            (int2Word# (case sc of I64# i -> i))
    in (I# (word2Int# tag), fromIntegral (I# (word2Int# ec)))
```

Note: The exact unboxing may need adjustment depending on how inline-cmm maps `W64` return values. The key structure is right — we'll refine during build.

**Step 3: Add SpinWait to other-modules in cabal**

```cabal
  other-modules:
    Hatchery.Internal.Compile
    Hatchery.Internal.Memfd
    Hatchery.Internal.Vfork
    Hatchery.Internal.Protocol
    Hatchery.Internal.Embedded
    Hatchery.Internal.SpinWait
```

**Step 4: Build to verify the Cmm compiles**

Run: `nix build .#hatchery`
Expected: PASS (module compiles but isn't called yet)

**Step 5: Commit**

```bash
git add hatchery/hatchery.cabal hatchery/src/Hatchery/Internal/SpinWait.hs
git commit -m "feat: add Cmm spin-wait function via inline-cmm"
```

---

### Task 6: Wire spin-wait into `run`

**Files:**
- Modify: `hatchery/src/Hatchery/Dispatch.hs`
- Modify: `hatchery/cbits/direct_helpers.c` (add safe futex wait helper)

**Step 1: Add safe FFI futex wait helper in direct_helpers.c**

```c
/* Safe FFI version: releases GHC capability during wait.
 * Waits on ring->notify with 100ms timeout. */
int hatchery_futex_wait_safe(void *ring_base)
{
    uint32_t *notify = (uint32_t *)((char *)ring_base + RING_NOTIFY_OFF);
    uint32_t nv = __atomic_load_n(notify, __ATOMIC_ACQUIRE);
    if (nv == 0) {
        struct timespec ts = { 0, 100000000L };
        syscall(__NR_futex, notify, FUTEX_WAIT, 0, &ts, NULL, 0);
    }
    return 0;
}
```

**Step 2: Add safe FFI import in Dispatch.hs**

```haskell
foreign import ccall safe "hatchery_futex_wait_safe"
  c_futex_wait_safe :: Ptr () -> IO CInt
```

**Step 3: Modify `run` to use spin-wait when configured**

```haskell
import Hatchery.Config (InjectionCapability(..), InjectionMethod(..),
                        HatcheryConfig(..), WaitStrategy(..))
import Hatchery.Internal.SpinWait (spinWait)

-- | Re-run pre-loaded code on a prepared worker.
run :: PreparedWorker -> IO DispatchResult
run pw = do
  c_wake_worker (pwRingPtr pw)
  case waitStrategy (hConfig (pwHatchery pw)) of
    FutexWait  -> runFutex pw
    SpinWait n -> runSpin pw n

-- | Original futex-based wait (unchanged logic).
runFutex :: PreparedWorker -> IO DispatchResult
runFutex pw =
  alloca $ \ecPtr -> do
    ret <- c_wait_worker (pwRingPtr pw) (fromIntegral (pwWorkerPid pw)) ecPtr
    if ret == 0
      then do
        ec <- peek ecPtr
        rsz <- c_result_size (pwRingPtr pw)
        if rsz > 0
          then do
            dataPtr <- c_result_data (pwRingPtr pw)
            bs <- BS.packCStringLen (castPtr dataPtr, fromIntegral rsz)
            return $ Completed ec (Just bs)
          else return $ Completed ec Nothing
      else return $ Crashed 0

-- | Spin-wait with futex fallback.
runSpin :: PreparedWorker -> Word32 -> IO DispatchResult
runSpin pw n = go
  where
    go = case spinWait (pwRingPtr pw) n of
      (0, ec) -> do
        rsz <- c_result_size (pwRingPtr pw)
        if rsz > 0
          then do
            dataPtr <- c_result_data (pwRingPtr pw)
            bs <- BS.packCStringLen (castPtr dataPtr, fromIntegral rsz)
            return $ Completed ec (Just bs)
          else return $ Completed ec Nothing
      (1, _) -> return $ Crashed 0
      _      -> do
        -- Spins exhausted: futex wait (safe FFI, releases capability)
        _ <- c_futex_wait_safe (pwRingPtr pw)
        go
```

**Step 4: Add import for `Word32`**

```haskell
import Data.Word (Word32)
```

**Step 5: Build to verify**

Run: `nix build .#hatchery`
Expected: PASS

**Step 6: Commit**

```bash
git add hatchery/src/Hatchery/Dispatch.hs hatchery/cbits/direct_helpers.c
git commit -m "feat: wire spin-wait into PreparedWorker.run with futex fallback"
```

---

### Task 7: Benchmark spin-wait mode

**Files:**
- Modify: `hatchery-bench/src/Main.hs`

**Step 1: Add spin-wait benchmarks**

After the existing pre-loaded benchmark, add:

```haskell
  -- Spin-wait pre-loaded payload
  let spinCfg = defaultConfig { poolSize = 2, waitStrategy = SpinWait 10000 }
  withHatchery spinCfg $ \h -> do
    withPrepared h UseSharedMemfd payload $ \pw -> do
      -- warmup
      mapM_ (\_ -> run pw) [1..10 :: Int]

      avgSpin <- timeN hn (run pw)
      printf "  hatchery (spin-wait): %7.2f us/call  (%d calls)\n" avgSpin hn
```

Add `import Hatchery.Config (WaitStrategy(..))` (or it may already be re-exported from `Hatchery`).

**Step 2: Build and run benchmark**

Run: `nix build .#hatchery-bench`
Then run the benchmark binary manually outside nix sandbox.

**Step 3: Commit**

```bash
git add hatchery-bench/src/Main.hs
git commit -m "bench: add spin-wait mode to latency benchmark"
```

---

### Task 8: Update devlog and docs

**Files:**
- Modify: `artifacts/devlog.md` (append new session entry)
- Modify: `PLAN.md` (update status table, latency reference)
- Modify: `CLAUDE.md` (if needed)

**Step 1: Append devlog entry with results**

Include: what was implemented, measured latency numbers, any issues found.

**Step 2: Update PLAN.md status**

Mark spin-wait as done in the Phase 2 table. Update latency reference with measured numbers.

**Step 3: Commit**

```bash
git add artifacts/devlog.md PLAN.md
git commit -m "docs: update devlog and plan with spin-wait implementation results"
```
