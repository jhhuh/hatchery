module TrustlessFFI
  ( -- * Setup
    FFI
  , withFFI
  , FFIConfig(..)
  , defaultFFIConfig
    -- * Calling foreign code
  , call
  , callAsync
  , CallResult(..)
    -- * Re-exports for convenience
  , InjectionMethod(..)
  ) where

import Data.ByteString (ByteString)
import Control.Concurrent.Async (Async, async)
import Data.Int (Int32)

import qualified Hatchery
import Hatchery (InjectionMethod(..), InjectionCapability(..))

-- | Simplified config hiding pool/sandbox details.
data FFIConfig = FFIConfig
  { maxConcurrent   :: !Int              -- ^ Max concurrent calls (= pool size, default: 4)
  , timeout         :: !(Maybe Double)   -- ^ Per-call timeout in seconds (default: 30)
  , injectionMethod :: !InjectionMethod  -- ^ Default injection method (default: UseSharedMemfd)
  } deriving (Show, Eq)

defaultFFIConfig :: FFIConfig
defaultFFIConfig = FFIConfig
  { maxConcurrent   = 4
  , timeout         = Just 30.0
  , injectionMethod = UseSharedMemfd
  }

-- | Opaque handle to a trustless-ffi instance.
newtype FFI = FFI Hatchery.Hatchery

-- | Create a trustless-ffi instance.
-- Must be called from a bound thread (enforced by hatchery).
withFFI :: FFIConfig -> (FFI -> IO a) -> IO a
withFFI cfg action =
  Hatchery.withHatchery (toHatcheryConfig cfg) $ \h ->
    action (FFI h)

toHatcheryConfig :: FFIConfig -> Hatchery.HatcheryConfig
toHatcheryConfig cfg = Hatchery.defaultConfig
  { Hatchery.poolSize            = maxConcurrent cfg
  , Hatchery.injectionCapability = BothMethods
  , Hatchery.dispatchTimeout     = timeout cfg
  }

-- | Result of a foreign call.
data CallResult
  = Success !Int32 !(Maybe ByteString)  -- ^ Exit code and optional result data
  | ForeignCrash !String                -- ^ Human-readable crash description
  | Timeout                             -- ^ Call exceeded timeout
  deriving (Show)

-- | Call foreign code synchronously.
-- The ByteString must contain raw x86_64 machine code.
call :: FFI -> ByteString -> IO CallResult
call = callWith UseSharedMemfd

-- | Call foreign code with a specific injection method.
callWith :: InjectionMethod -> FFI -> ByteString -> IO CallResult
callWith method (FFI h) codeBytes = do
  result <- Hatchery.dispatch h method codeBytes
  return $ case result of
    Hatchery.Completed code mdata -> Success code mdata
    Hatchery.Crashed sig -> ForeignCrash $ "Worker crashed with signal " ++ show sig

-- | Call foreign code asynchronously.
callAsync :: FFI -> ByteString -> IO (Async CallResult)
callAsync ffi codeBytes = async $ call ffi codeBytes
