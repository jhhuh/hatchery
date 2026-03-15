module Hatchery.Internal.Protocol
  ( Command(..)
  , Response(..)
  , DispatchCmd(..)
  , WorkerDoneRsp(..)
  , WorkerCrashedRsp(..)
  , PoolStatusRsp(..)
  , InjectionMethodWire(..)
  , sendCommand
  , recvResponse
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import Foreign.Storable
import Foreign.Ptr
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Utils (fillBytes)
import Data.Word
import Data.Int
import System.Posix.Types (Fd(..))
import System.Posix.IO (fdReadBuf, fdWriteBuf)

-- Wire sizes matching C structs
commandSize :: Int
commandSize = 16  -- 4 (type) + 12 (cmd_dispatch)

responseSize :: Int
responseSize = 20  -- 4 (type) + 16 (rsp_pool_status is largest union member)

------------------------------------------------------------------------
-- Wire format injection method values (match ring_buffer.h)
------------------------------------------------------------------------

data InjectionMethodWire = WireProcessVmWritev | WireSharedMemfd
  deriving (Eq, Show)

injectionMethodToWord :: InjectionMethodWire -> Word32
injectionMethodToWord WireProcessVmWritev = 0
injectionMethodToWord WireSharedMemfd     = 1

------------------------------------------------------------------------
-- Command types (match protocol.h cmd_type enum)
------------------------------------------------------------------------

data Command
  = CmdDispatch !DispatchCmd !ByteString  -- dispatch command + code bytes
  | CmdStatus
  | CmdShutdown
  deriving (Show)

data DispatchCmd = DispatchCmd
  { dcWorkerId        :: !Word32  -- use maxBound for auto-select
  , dcInjectionMethod :: !InjectionMethodWire
  , dcCodeLen         :: !Word32
  } deriving (Show)

------------------------------------------------------------------------
-- Response types (match protocol.h rsp_type enum)
------------------------------------------------------------------------

data Response
  = RspWorkerReady !Word32           -- worker_id
  | RspWorkerDone !WorkerDoneRsp !(Maybe ByteString)  -- result data if any
  | RspWorkerCrashed !WorkerCrashedRsp
  | RspPoolStatus !PoolStatusRsp
  | RspError !Int32
  deriving (Show)

data WorkerDoneRsp = WorkerDoneRsp
  { wdWorkerId   :: !Word32
  , wdExitCode   :: !Int32
  , wdResultSize :: !Word32
  } deriving (Show)

data WorkerCrashedRsp = WorkerCrashedRsp
  { wcWorkerId :: !Word32
  , wcSignal   :: !Int32
  } deriving (Show)

data PoolStatusRsp = PoolStatusRsp
  { psPoolSize     :: !Word32
  , psIdleCount    :: !Word32
  , psBusyCount    :: !Word32
  , psCrashedCount :: !Word32
  } deriving (Show)

------------------------------------------------------------------------
-- Serialization helpers
------------------------------------------------------------------------

pokeW32 :: Ptr Word8 -> Int -> Word32 -> IO ()
pokeW32 base off val = pokeByteOff (castPtr base) off val

peekW32 :: Ptr Word8 -> Int -> IO Word32
peekW32 base off = peekByteOff (castPtr base) off

pokeI32 :: Ptr Word8 -> Int -> Int32 -> IO ()
pokeI32 base off val = pokeByteOff (castPtr base) off val

peekI32 :: Ptr Word8 -> Int -> IO Int32
peekI32 base off = peekByteOff (castPtr base) off

-- Write exactly n bytes to fd, looping on short writes.
writeAll :: Fd -> Ptr Word8 -> Int -> IO ()
writeAll _  _   0   = return ()
writeAll fd buf len = do
  written <- fdWriteBuf fd buf (fromIntegral len)
  let n = fromIntegral written
  if n <= 0
    then ioError (userError "writeAll: write failed")
    else writeAll fd (buf `plusPtr` n) (len - n)

-- Read exactly n bytes from fd, looping on short reads.
readAll :: Fd -> Ptr Word8 -> Int -> IO ()
readAll _  _   0   = return ()
readAll fd buf len = do
  got <- fdReadBuf fd buf (fromIntegral len)
  let n = fromIntegral got
  if n <= 0
    then ioError (userError "readAll: read failed or EOF")
    else readAll fd (buf `plusPtr` n) (len - n)

------------------------------------------------------------------------
-- sendCommand
------------------------------------------------------------------------

sendCommand :: Fd -> Command -> IO ()
sendCommand fd cmd = allocaBytes commandSize $ \buf -> do
  fillBytes buf 0 commandSize
  case cmd of
    CmdDispatch dc codeBytes -> do
      pokeW32 buf 0 1  -- CMD_DISPATCH
      pokeW32 buf 4 (dcWorkerId dc)
      pokeW32 buf 8 (injectionMethodToWord (dcInjectionMethod dc))
      pokeW32 buf 12 (dcCodeLen dc)
      writeAll fd buf commandSize
      -- Send code bytes immediately after
      let (fptr, off, clen) = BSI.toForeignPtr codeBytes
      withForeignPtr fptr $ \p ->
        writeAll fd (p `plusPtr` off) clen
    CmdStatus -> do
      pokeW32 buf 0 2  -- CMD_STATUS
      writeAll fd buf commandSize
    CmdShutdown -> do
      pokeW32 buf 0 3  -- CMD_SHUTDOWN
      writeAll fd buf commandSize

------------------------------------------------------------------------
-- recvResponse
------------------------------------------------------------------------

recvResponse :: Fd -> IO Response
recvResponse fd = allocaBytes responseSize $ \buf -> do
  readAll fd buf responseSize
  rtype <- peekW32 buf 0
  case rtype of
    1 -> do  -- RSP_WORKER_READY
      wid <- peekW32 buf 4
      return (RspWorkerReady wid)
    2 -> do  -- RSP_WORKER_DONE
      wid  <- peekW32 buf 4
      ec   <- peekI32 buf 8
      rsz  <- peekW32 buf 12
      let done = WorkerDoneRsp wid ec rsz
      if rsz > 0
        then do
          resultBytes <- BSI.create (fromIntegral rsz) $ \p ->
            readAll fd p (fromIntegral rsz)
          return (RspWorkerDone done (Just resultBytes))
        else return (RspWorkerDone done Nothing)
    3 -> do  -- RSP_WORKER_CRASHED
      wid <- peekW32 buf 4
      sig <- peekI32 buf 8
      return (RspWorkerCrashed (WorkerCrashedRsp wid sig))
    4 -> do  -- RSP_POOL_STATUS
      ps <- peekW32 buf 4
      ic <- peekW32 buf 8
      bc <- peekW32 buf 12
      cc <- peekW32 buf 16
      return (RspPoolStatus (PoolStatusRsp ps ic bc cc))
    5 -> do  -- RSP_ERROR
      code <- peekI32 buf 4
      return (RspError code)
    _ -> ioError (userError $ "recvResponse: unknown response type " ++ show rtype)
