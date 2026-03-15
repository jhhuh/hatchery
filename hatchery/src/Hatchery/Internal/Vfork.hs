module Hatchery.Internal.Vfork
  ( SpawnResult(..)
  , spawnForkServer
  ) where

import Foreign.C.Types
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc (alloca)
import Data.Word (Word8, Word32)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Unsafe as BSU

data SpawnResult = SpawnResult
  { srPid        :: !Int   -- fork server PID
  , srSockFd     :: !Int   -- our end of socketpair
  , srLivenessFd :: !Int   -- write end of liveness pipe
  } deriving (Show)

-- C struct: 3 ints = 12 bytes
instance Storable SpawnResult where
  sizeOf _    = 12
  alignment _ = 4
  peek ptr = do
    pid  <- peekByteOff ptr 0 :: IO CInt
    sock <- peekByteOff ptr 4 :: IO CInt
    live <- peekByteOff ptr 8 :: IO CInt
    return $ SpawnResult (fromIntegral pid) (fromIntegral sock) (fromIntegral live)
  poke ptr (SpawnResult pid sock live) = do
    pokeByteOff ptr 0 (fromIntegral pid :: CInt)
    pokeByteOff ptr 4 (fromIntegral sock :: CInt)
    pokeByteOff ptr 8 (fromIntegral live :: CInt)

foreign import ccall "spawn_fork_server"
  c_spawn_fork_server
    :: Ptr Word8        -- elf_data
    -> CUInt            -- elf_size
    -> CInt             -- pool_size
    -> CInt             -- injection_cap
    -> CULong           -- code_region_size
    -> CULong           -- ring_buf_size
    -> CUInt            -- spin_count
    -> Ptr SpawnResult  -- out
    -> IO CInt          -- returns 0 on success, -errno on failure

-- | Spawn the fork server process.
spawnForkServer :: ByteString  -- ^ Fork server ELF binary
               -> Int          -- ^ Pool size
               -> Int          -- ^ Injection capability (0/1/2)
               -> Word         -- ^ Code region size
               -> Word         -- ^ Ring buffer size
               -> Word32       -- ^ Spin count (0 = pure futex)
               -> IO SpawnResult
spawnForkServer elf poolSz injCap crSize rbSize spinCount =
  BSU.unsafeUseAsCStringLen elf $ \(ptr, len) ->
    alloca $ \outPtr -> do
      ret <- c_spawn_fork_server
        (castPtr ptr)
        (fromIntegral len)
        (fromIntegral poolSz)
        (fromIntegral injCap)
        (fromIntegral crSize)
        (fromIntegral rbSize)
        (fromIntegral spinCount)
        outPtr
      if ret /= 0
        then ioError (userError $ "spawn_fork_server failed: " ++ show ret)
        else peek outPtr
