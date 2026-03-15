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
import Data.Int
import Data.Word
import Control.Exception (throwIO, Exception, bracket)
import Foreign.Ptr
import Foreign.Storable (peek)
import Foreign.Marshal.Alloc (alloca)
import Foreign.C.Types

import Hatchery.Config (InjectionCapability(..), InjectionMethod(..), HatcheryConfig(..))
import Hatchery.Core (Hatchery(..))
import Hatchery.Internal.Protocol

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
-- The ring buffer is mmap'd into the Haskell process for direct access.
data PreparedWorker = PreparedWorker
  { pwHatchery  :: !Hatchery
  , pwWorkerId  :: !Word32
  , pwRingPtr   :: !(Ptr ())      -- mmap'd ring buffer
  , pwRingSize  :: !Word          -- ring buffer size (for munmap)
  , pwWorkerPid :: !Int           -- worker PID (for liveness check)
  , pwRingFd    :: !CInt          -- local fd for ring buffer memfd
  , pwCodeFd    :: !CInt          -- local fd for code memfd (-1 if none)
  }

-- FFI imports for direct dispatch
foreign import ccall "hatchery_pidfd_open"
  c_pidfd_open :: CInt -> IO CInt

foreign import ccall "hatchery_pidfd_getfd"
  c_pidfd_getfd :: CInt -> CInt -> IO CInt

foreign import ccall "hatchery_mmap_ring"
  c_mmap_ring :: CInt -> CULong -> IO (Ptr ())

foreign import ccall "hatchery_munmap_ring"
  c_munmap_ring :: Ptr () -> CULong -> IO CInt

foreign import ccall "hatchery_wake_worker"
  c_wake_worker :: Ptr () -> IO ()

foreign import ccall "hatchery_wait_worker"
  c_wait_worker :: Ptr () -> CInt -> Ptr Int32 -> IO CInt

foreign import ccall "hatchery_result_size"
  c_result_size :: Ptr () -> IO Word32

foreign import ccall "hatchery_result_data"
  c_result_data :: Ptr () -> IO (Ptr Word8)

foreign import ccall "close"
  c_close :: CInt -> IO CInt

-- | Validate that the requested injection method is compatible with pool capability.
validateMethod :: InjectionCapability -> InjectionMethod -> Bool
validateMethod BothMethods         _                  = True
validateMethod ProcessVmWritevOnly UseProcessVmWritev = True
validateMethod SharedMemfdOnly     UseSharedMemfd     = True
validateMethod _                   _                  = False

methodToWire :: InjectionMethod -> InjectionMethodWire
methodToWire UseProcessVmWritev = WireProcessVmWritev
methodToWire UseSharedMemfd     = WireSharedMemfd

-- | Handle a dispatch/run response from the fork server.
handleResponse :: Hatchery -> IO DispatchResult
handleResponse h = do
  rsp <- recvResponse (hSockFd h)
  case rsp of
    RspWorkerDone done mdata ->
      return $ Completed (wdExitCode done) mdata
    RspWorkerCrashed crashed ->
      return $ Crashed (wcSignal crashed)
    RspError code ->
      if code == -1
        then throwIO NoAvailableWorker
        else throwIO HatcheryDead
    _ -> ioError (userError $ "dispatch: unexpected response: " ++ show rsp)

-- | Dispatch code to a worker.
dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult
dispatch h method codeBytes = do
  let cap = injectionCapability (hConfig h)
  if not (validateMethod cap method)
    then throwIO IncompatibleInjectionMethod
    else do
      let cmd = CmdDispatch
            (DispatchCmd
              { dcWorkerId = maxBound  -- auto-select
              , dcInjectionMethod = methodToWire method
              , dcCodeLen = fromIntegral (BS.length codeBytes)
              })
            codeBytes
      sendCommand (hSockFd h) cmd
      handleResponse h

-- | Reserve a worker, inject code, and run it once.
-- The worker is reserved from the pool and can be re-run via 'run'.
-- The ring buffer is mmap'd for direct Haskell↔worker communication.
prepare :: Hatchery -> InjectionMethod -> ByteString -> IO PreparedWorker
prepare h method codeBytes = do
  let cap = injectionCapability (hConfig h)
  if not (validateMethod cap method)
    then throwIO IncompatibleInjectionMethod
    else do
      -- Reserve an idle worker
      sendCommand (hSockFd h) (CmdReserve maxBound)
      rsp <- recvResponse (hSockFd h)
      (wid, remoteRingFd, remoteCodeFd, workerPid) <- case rsp of
        RspWorkerReserved wid rfd cfd wpid ->
          return (wid, rfd, cfd, wpid)
        RspError code ->
          if code == -1
            then throwIO NoAvailableWorker
            else throwIO HatcheryDead
        _ -> ioError (userError $ "prepare: unexpected response: " ++ show rsp)

      -- Duplicate fork server's fds into our process via pidfd_getfd
      fsPidfd <- c_pidfd_open (fromIntegral (hPid h))
      localRingFd <- c_pidfd_getfd fsPidfd (fromIntegral remoteRingFd)
      localCodeFd <- if remoteCodeFd >= 0
        then c_pidfd_getfd fsPidfd (fromIntegral remoteCodeFd)
        else return (-1)
      _ <- c_close fsPidfd

      -- mmap the ring buffer
      let rbSize = ringBufSize (hConfig h)
      ringPtr <- c_mmap_ring localRingFd (fromIntegral rbSize)

      let pw = PreparedWorker
            { pwHatchery  = h
            , pwWorkerId  = wid
            , pwRingPtr   = ringPtr
            , pwRingSize  = rbSize
            , pwWorkerPid = fromIntegral workerPid
            , pwRingFd    = localRingFd
            , pwCodeFd    = localCodeFd
            }

      -- First dispatch via fork server to inject code
      let cmd = CmdDispatch
            (DispatchCmd
              { dcWorkerId = wid
              , dcInjectionMethod = methodToWire method
              , dcCodeLen = fromIntegral (BS.length codeBytes)
              })
            codeBytes
      sendCommand (hSockFd h) cmd
      _ <- handleResponse h

      return pw

-- | Re-run pre-loaded code on a prepared worker.
-- Direct Haskell↔worker path: no socketpair, no fork server.
run :: PreparedWorker -> IO DispatchResult
run pw = do
  c_wake_worker (pwRingPtr pw)
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

-- | Release a reserved worker back to the pool.
release :: PreparedWorker -> IO ()
release pw = do
  -- Unmap ring buffer
  _ <- c_munmap_ring (pwRingPtr pw) (fromIntegral (pwRingSize pw))
  -- Close local fds
  _ <- c_close (pwRingFd pw)
  if pwCodeFd pw >= 0
    then c_close (pwCodeFd pw) >> return ()
    else return ()
  -- Tell fork server to release
  sendCommand (hSockFd (pwHatchery pw)) (CmdRelease (pwWorkerId pw))

-- | Bracket pattern: prepare, run action, release.
withPrepared :: Hatchery -> InjectionMethod -> ByteString
             -> (PreparedWorker -> IO a) -> IO a
withPrepared h method codeBytes =
  bracket (prepare h method codeBytes) release
