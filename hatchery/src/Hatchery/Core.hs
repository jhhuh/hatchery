{-# LANGUAGE ScopedTypeVariables #-}

module Hatchery.Core
  ( Hatchery(..)
  , withHatchery
  ) where

import Control.Concurrent (rtsSupportsBoundThreads, runInBoundThread)
import Control.Exception (bracket, SomeException, catch)
import System.Posix.Types (Fd(..))
import System.Posix.IO (closeFd)

import Hatchery.Config
import Data.Word (Word32)
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
-- With -threaded RTS, uses runInBoundThread to ensure vfork happens on a
-- bound OS thread (PDEATHSIG safe). With single-threaded RTS, runs directly
-- (only one OS thread, PDEATHSIG is inherently safe).
withHatchery :: HatcheryConfig -> (Hatchery -> IO a) -> IO a
withHatchery cfg action = inBoundThread $
  bracket acquire release $ \h -> do
    -- Wait for all workers to report ready
    waitForWorkers h
    action h
  where
    acquire = do
      let sc = case waitStrategy cfg of
                 FutexWait  -> 0 :: Word32
                 SpinWait n -> n
      sr <- spawnForkServer
        forkServerELF
        (poolSize cfg)
        (injCapToInt (injectionCapability cfg))
        (codeRegionSize cfg)
        (ringBufSize cfg)
        sc
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

-- | Run action on a bound thread if -threaded, otherwise run directly.
inBoundThread :: IO a -> IO a
inBoundThread
  | rtsSupportsBoundThreads = runInBoundThread
  | otherwise               = id
