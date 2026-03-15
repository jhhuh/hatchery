# Direct Dispatch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `dispatch` bypass the fork server entirely — Haskell writes code to mmap'd memfd and wakes workers directly, cutting one-shot latency from ~5500ns to ~500ns (spin) / ~3200ns (futex).

**Architecture:** At `withHatchery` startup, reserve all workers via `CMD_RESERVE`, duplicate their fds via `pidfd_getfd`, mmap ring buffers and code regions. Maintain idle worker set as `MVar [WorkerId]`. `dispatch` = take idle worker → memcpy code → wake → wait → return to idle. Fork server becomes lifecycle-only (spawn, crash detect, shutdown).

**Tech Stack:** Haskell (GHC 9.10), C (GHC-compiled, not musl), inline-cmm, futex, memfd, pidfd_getfd

---

### Task 1: Add `hatchery_write_code` to direct_helpers.c

**Files:**
- Modify: `hatchery/cbits/direct_helpers.c`

**Step 1: Add the C helper**

Add at end of `direct_helpers.c`:

```c
/* Write code bytes to mmap'd code memfd.
 * code_ptr: mmap'd base of code memfd
 * src: code bytes
 * len: byte count
 * Also updates code_len in the ring buffer. */
void hatchery_write_code(void *ring_base, void *code_ptr, const void *src, uint32_t len)
{
    __builtin_memcpy(code_ptr, src, len);
    uint32_t *cl = (uint32_t *)((char *)ring_base + offsetof(struct ring_buffer, code_len));
    *cl = len;
}
```

**Step 2: Verify build**

Run: `nix build .#hatchery 2>&1 | tail -20`
Expected: builds successfully (no test changes yet)

**Step 3: Commit**

```bash
git add hatchery/cbits/direct_helpers.c
git commit -m "feat: add hatchery_write_code C helper for direct memfd writes"
```

---

### Task 2: Add `hatchery_mmap_code` to direct_helpers.c

The code memfd needs to be mmap'd as PROT_READ|PROT_WRITE (Haskell writes code) from the Haskell side. Existing `hatchery_mmap_ring` uses PROT_READ|PROT_WRITE + MAP_SHARED which works, but the code region needs to be a separate mmap.

**Files:**
- Modify: `hatchery/cbits/direct_helpers.c`

**Step 1: Add the C helper**

```c
/* mmap code memfd for direct writes from Haskell */
void *hatchery_mmap_code(int fd, unsigned long size)
{
    return mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
}
```

**Step 2: Verify build**

Run: `nix build .#hatchery 2>&1 | tail -20`
Expected: builds successfully

**Step 3: Commit**

```bash
git add hatchery/cbits/direct_helpers.c
git commit -m "feat: add hatchery_mmap_code C helper for code memfd mapping"
```

---

### Task 3: Extend `Hatchery` record and `Core.hs` — reserve all workers at startup

**Files:**
- Modify: `hatchery/src/Hatchery/Core.hs`

**Step 1: Add imports and extend `Hatchery` record**

Add to imports:

```haskell
import Control.Concurrent.MVar
import Data.Word (Word32)
import Foreign.Ptr
import Foreign.C.Types
import Data.IORef
```

Extend `Hatchery`:

```haskell
data Hatchery = Hatchery
  { hSockFd      :: !Fd
  , hLivenessFd  :: !Fd
  , hConfig      :: !HatcheryConfig
  , hPid         :: !Int
  , hIdleWorkers :: !(MVar [Word32])           -- idle worker IDs
  , hWorkerInfo  :: !(IORef [WorkerMapping])    -- per-worker mmap'd state
  }

data WorkerMapping = WorkerMapping
  { wmWorkerId  :: !Word32
  , wmRingPtr   :: !(Ptr ())    -- mmap'd ring buffer
  , wmCodePtr   :: !(Ptr ())    -- mmap'd code memfd
  , wmRingFd    :: !CInt        -- local fd for ring memfd
  , wmCodeFd    :: !CInt        -- local fd for code memfd
  , wmWorkerPid :: !Int
  }
```

**Step 2: Add FFI imports** (reuse from Dispatch.hs — these will be shared)

```haskell
foreign import ccall "hatchery_pidfd_open"
  c_pidfd_open :: CInt -> IO CInt
foreign import ccall "hatchery_pidfd_getfd"
  c_pidfd_getfd :: CInt -> CInt -> IO CInt
foreign import ccall "hatchery_mmap_ring"
  c_mmap_ring :: CInt -> CULong -> IO (Ptr ())
foreign import ccall "hatchery_mmap_code"
  c_mmap_code :: CInt -> CULong -> IO (Ptr ())
foreign import ccall "hatchery_munmap_ring"
  c_munmap_ring :: Ptr () -> CULong -> IO CInt
foreign import ccall "hatchery_set_spin_mode"
  c_set_spin_mode :: Ptr () -> Word32 -> IO ()
foreign import ccall "close"
  c_close :: CInt -> IO CInt
```

