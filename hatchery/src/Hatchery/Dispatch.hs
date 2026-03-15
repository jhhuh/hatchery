module Hatchery.Dispatch
  ( dispatch
  , DispatchResult(..)
  , DispatchError(..)
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int
import Control.Exception (throwIO, Exception)

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

-- | Validate that the requested injection method is compatible with pool capability.
validateMethod :: InjectionCapability -> InjectionMethod -> Bool
validateMethod BothMethods         _                  = True
validateMethod ProcessVmWritevOnly UseProcessVmWritev = True
validateMethod SharedMemfdOnly     UseSharedMemfd     = True
validateMethod _                   _                  = False

methodToWire :: InjectionMethod -> InjectionMethodWire
methodToWire UseProcessVmWritev = WireProcessVmWritev
methodToWire UseSharedMemfd     = WireSharedMemfd

-- | Dispatch code to a worker.
dispatch :: Hatchery -> InjectionMethod -> ByteString -> IO DispatchResult
dispatch h method codeBytes = do
  -- Validate injection method against pool capability
  let cap = injectionCapability (hConfig h)
  if not (validateMethod cap method)
    then throwIO IncompatibleInjectionMethod
    else do
      -- Send dispatch command
      let cmd = CmdDispatch
            (DispatchCmd
              { dcWorkerId = maxBound  -- auto-select
              , dcInjectionMethod = methodToWire method
              , dcCodeLen = fromIntegral (BS.length codeBytes)
              })
            codeBytes
      sendCommand (hSockFd h) cmd

      -- Wait for response
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
