{-# LANGUAGE TemplateHaskell #-}

module Hatchery.Internal.Embedded (forkServerELF) where

import Data.ByteString (ByteString)
import Hatchery.Internal.Compile (compileForkServer)

-- | The fork server static-PIE ELF binary, compiled and embedded at compile time.
-- Uses $HATCHERY_CC (musl cross-compiler) to build from C sources in cbits/.
forkServerELF :: ByteString
forkServerELF = $(compileForkServer >>= \bs -> [| bs |])
