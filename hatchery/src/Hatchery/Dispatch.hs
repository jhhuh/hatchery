module Hatchery.Dispatch
  ( dispatch
  , DispatchResult(..)
  , DispatchError(..)
    -- * Pre-loaded payloads
  , PreparedWorker
  , prepare
  , run
  , release
  , withPrepared
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import Data.Int
import Data.IORef
import Data.Word
import Control.Concurrent.MVar
import Control.Exception (throwIO, Exception, bracket)
import Control.Monad (when)
import Foreign.Ptr
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable (peek)
import Foreign.Marshal.Alloc (alloca)
import Foreign.C.Types

import Hatchery.Config (InjectionCapability(..), InjectionMethod, HatcheryConfig(..), WaitStrategy(..))
import Hatchery.Core (Hatchery(..), WorkerMapping(..))
import Hatchery.Internal.SpinWait (spinWait)

data DispatchResult
  = Completed !Int32 !(Maybe ByteString)  -- exit code + optional result bytes
  | Crashed !Int32                         -- signal number
  deriving (Show)

data DispatchError
  = NoAvailableWorker
  | HatcheryDead
  | IncompatibleInjectionMethod
  deriving (Show)

instance Exception DispatchError

-- | Opaque handle to a worker with pre-loaded code.
-- Wraps a WorkerMapping from the pool — the ring buffer and code region
-- are already mmap'd by withHatchery.
data PreparedWorker = PreparedWorker
  { pwHatchery  :: !Hatchery
  , pwWorkerId  :: !Word32
  , pwMapping   :: !WorkerMapping
  }

-- FFI imports for direct dispatch
foreign import ccall "hatchery_wake_worker"
  c_wake_worker :: Ptr () -> IO ()

foreign import ccall "hatchery_wake_worker_spin"
  c_wake_worker_spin :: Ptr () -> IO ()

foreign import ccall "hatchery_wait_worker"
  c_wait_worker :: Ptr () -> CInt -> Ptr Int32 -> IO CInt

foreign import ccall "hatchery_result_size"
  c_result_size :: Ptr () -> IO Word32

foreign import ccall "hatchery_result_data"
  c_result_data :: Ptr () -> IO (Ptr Word8)

foreign import ccall unsafe "hatchery_spin_wait_c"
  c_spin_wait :: Ptr () -> Word32 -> Ptr Int32 -> IO CInt

foreign import ccall safe "hatchery_futex_wait_safe"
  c_futex_wait_safe :: Ptr () -> IO CInt

foreign import ccall "hatchery_write_code"
  c_write_code :: Ptr () -> Ptr () -> Ptr Word8 -> Word32 -> IO ()

-- | Take an idle worker from the pool. Returns Nothing if none available.
takeWorker :: MVar [Word32] -> IO (Maybe Word32)
takeWorker mv = do
  ws <- takeMVar mv
  case ws of
    []     -> putMVar mv [] >> return Nothing
    (w:rest) -> putMVar mv rest >> return (Just w)

-- | Return a worker to the idle pool.
putWorker :: MVar [Word32] -> Word32 -> IO ()
putWorker mv wid = do
  ws <- takeMVar mv
  putMVar mv (wid : ws)

-- | Find a worker mapping by ID.
findWorker :: IORef [WorkerMapping] -> Word32 -> IO WorkerMapping
findWorker ref wid = do
  ws <- readIORef ref
  case filter (\w -> wmWorkerId w == wid) ws of
    (w:_) -> return w
    []    -> ioError (userError $ "findWorker: unknown worker " ++ show wid)

-- | Core wake+wait logic shared by dispatch and run.
runDirect :: Hatchery -> Ptr () -> Int -> IO DispatchResult
runDirect h ringPtr workerPid = do
  case waitStrategy (hConfig h) of
    FutexWait   -> c_wake_worker ringPtr >> waitFutex ringPtr workerPid
    SpinWait n  -> c_wake_worker_spin ringPtr >> waitSpin ringPtr n
    SpinWaitC n -> c_wake_worker_spin ringPtr >> waitSpinC ringPtr n

-- | Futex-based wait.
waitFutex :: Ptr () -> Int -> IO DispatchResult
waitFutex ringPtr workerPid =
  alloca $ \ecPtr -> do
    ret <- c_wait_worker ringPtr (fromIntegral workerPid) ecPtr
    if ret == 0
      then readResult ringPtr ecPtr
      else return $ Crashed 0

-- | Spin-wait with futex fallback (Cmm via inline-cmm).
waitSpin :: Ptr () -> Word32 -> IO DispatchResult
waitSpin ringPtr n = go
  where
    go = case spinWait ringPtr n of
      (0, ec) -> do
        rsz <- c_result_size ringPtr
        if rsz > 0
          then do
            dataPtr <- c_result_data ringPtr
            bs <- BS.packCStringLen (castPtr dataPtr, fromIntegral rsz)
            return $ Completed (fromIntegral ec) (Just bs)
          else return $ Completed (fromIntegral ec) Nothing
      (1, _) -> return $ Crashed 0
      _      -> do
        _ <- c_futex_wait_safe ringPtr
        go

-- | Spin-wait with futex fallback (C, atomics inlined by GCC).
waitSpinC :: Ptr () -> Word32 -> IO DispatchResult
waitSpinC ringPtr n = alloca $ \ecPtr -> go ecPtr
  where
    go ecPtr = do
      ret <- c_spin_wait ringPtr n ecPtr
      case ret of
        0 -> do
          ec <- peek ecPtr
          rsz <- c_result_size ringPtr
          if rsz > 0
            then do
              dataPtr <- c_result_data ringPtr
              bs <- BS.packCStringLen (castPtr dataPtr, fromIntegral rsz)
              return $ Completed ec (Just bs)
            else return $ Completed ec Nothing
        1 -> return $ Crashed 0
        _ -> do
          _ <- c_futex_wait_safe ringPtr
          go ecPtr

-- | Read result after successful futex wait.
readResult :: Ptr () -> Ptr Int32 -> IO DispatchResult
readResult ringPtr ecPtr = do
  ec <- peek ecPtr
  rsz <- c_result_size ringPtr
  if rsz > 0
    then do
      dataPtr <- c_result_data ringPtr
      bs <- BS.packCStringLen (castPtr dataPtr, fromIntegral rsz)
      return $ Completed ec (Just bs)
    else return $ Completed ec Nothing

-- | Dispatch code to a worker. Bypasses the fork server entirely:
-- takes an idle worker, writes code directly to the mmap'd memfd,
-- wakes the worker, and waits for completion.
dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult
dispatch h _method codeBytes = do
  let cap = injectionCapability (hConfig h)
  when (cap == ProcessVmWritevOnly) $
    throwIO IncompatibleInjectionMethod

  mwid <- takeWorker (hIdleWorkers h)
  wid <- case mwid of
    Nothing -> throwIO NoAvailableWorker
    Just w  -> return w

  wm <- findWorker (hWorkerInfo h) wid

  -- Write code directly to mmap'd memfd
  let (fptr, off, len) = BSI.toForeignPtr codeBytes
  withForeignPtr fptr $ \p ->
    c_write_code (wmRingPtr wm) (wmCodePtr wm) (p `plusPtr` off) (fromIntegral len)

  -- Wake and wait (same path as run)
  result <- runDirect h (wmRingPtr wm) (wmWorkerPid wm)

  -- Return worker to idle set (unless crashed)
  case result of
    Crashed _ -> return ()
    _         -> putWorker (hIdleWorkers h) wid

  return result

-- | Take an idle worker from the pool, inject code, and return a handle
-- for repeated re-runs. The worker is removed from the idle set until
-- 'release' returns it.
prepare :: Hatchery -> InjectionMethod -> ByteString -> IO PreparedWorker
prepare h _method codeBytes = do
  let cap = injectionCapability (hConfig h)
  when (cap == ProcessVmWritevOnly) $
    throwIO IncompatibleInjectionMethod

  mwid <- takeWorker (hIdleWorkers h)
  wid <- case mwid of
    Nothing -> throwIO NoAvailableWorker
    Just w  -> return w

  wm <- findWorker (hWorkerInfo h) wid

  -- Write code directly to mmap'd memfd
  let (fptr, off, len) = BSI.toForeignPtr codeBytes
  withForeignPtr fptr $ \p ->
    c_write_code (wmRingPtr wm) (wmCodePtr wm) (p `plusPtr` off) (fromIntegral len)

  -- Run once to verify code loads correctly
  result <- runDirect h (wmRingPtr wm) (wmWorkerPid wm)
  case result of
    Crashed _ -> do
      -- Worker crashed during initial run — don't return to pool
      throwIO HatcheryDead
    _ -> return ()

  return PreparedWorker
    { pwHatchery = h
    , pwWorkerId = wid
    , pwMapping  = wm
    }

-- | Re-run pre-loaded code on a prepared worker.
-- Direct Haskell↔worker path: no socketpair, no fork server.
run :: PreparedWorker -> IO DispatchResult
run pw = runDirect (pwHatchery pw) (wmRingPtr (pwMapping pw)) (wmWorkerPid (pwMapping pw))

-- | Release a prepared worker back to the idle pool.
release :: PreparedWorker -> IO ()
release pw = putWorker (hIdleWorkers (pwHatchery pw)) (pwWorkerId pw)

-- | Bracket pattern: prepare, run action, release.
withPrepared :: Hatchery -> InjectionMethod -> ByteString
             -> (PreparedWorker -> IO a) -> IO a
withPrepared h method codeBytes =
  bracket (prepare h method codeBytes) release
