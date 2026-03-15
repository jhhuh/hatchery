module Hatchery.Config
  ( HatcheryConfig(..)
  , defaultConfig
  , InjectionCapability(..)
  , InjectionMethod(..)
  ) where

-- | Pool-level injection capability determines how workers set up their code regions.
data InjectionCapability
  = ProcessVmWritevOnly  -- ^ Code region: MAP_PRIVATE|MAP_ANONYMOUS. Only process_vm_writev dispatch.
  | SharedMemfdOnly      -- ^ Code region: MAP_SHARED from memfd. Only memfd-write dispatch.
  | BothMethods          -- ^ Code region: MAP_SHARED from memfd. Either method per-dispatch.
  deriving (Show, Eq)

-- | Per-dispatch injection method selection.
data InjectionMethod
  = UseProcessVmWritev   -- ^ Use process_vm_writev to inject code cross-process.
  | UseSharedMemfd       -- ^ Write code to shared memfd, worker sees via mapping.
  deriving (Show, Eq)

-- | Configuration for a hatchery worker pool.
data HatcheryConfig = HatcheryConfig
  { poolSize            :: !Int    -- ^ Number of pre-spawned workers (default: 4)
  , codeRegionSize      :: !Word   -- ^ Executable region per worker in bytes (default: 4MB)
  , ringBufSize         :: !Word   -- ^ Shared ring buffer per worker in bytes (default: 1MB)
  , injectionCapability :: !InjectionCapability  -- ^ Pool-level injection capability (default: BothMethods)
  , dispatchTimeout     :: !(Maybe Double)  -- ^ Per-dispatch timeout in seconds (default: Nothing)
  } deriving (Show, Eq)

-- | Sensible defaults: 4 workers, 4MB code region, 1MB ring buffer, both injection methods.
defaultConfig :: HatcheryConfig
defaultConfig = HatcheryConfig
  { poolSize            = 4
  , codeRegionSize      = 4 * 1024 * 1024
  , ringBufSize         = 1024 * 1024
  , injectionCapability = BothMethods
  , dispatchTimeout     = Nothing
  }