**Step 3: Implement `reserveAllWorkers`**

After `waitForWorkers`, reserve all N workers and mmap their buffers:

```haskell
reserveAllWorkers :: Hatchery -> IO [WorkerMapping]
reserveAllWorkers h = do
  let n = poolSize (hConfig h)
  fsPidfd <- c_pidfd_open (fromIntegral (hPid h))
  when (fsPidfd < 0) $ ioError (userError "reserveAllWorkers: pidfd_open failed")
  mappings <- mapM (\_ -> reserveOne h fsPidfd) [1..n]
  _ <- c_close fsPidfd
  return mappings

reserveOne :: Hatchery -> CInt -> IO WorkerMapping
reserveOne h fsPidfd = do
  sendCommand (hSockFd h) (CmdReserve maxBound)
  rsp <- recvResponse (hSockFd h)
  (wid, remoteRingFd, remoteCodeFd, workerPid) <- case rsp of
    RspWorkerReserved wid rfd cfd wpid -> return (wid, rfd, cfd, wpid)
    RspError code -> if code == -1
      then throwIO NoAvailableWorker
      else throwIO HatcheryDead
    _ -> ioError (userError "reserveOne: unexpected response")

  -- Duplicate fds
  localRingFd <- c_pidfd_getfd fsPidfd (fromIntegral remoteRingFd)
  when (localRingFd < 0) $ ioError (userError "reserveOne: pidfd_getfd ring_fd failed")
  localCodeFd <- if remoteCodeFd >= 0
    then do fd <- c_pidfd_getfd fsPidfd (fromIntegral remoteCodeFd)
            when (fd < 0) $ ioError (userError "reserveOne: pidfd_getfd code_fd failed")
            return fd
    else return (-1)

  -- mmap ring buffer and code region
  let rbSize = ringBufSize (hConfig h)
      codeSize = codeRegionSize (hConfig h)
  ringPtr <- c_mmap_ring localRingFd (fromIntegral rbSize)
  when (ringPtr == nullPtr `plusPtr` (-1)) $ ioError (userError "reserveOne: mmap ring failed")
  codePtr <- if localCodeFd >= 0
    then do p <- c_mmap_code localCodeFd (fromIntegral codeSize)
            when (p == nullPtr `plusPtr` (-1)) $ ioError (userError "reserveOne: mmap code failed")
            return p
    else return nullPtr

  -- Enable spin_mode if configured
  case waitStrategy (hConfig h) of
    SpinWait _  -> c_set_spin_mode ringPtr 1
    SpinWaitC _ -> c_set_spin_mode ringPtr 1
    _           -> return ()

  return WorkerMapping
    { wmWorkerId  = wid
    , wmRingPtr   = ringPtr
    , wmCodePtr   = codePtr
    , wmRingFd    = localRingFd
    , wmCodeFd    = localCodeFd
    , wmWorkerPid = fromIntegral workerPid
    }
```

**Step 4: Wire into `withHatchery`**

Update `acquire` to create the MVar and IORef. Update the bracket flow:

```haskell
withHatchery cfg action = inBoundThread $
  bracket acquire release $ \h -> do
    waitForWorkers h
    mappings <- reserveAllWorkers h
    writeIORef (hWorkerInfo h) mappings
    putMVar (hIdleWorkers h) (map wmWorkerId mappings)
    action h
```

Update `acquire` to initialize empty MVar and IORef:

```haskell
acquire = do
  ...
  idle <- newEmptyMVar
  info <- newIORef []
  return $ Hatchery { ..., hIdleWorkers = idle, hWorkerInfo = info }
```

Update `release` to munmap and release all workers:

```haskell
release h = do
  mappings <- readIORef (hWorkerInfo h)
  mapM_ releaseMapping mappings
  sendCommand (hSockFd h) CmdShutdown `catch` \(_ :: SomeException) -> return ()
  closeFd (hSockFd h)
  closeFd (hLivenessFd h)

releaseMapping :: WorkerMapping -> IO ()
releaseMapping wm = do
  -- don't need CMD_RELEASE since we're shutting down anyway
  _ <- c_munmap_ring (wmRingPtr wm) ... -- need ring size here
  when (wmCodePtr wm /= nullPtr) $
    c_munmap_ring (wmCodePtr wm) ... >> return ()  -- reuse munmap for code region
  _ <- c_close (wmRingFd wm)
  when (wmCodeFd wm >= 0) $ c_close (wmCodeFd wm) >> return ()
```

Note: `releaseMapping` needs the ring and code region sizes. Store them in `Hatchery` or pass from config. Simplest: read from `hConfig h` in the release closure.

