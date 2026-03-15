module Hatchery.LLVM
  ( compileModule
  , CompileError(..)
  ) where

import Data.ByteString (ByteString)
import Control.Exception (Exception, throwIO)

-- | Errors during LLVM compilation.
data CompileError = CompileError String
  deriving (Show)

instance Exception CompileError

-- | Compile an LLVM module to raw x86_64 machine code.
--
-- The returned ByteString contains position-independent machine code
-- suitable for injection into a hatchery worker's code region.
--
-- TODO: Implementation requires using LLVM's TargetMachine to emit
-- object code, then extracting the .text section. The llvm-tf package
-- may need extensions for this, or we call LLVM C API directly.
compileModule :: ByteString -> IO ByteString
compileModule _ = throwIO $ CompileError "LLVM compilation not yet implemented — Phase 1 stub"
