{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE UnboxedTuples #-}

module Hatchery.Internal.SpinWait
  ( spinWait
  ) where

import GHC.Exts (Word(..), Word#, Addr#)
import GHC.Word (Word32(..))
import Foreign.Ptr (Ptr)
import GHC.Ptr (Ptr(..))
import Language.Haskell.Inline.Cmm (verbatim, include)
import Hatchery.Internal.RingOffsets

include "\"Cmm.h\""

-- Uses hatchery_atomic_read32/write32 (seq_cst wrappers in direct_helpers.c)
-- for correct memory ordering. On x86, seq_cst load = MOV, seq_cst store = XCHG.
verbatim $ "\
\hatchery_spin_wait (W_ ring_base, W_ spin_count)\n\
\{\n\
\    W_ status_addr, i, st;\n\
\\n\
\    status_addr = ring_base + " ++ show ringStatusOff ++ ";\n\
\    i = 0;\n\
\\n\
\again:\n\
\    if (i >= spin_count) goto exhausted;\n\
\\n\
\    (st) = ccall hatchery_atomic_read32(status_addr);\n\
\    if (st == " ++ show workerDone ++ ") goto done;\n\
\    if (st == " ++ show workerCrashed ++ ") goto crashed;\n\
\\n\
\    i = i + 1;\n\
\    goto again;\n\
\\n\
\done:\n\
\    W_ ec;\n\
\    (ec) = ccall hatchery_atomic_read32(ring_base + " ++ show ringExitCodeOff ++ ");\n\
\\n\
\    ccall hatchery_release_write32(ring_base + " ++ show ringNotifyOff ++ ", 0);\n\
\    ccall hatchery_release_write32(status_addr, " ++ show workerReady ++ ");\n\
\\n\
\    return (0, ec);\n\
\\n\
\crashed:\n\
\    return (1, 0);\n\
\\n\
\exhausted:\n\
\    return (2, 0);\n\
\}\n"

foreign import prim "hatchery_spin_wait"
  hatchery_spin_wait# :: Addr# -> Word# -> (# Word#, Word# #)

-- | Spin on ring buffer status. Returns:
--   (0, exit_code) — worker completed
--   (1, _)         — worker crashed
--   (2, _)         — spins exhausted, caller should futex-wait and retry
spinWait :: Ptr () -> Word32 -> (Word, Word)
spinWait (Ptr addr) spinCount =
    let !(W# sc) = fromIntegral spinCount
        !(# tag, ec #) = hatchery_spin_wait# addr sc
    in (W# tag, W# ec)
