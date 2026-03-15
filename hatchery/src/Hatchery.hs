module Hatchery
  ( -- * Core
    Hatchery
  , withHatchery
  , HatcheryConfig(..)
  , defaultConfig
  , InjectionCapability(..)
  , InjectionMethod(..)
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
import Hatchery.Core (Hatchery, withHatchery)
import Hatchery.Dispatch
