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
data PreparedWorker = PreparedWorker
  { pwHatchery :: !Hatchery
  , pwWorkerId :: !Word32
  }

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
prepare :: Hatchery -> InjectionMethod -> ByteString -> IO PreparedWorker
prepare h method codeBytes = do
  let cap = injectionCapability (hConfig h)
  if not (validateMethod cap method)
    then throwIO IncompatibleInjectionMethod
    else do
      -- Reserve an idle worker
      sendCommand (hSockFd h) (CmdReserve maxBound)
      rsp <- recvResponse (hSockFd h)
      wid <- case rsp of
        RspWorkerReserved wid -> return wid
        RspError code ->
          if code == -1
            then throwIO NoAvailableWorker
            else throwIO HatcheryDead
        _ -> ioError (userError $ "prepare: unexpected response: " ++ show rsp)

      -- Dispatch code to the reserved worker
      let cmd = CmdDispatch
            (DispatchCmd
              { dcWorkerId = wid
              , dcInjectionMethod = methodToWire method
              , dcCodeLen = fromIntegral (BS.length codeBytes)
              })
            codeBytes
      sendCommand (hSockFd h) cmd
      _ <- handleResponse h  -- consume the first run's result

      return (PreparedWorker h wid)

-- | Re-run pre-loaded code on a prepared worker (no injection, pure futex round-trip).
run :: PreparedWorker -> IO DispatchResult
run pw = do
  sendCommand (hSockFd (pwHatchery pw)) (CmdRun (pwWorkerId pw))
  handleResponse (pwHatchery pw)

-- | Release a reserved worker back to the pool.
release :: PreparedWorker -> IO ()
release pw =
  sendCommand (hSockFd (pwHatchery pw)) (CmdRelease (pwWorkerId pw))

-- | Bracket pattern: prepare, run action, release.
withPrepared :: Hatchery -> InjectionMethod -> ByteString
             -> (PreparedWorker -> IO a) -> IO a
withPrepared h method codeBytes =
  bracket (prepare h method codeBytes) release
