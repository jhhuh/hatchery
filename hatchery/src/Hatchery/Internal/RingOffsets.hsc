module Hatchery.Internal.RingOffsets
  ( -- * Ring buffer field offsets
    ringControlOff
  , ringNotifyOff
  , ringStatusOff
  , ringSpinModeOff
  , ringExitCodeOff
  , ringResultOffsetOff
  , ringResultSizeOff
  , ringDataOff
    -- * Worker status enum values
  , workerIdle
  , workerRun
  , workerReady
  , workerDone
  , workerCrashed
  ) where

#include "ring_buffer_layout.h"
#include <stddef.h>

ringControlOff, ringNotifyOff, ringStatusOff :: Int
ringControlOff = #{offset struct ring_buffer, control}
ringNotifyOff  = #{offset struct ring_buffer, notify}
ringStatusOff  = #{offset struct ring_buffer, status}

ringSpinModeOff, ringExitCodeOff :: Int
ringSpinModeOff  = #{offset struct ring_buffer, spin_mode}
ringExitCodeOff  = #{offset struct ring_buffer, exit_code}

ringResultOffsetOff, ringResultSizeOff, ringDataOff :: Int
ringResultOffsetOff = #{offset struct ring_buffer, result_offset}
ringResultSizeOff   = #{offset struct ring_buffer, result_size}
ringDataOff         = #{offset struct ring_buffer, data}

workerIdle, workerRun, workerReady, workerDone, workerCrashed :: Int
workerIdle    = #{const WORKER_IDLE}
workerRun     = #{const WORKER_RUN}
workerReady   = #{const WORKER_READY}
workerDone    = #{const WORKER_DONE}
workerCrashed = #{const WORKER_CRASHED}
