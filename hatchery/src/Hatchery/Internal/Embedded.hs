{-# LANGUAGE TemplateHaskell #-}

module Hatchery.Internal.Embedded (forkServerELF) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)

-- | The fork server static-PIE ELF binary, embedded at compile time.
forkServerELF :: ByteString
forkServerELF = $(embedFile "cbits/fork_server")
