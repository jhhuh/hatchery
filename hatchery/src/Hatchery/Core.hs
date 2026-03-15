{-# LANGUAGE ScopedTypeVariables #-}

module Hatchery.Core
  ( Hatchery(..)
  , withHatchery
  ) where

import Control.Concurrent (rtsSupportsBoundThreads, isCurrentThreadBound)
import Control.Exception (bracket, SomeException, catch)
import Control.Monad (when)
import System.Posix.Types (Fd(..))
import System.Posix.IO (closeFd)

import Hatchery.Config
import Hatchery.Internal.Embedded (forkServerELF)
import Hatchery.Internal.Vfork (SpawnResult(..), spawnForkServer)
import Hatchery.Internal.Protocol (Command(..), sendCommand, recvResponse)

-- | Handle to a running hatchery instance.
data Hatchery = Hatchery
  { hSockFd     :: !Fd                   -- socketpair to fork server
  , hLivenessFd :: !Fd                   -- write end of liveness pipe
  , hConfig     :: !HatcheryConfig
  , hPid        :: !Int                  -- fork server PID
  }

-- Convert InjectionCapability to the C wire value
injCapToInt :: InjectionCapability -> Int
injCapToInt ProcessVmWritevOnly = 0
injCapToInt SharedMemfdOnly     = 1
injCapToInt BothMethods         = 2

-- | Create a hatchery, run the action, then shut it down.
-- Must be called from a bound thread.
withHatchery :: HatcheryConfig -> (Hatchery -> IO a) -> IO a
withHatchery cfg action = do
  -- Enforce bound thread
  when (not rtsSupportsBoundThreads) $
    error "withHatchery: requires -threaded RTS"
  bound <- isCurrentThreadBound
  when (not bound) $
    error "withHatchery: must be called from a bound thread"

  bracket acquire release $ \h -> do
    -- Wait for all workers to report ready
    waitForWorkers h
    action h
  where
    acquire = do
      sr <- spawnForkServer
        forkServerELF
        (poolSize cfg)
        (injCapToInt (injectionCapability cfg))
        (codeRegionSize cfg)
        (ringBufSize cfg)
      return $ Hatchery
        { hSockFd     = Fd (fromIntegral (srSockFd sr))
        , hLivenessFd = Fd (fromIntegral (srLivenessFd sr))
        , hConfig     = cfg
        , hPid        = srPid sr
        }

    release h = do
      -- Send shutdown command (ignore errors)
      sendCommand (hSockFd h) CmdShutdown `catch` \(_ :: SomeException) -> return ()
      closeFd (hSockFd h)
      closeFd (hLivenessFd h)

    waitForWorkers h = do
      let n = poolSize cfg
      mapM_ (\_ -> recvResponse (hSockFd h)) [1..n]
      -- Each should be RspWorkerReady; for now just consume them