**Step 5: Export `WorkerMapping` and `Hatchery` fields needed by Dispatch**

`Hatchery(..)` is already exported with all fields. Add `WorkerMapping(..)` to exports.

**Step 6: Verify build**

Run: `nix build .#hatchery 2>&1 | tail -20`
Expected: builds (Dispatch.hs will have unused imports for pidfd/mmap FFI, but should still compile)

**Step 7: Commit**

```bash
git add hatchery/src/Hatchery/Core.hs
git commit -m "feat: reserve all workers at startup, mmap ring buffers and code regions"
```

---

### Task 4: Rewrite `dispatch` to use direct path

**Files:**
- Modify: `hatchery/src/Hatchery/Dispatch.hs`

**Step 1: Add FFI import for `hatchery_write_code`**

```haskell
foreign import ccall "hatchery_write_code"
  c_write_code :: Ptr () -> Ptr () -> Ptr Word8 -> Word32 -> IO ()
```

**Step 2: Add helper to find WorkerMapping by ID**

```haskell
findWorker :: IORef [WorkerMapping] -> Word32 -> IO WorkerMapping
findWorker ref wid = do
  ws <- readIORef ref
  case filter (\w -> wmWorkerId w == wid) ws of
    (w:_) -> return w
    []    -> ioError (userError $ "findWorker: unknown worker " ++ show wid)
```

**Step 3: Rewrite `dispatch`**

```haskell
dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult
dispatch h method codeBytes = do
  let cap = injectionCapability (hConfig h)
  -- Direct dispatch requires memfd (SharedMemfdOnly or BothMethods)
  when (cap == ProcessVmWritevOnly) $
    throwIO IncompatibleInjectionMethod

  -- Take an idle worker (blocks if none available)
  wid <- takeWorker (hIdleWorkers h)
  wm <- findWorker (hWorkerInfo h) wid

  -- Write code directly to mmap'd memfd
  let (fptr, off, len) = BSI.toForeignPtr codeBytes
  withForeignPtr fptr $ \p ->
    c_write_code (wmRingPtr wm) (wmCodePtr wm) (p `plusPtr` off) (fromIntegral len)

  -- Wake and wait (same as run path)
  result <- runWorker h wm

  -- Return worker to idle set (unless crashed)
  case result of
    Crashed _ -> return ()  -- don't return crashed worker
    _         -> putWorker (hIdleWorkers h) wid

  return result

takeWorker :: MVar [Word32] -> IO Word32
takeWorker mv = do
  ws <- takeMVar mv
  case ws of
    []     -> do putMVar mv []; throwIO NoAvailableWorker
    (w:rest) -> do putMVar mv rest; return w

putWorker :: MVar [Word32] -> Word32 -> IO ()
putWorker mv wid = do
  ws <- takeMVar mv
  putMVar mv (wid : ws)
```

**Step 4: Extract shared wake/wait into `runWorker`**

Factor the wake + wait logic from `run` into a shared helper that both `run` and `dispatch` use:

```haskell
runWorker :: Hatchery -> WorkerMapping -> IO DispatchResult
runWorker h wm = do
  let ringPtr = wmRingPtr wm
      pid = wmWorkerPid wm
  case waitStrategy (hConfig h) of
    FutexWait   -> c_wake_worker ringPtr >> runFutexWm wm
    SpinWait n  -> c_wake_worker_spin ringPtr >> runSpinWm wm n
    SpinWaitC n -> c_wake_worker_spin ringPtr >> runSpinCWm wm n
```

The `runFutexWm`, `runSpinWm`, `runSpinCWm` are the existing `runFutex`, `runSpin`, `runSpinC` but taking `WorkerMapping` instead of `PreparedWorker`. Factor to avoid duplication — both `PreparedWorker` and `WorkerMapping` have `ringPtr` and `workerPid`.

Simplest approach: make `run` (for PreparedWorker) delegate to `runWorker` by constructing a temporary `WorkerMapping`, or better, have both `PreparedWorker` and the new dispatch path use the same underlying fields via a shared type or just pass `(Ptr (), Int)` (ringPtr, workerPid).

**Step 5: Update `PreparedWorker` / `prepare` to reuse `WorkerMapping`**

Option: `PreparedWorker` wraps a `WorkerMapping` from the pool instead of doing its own reserve+mmap. `prepare` = take from idle set + write code via fork server (first inject) + return handle. `release` = return to idle set. This unifies the plumbing.

But this is a bigger refactor. For now, keep `PreparedWorker` as-is (it does its own reserve+mmap). The direct dispatch path uses `WorkerMapping` from Core.hs. Unification can happen later.

**Step 6: Verify build**

