{-# LANGUAGE ScopedTypeVariables #-}

module Hatchery.Core
  ( Hatchery(..)
  , WorkerMapping(..)
  , withHatchery
  ) where

import Control.Concurrent (rtsSupportsBoundThreads, runInBoundThread)
import Control.Concurrent.MVar
import Control.Exception (bracket, SomeException, catch)
import Control.Monad (when, forM)
import Data.IORef
import Data.Word (Word32)
import Foreign.C.Types
import Foreign.Ptr
import System.Posix.Types (Fd(..))
import System.Posix.IO (closeFd)

import Hatchery.Config
import Hatchery.Internal.Embedded (forkServerELF)
import Hatchery.Internal.Vfork (SpawnResult(..), spawnForkServer)
import Hatchery.Internal.Protocol (Command(..), Response(..), sendCommand, recvResponse)

-- | Per-worker mmap'd state for direct dispatch.
data WorkerMapping = WorkerMapping
  { wmWorkerId  :: !Word32
  , wmRingPtr   :: !(Ptr ())    -- mmap'd ring buffer
  , wmCodePtr   :: !(Ptr ())    -- mmap'd code memfd
  , wmRingFd    :: !CInt        -- local fd for ring memfd
  , wmCodeFd    :: !CInt        -- local fd for code memfd
  , wmWorkerPid :: !Int
  }

-- | Handle to a running hatchery instance.
data Hatchery = Hatchery
  { hSockFd      :: !Fd                   -- socketpair to fork server
  , hLivenessFd  :: !Fd                   -- write end of liveness pipe
  , hConfig      :: !HatcheryConfig
  , hPid         :: !Int                  -- fork server PID
  , hIdleWorkers :: MVar [Word32]         -- idle worker IDs
  , hWorkerInfo  :: IORef [WorkerMapping] -- per-worker mmap'd state
  }

-- FFI imports for direct dispatch setup
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

-- Convert InjectionCapability to the C wire value
injCapToInt :: InjectionCapability -> Int
injCapToInt ProcessVmWritevOnly = 0
injCapToInt SharedMemfdOnly     = 1
injCapToInt BothMethods         = 2

-- | Create a hatchery, run the action, then shut it down.
-- With -threaded RTS, uses runInBoundThread to ensure vfork happens on a
-- bound OS thread (PDEATHSIG safe). With single-threaded RTS, runs directly
-- (only one OS thread, PDEATHSIG is inherently safe).
withHatchery :: HatcheryConfig -> (Hatchery -> IO a) -> IO a
withHatchery cfg action = inBoundThread $
  bracket acquire release $ \h -> do
    -- Wait for all workers to report ready
    waitForWorkers h
    -- Reserve all workers and set up direct dispatch
    reserveAllWorkers h
    action h
  where
    acquire = do
      let sc = case waitStrategy cfg of
                 FutexWait   -> 0 :: Word32
                 SpinWait n  -> n
                 SpinWaitC n -> n
      sr <- spawnForkServer
        forkServerELF
        (poolSize cfg)
        (injCapToInt (injectionCapability cfg))
        (codeRegionSize cfg)
        (ringBufSize cfg)
        sc
      idleVar <- newMVar []
      infoRef <- newIORef []
      return $ Hatchery
        { hSockFd      = Fd (fromIntegral (srSockFd sr))
        , hLivenessFd  = Fd (fromIntegral (srLivenessFd sr))
        , hConfig      = cfg
        , hPid         = srPid sr
        , hIdleWorkers = idleVar
        , hWorkerInfo  = infoRef
        }

    release h = do
      -- Munmap all ring buffers and code regions, close local fds
      mappings <- readIORef (hWorkerInfo h)
      let rbSize = fromIntegral (ringBufSize cfg)
          codeSize = fromIntegral (codeRegionSize cfg)
      mapM_ (\wm -> do
        _ <- c_munmap_ring (wmRingPtr wm) rbSize
        when (wmCodePtr wm /= nullPtr) $
          c_munmap_ring (wmCodePtr wm) codeSize >> return ()
        _ <- c_close (wmRingFd wm)
        when (wmCodeFd wm >= 0) $
          c_close (wmCodeFd wm) >> return ()
        ) mappings
      -- Send shutdown command (ignore errors)
      sendCommand (hSockFd h) CmdShutdown `catch` \(_ :: SomeException) -> return ()
      closeFd (hSockFd h)
      closeFd (hLivenessFd h)

    waitForWorkers h = do
      let n = poolSize cfg
      mapM_ (\_ -> recvResponse (hSockFd h)) [1..n]
      -- Each should be RspWorkerReady; for now just consume them

    reserveAllWorkers h = do
      let n = poolSize cfg
          rbSize = ringBufSize cfg
          codeSize = codeRegionSize cfg
      -- Open one pidfd for the fork server, reuse for all workers
      fsPidfd <- c_pidfd_open (fromIntegral (hPid h))
      when (fsPidfd < 0) $ ioError (userError "reserveAllWorkers: pidfd_open failed")

      mappings <- forM [0 .. n - 1] $ \_ -> do
        -- Reserve a worker
        sendCommand (hSockFd h) (CmdReserve maxBound)
        rsp <- recvResponse (hSockFd h)
        (wid, remoteRingFd, remoteCodeFd, workerPid) <- case rsp of
          RspWorkerReserved wid rfd cfd wpid ->
            return (wid, rfd, cfd, wpid)
          RspError code ->
            ioError (userError $ "reserveAllWorkers: reserve failed, error code " ++ show code)
          _ -> ioError (userError $ "reserveAllWorkers: unexpected response: " ++ show rsp)

        -- Duplicate fork server's fds into our process via pidfd_getfd
        localRingFd <- c_pidfd_getfd fsPidfd (fromIntegral remoteRingFd)
        when (localRingFd < 0) $ ioError (userError "reserveAllWorkers: pidfd_getfd ring_fd failed")
        localCodeFd <- if remoteCodeFd >= 0
          then do fd <- c_pidfd_getfd fsPidfd (fromIntegral remoteCodeFd)
                  when (fd < 0) $ ioError (userError "reserveAllWorkers: pidfd_getfd code_fd failed")
                  return fd
          else return (-1)

        -- mmap the ring buffer
        ringPtr <- c_mmap_ring localRingFd (fromIntegral rbSize)
        when (ringPtr == nullPtr `plusPtr` (-1)) $
          ioError (userError "reserveAllWorkers: mmap ring failed")

        -- mmap the code region (if we have a code fd)
        codePtr <- if localCodeFd >= 0
          then do p <- c_mmap_code localCodeFd (fromIntegral codeSize)
                  when (p == nullPtr `plusPtr` (-1)) $
                    ioError (userError "reserveAllWorkers: mmap code failed")
                  return p
          else return nullPtr

        -- Enable spin_mode if configured
        case waitStrategy cfg of
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

      _ <- c_close fsPidfd

      -- Populate idle workers list and worker info
      let workerIds = map wmWorkerId mappings
      writeIORef (hWorkerInfo h) mappings
      putMVar (hIdleWorkers h) workerIds

-- | Run action on a bound thread if -threaded, otherwise run directly.
inBoundThread :: IO a -> IO a
inBoundThread
  | rtsSupportsBoundThreads = runInBoundThread
  | otherwise               = id
