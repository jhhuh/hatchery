{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE UnboxedTuples #-}

module PrimBaseline (primReturn42) where

import GHC.Exts (Int#, Int(..), Word#, State#, RealWorld)
import GHC.IO (IO(..))
import Language.Haskell.Inline.Cmm (verbatim, include)

include "\"Cmm.h\""

verbatim "\
\prim_return42 (W_ dummy)\n\
\{\n\
\    return (42);\n\
\}\n"

foreign import prim "prim_return42"
  prim_return42# :: Word# -> Int#

primReturn42 :: IO Int
primReturn42 = IO $ \s -> (# s, I# (prim_return42# 0##) #)