Run: `nix build .#hatchery 2>&1 | tail -20`
Expected: builds successfully

**Step 7: Commit**

```bash
git add hatchery/src/Hatchery/Dispatch.hs
git commit -m "feat: dispatch bypasses fork server, writes code directly to memfd"
```

---

### Task 5: Update tests

**Files:**
- Modify: `hatchery/test/Main.hs`

**Step 1: Update test to use `SharedMemfdOnly` or `BothMethods`**

The existing test uses `defaultConfig` which is `BothMethods` — this already works. But Test 1 uses `UseProcessVmWritev` which still works for direct dispatch (the code is written to memfd regardless; `InjectionMethod` is now only relevant for `prepare`).

Actually, `dispatch` now ignores `InjectionMethod` — it always writes to memfd directly. The `InjectionMethod` parameter in `dispatch` becomes vestigial. Two options:
1. Keep the parameter but ignore it (backward compat)
2. Remove it from `dispatch` signature

Option 1 is simpler for now. Document that `dispatch` always uses memfd direct write.

But: `dispatch` with `ProcessVmWritevOnly` config now errors. Test 1 uses `defaultConfig` (BothMethods) + `UseProcessVmWritev` — this should still work since the capability check is against the pool config, not the method.

Wait — re-read the new dispatch: `when (cap == ProcessVmWritevOnly) $ throwIO IncompatibleInjectionMethod`. Test uses `BothMethods`, so Test 1 passes. But `UseProcessVmWritev` as a method argument is now meaningless for dispatch. That's fine — it's ignored.

**Step 2: Add test for `ProcessVmWritevOnly` rejection**

```haskell
-- Test 3: ProcessVmWritevOnly config rejects dispatch
putStrLn "Test 3: dispatch rejects ProcessVmWritevOnly..."
withHatchery defaultConfig { poolSize = 1, injectionCapability = ProcessVmWritevOnly } $ \h -> do
  result <- try (dispatch h UseProcessVmWritev payload)
  case result of
    Left IncompatibleInjectionMethod -> putStrLn "  PASS (correctly rejected)"
    _ -> do putStrLn "  FAIL: should have thrown IncompatibleInjectionMethod"; exitFailure
```

**Step 3: Verify tests pass**

Run outside nix sandbox (tests need vfork/seccomp):
```bash
nix build .#hatchery
# Tests are in the build output, or run via nix develop:
nix develop -c cabal test hatchery
```

Wait — CLAUDE.md says tests must run outside nix sandbox. And `nix build` has `dontCheck`. So build first, then run the test binary manually or use `nix develop -c cabal test`.

Actually, the memory says "Always use nix build, not nix develop -c cabal build." But tests can't run in nix build sandbox. This is a known constraint. For testing, we'll need to build and then run the test binary.

**Step 4: Commit**

```bash
git add hatchery/test/Main.hs
git commit -m "test: add ProcessVmWritevOnly rejection test for direct dispatch"
```

---

### Task 6: Update benchmarks

**Files:**
- Modify: `hatchery-bench/src/Main.hs`

**Step 1: Add direct dispatch benchmarks**

The existing `dispatch` benchmarks now automatically use the direct path (since `dispatch` internally bypasses the fork server). The benchmark numbers should drop from ~5500ns to ~3200ns (futex) or ~500ns (spin).

Add spin-wait dispatch benchmark:

```haskell
-- Direct dispatch with spin-wait
let spinDispCfg = defaultConfig { poolSize = 1, waitStrategy = SpinWait 10000 }
withHatchery spinDispCfg $ \h -> do
  -- warmup
  mapM_ (\_ -> dispatch h UseSharedMemfd payload) [1..10 :: Int]

  avgSpinDisp <- timeN hn (dispatch h UseSharedMemfd payload)
  printf "  hatchery (dispatch spin): %7.1f ns/call  (%d calls)\n" avgSpinDisp hn
```

**Step 2: Verify build and run**

```bash
nix build .#hatchery-bench
result/bin/hatchery-bench
```

Compare numbers against baseline.

**Step 3: Commit**

```bash
git add hatchery-bench/src/Main.hs
git commit -m "bench: add spin-wait dispatch benchmark for direct memfd path"
```

---

### Task 7: Update docs and devlog

**Files:**
- Modify: `artifacts/devlog.md`
- Modify: `README.md`

**Step 1: Append devlog entry**

Add new section with measured latency, design decisions, and what changed.

**Step 2: Update README latency table**

Update the dispatch latency numbers and add spin-wait dispatch row.

**Step 3: Update CLAUDE.md**

Update project status, architecture description, dispatch modes table.

**Step 4: Commit and push**

```bash
git add artifacts/devlog.md README.md CLAUDE.md
git commit -m "docs: update latency numbers and architecture for direct dispatch"
git push
```
