module Hatchery.Internal.Memfd
  ( memfdCreate
  , memfdSeal
  , MemfdFlag(..)
  , SealFlag(..)
  ) where

import Foreign.C.Types
import Foreign.C.String
import System.Posix.Types (Fd(..))
import Data.Bits ((.|.))

-- | Flags for memfd_create
data MemfdFlag
  = MFD_CLOEXEC        -- 0x0001
  | MFD_ALLOW_SEALING  -- 0x0002
  deriving (Eq, Show)

memfdFlagValue :: MemfdFlag -> CUInt
memfdFlagValue MFD_CLOEXEC = 0x0001
memfdFlagValue MFD_ALLOW_SEALING = 0x0002

-- | Seal flags for fcntl F_ADD_SEALS
data SealFlag
  = SEAL_SEAL     -- 0x0001
  | SEAL_SHRINK   -- 0x0002
  | SEAL_GROW     -- 0x0004
  | SEAL_WRITE    -- 0x0008
  deriving (Eq, Show)

sealFlagValue :: SealFlag -> CInt
sealFlagValue SEAL_SEAL   = 0x0001
sealFlagValue SEAL_SHRINK = 0x0002
sealFlagValue SEAL_GROW   = 0x0004
sealFlagValue SEAL_WRITE  = 0x0008

foreign import ccall unsafe "memfd_create"
  c_memfd_create :: CString -> CUInt -> IO CInt

foreign import ccall unsafe "fcntl"
  c_fcntl :: CInt -> CInt -> CInt -> IO CInt

-- | Create a memfd with the given name and flags.
memfdCreate :: String -> [MemfdFlag] -> IO Fd
memfdCreate name flags = withCString name $ \cname -> do
  let flagBits = foldr (\f acc -> acc .|. memfdFlagValue f) 0 flags
  fd <- c_memfd_create cname flagBits
  if fd < 0
    then ioError (userError $ "memfd_create failed: " ++ show fd)
    else return (Fd fd)

-- | Add seals to a memfd via fcntl F_ADD_SEALS (1033).
memfdSeal :: Fd -> [SealFlag] -> IO ()
memfdSeal (Fd fd) seals = do
  let sealBits = foldr (\s acc -> acc .|. sealFlagValue s) 0 seals
  ret <- c_fcntl fd 1033 sealBits  -- F_ADD_SEALS = 1033
  if ret < 0
    then ioError (userError $ "fcntl F_ADD_SEALS failed: " ++ show ret)
    else return ()
