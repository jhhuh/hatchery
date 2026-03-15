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

include "\"Cmm.h\""

-- Ring buffer offsets (must match ring_buffer.h / direct_helpers.c):
--   control:    0     (cache line 0)
--   notify:    64     (cache line 1)
--   status:   128     (cache line 2)
--   exit_code: 216

-- Worker status values:
--   WORKER_READY   = 1
--   WORKER_DONE    = 3
--   WORKER_CRASHED = 4

-- On x86_64, all loads are naturally acquire and all stores are
-- naturally release (TSO). Plain bits32 loads/stores are correct.
-- For ARM, this would need %acquire/%release with W_ and masking.
verbatim "\
\hatchery_spin_wait (W_ ring_base, W_ spin_count)\n\
\{\n\
\    W_ status_addr, i, st;\n\
\\n\
\    status_addr = ring_base + 128;\n\
\    i = 0;\n\
\\n\
\again:\n\
\    if (i >= spin_count) goto exhausted;\n\
\\n\
\    st = bits32[status_addr];\n\
\    if (st == 3) goto done;\n\
\    if (st == 4) goto crashed;\n\
\\n\
\    i = i + 1;\n\
\    goto again;\n\
\\n\
\done:\n\
\    W_ ec;\n\
\    ec = bits32[ring_base + 216];\n\
\\n\
\    bits32[ring_base + 64] = 0;\n\
\    bits32[status_addr] = 1;\n\
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
