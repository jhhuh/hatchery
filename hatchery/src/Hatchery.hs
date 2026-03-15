module Hatchery
  ( -- * Core
    Hatchery
  , WorkerMapping(..)
  , withHatchery
  , HatcheryConfig(..)
  , defaultConfig
  , InjectionCapability(..)
  , InjectionMethod(..)
  , WaitStrategy(..)
    -- * Dispatch
  , dispatch
  , DispatchResult(..)
  , DispatchError(..)
    -- * Pre-loaded payloads
  , PreparedWorker
  , prepare
  , run
  , release
  , withPrepared
  ) where

import Hatchery.Config
import Hatchery.Core (Hatchery, WorkerMapping(..), withHatchery)
import Hatchery.Dispatch
