{-# LANGUAGE ScopedTypeVariables #-}

module Hatchery.Core
  ( Hatchery(..)
  , withHatchery
  ) where

import Control.Concurrent (runInBoundThread)
import Control.Exception (bracket, SomeException, catch)
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
-- Uses runInBoundThread to ensure the vfork happens on a bound OS thread,
-- so PR_SET_PDEATHSIG on the fork server fires at the right time.
-- Works with both -threaded and single-threaded RTS.
withHatchery :: HatcheryConfig -> (Hatchery -> IO a) -> IO a
withHatchery cfg action = runInBoundThread $
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
