{-# LANGUAGE LambdaCase #-}

module Hatchery.Internal.Compile (compileForkServer) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Language.Haskell.TH (Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Process (readProcessWithExitCode)
import System.Directory (makeAbsolute)

-- | Compile the fork server at TH time using $HATCHERY_CC.
compileForkServer :: Q ByteString
compileForkServer = do
  cc <- runIO (lookupEnv "HATCHERY_CC") >>= \case
    Just cc -> return cc
    Nothing -> fail $ unlines
      [ "HATCHERY_CC environment variable not set."
      , "Set it to the musl cross-compiler path, e.g.:"
      , "  export HATCHERY_CC=x86_64-unknown-linux-musl-gcc"
      ]

  -- Register source dependencies so GHC recompiles when they change
  let sources = [ "cbits/fork_server.c"
                , "cbits/seccomp_filter.c"
                , "cbits/syscall.h"
                , "cbits/ring_buffer.h"
                , "cbits/protocol.h"
                , "cbits/seccomp_filter.h"
                ]
  mapM_ addDependentFile sources

  -- Compile to a temp file
  runIO $ do
    tmp <- makeAbsolute "cbits/fork_server.tmp"
    let args = [ "-static-pie", "-nostartfiles", "-fPIE", "-Os"
               , "-Wall", "-Werror"
               , "-o", tmp
               , "cbits/fork_server.c", "cbits/seccomp_filter.c"
               ]
    (code, _stdout, stderr) <- readProcessWithExitCode cc args ""
    case code of
      ExitSuccess -> BS.readFile tmp
      ExitFailure _ -> fail $ "HATCHERY_CC compilation failed:\n"
                            ++ "  " ++ cc ++ " " ++ unwords args ++ "\n"
                            ++ stderr
