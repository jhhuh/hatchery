module Main where

import Hatchery
import qualified Data.ByteString as BS
import System.CPUTime
import System.IO (hSetBuffering, stdout, BufferMode(..))
import Text.Printf (printf)
import PrimBaseline (primReturn42)

-- FFI baselines: same return42 function via different call conventions
foreign import ccall unsafe "return42" unsafeReturn42 :: IO Int
foreign import ccall safe   "return42" safeReturn42   :: IO Int

-- | Raw x86_64: mov eax, 42; ret
payload :: BS.ByteString
payload = BS.pack [0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3]

-- | Returns average time per call in nanoseconds.
timeN :: Int -> IO a -> IO Double
timeN n act = do
  start <- getCPUTime
  go n
  end <- getCPUTime
  return $ fromIntegral (end - start) / 1e3 / fromIntegral n
  where
    go 0 = return ()
    go i = act >> go (i - 1)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  let n = 100000

  putStrLn "=== return42 Dispatch Latency ==="
  putStrLn ""

  -- FFI baselines
  avgPrim <- timeN n primReturn42
  printf "  foreign import prim:  %8.1f ns/call  (%d calls)\n" avgPrim n

  avgUnsafe <- timeN n unsafeReturn42
  printf "  unsafe ccall:         %8.1f ns/call  (%d calls)\n" avgUnsafe n

  avgSafe <- timeN n safeReturn42
  printf "  safe ccall:           %8.1f ns/call  (%d calls)\n" avgSafe n

  -- Hatchery
  let hn = 100000

  -- One-shot dispatch (futex wake/wait)
  withHatchery defaultConfig { poolSize = 1 } $ \h -> do
    -- warmup
    mapM_ (\_ -> dispatch h UseSharedMemfd payload) [1..10 :: Int]

    avgDisp <- timeN hn (dispatch h UseSharedMemfd payload)
    printf "  hatchery (dispatch):  %8.1f ns/call  (%d calls)\n" avgDisp hn

  -- One-shot dispatch with spin-wait on Haskell side
  let spinDispCfg = defaultConfig { poolSize = 1, waitStrategy = SpinWait 10000 }
  withHatchery spinDispCfg $ \h -> do
    mapM_ (\_ -> dispatch h UseSharedMemfd payload) [1..10 :: Int]

    avgSpinDisp <- timeN hn (dispatch h UseSharedMemfd payload)
    printf "  hatchery (dispatch spin): %5.1f ns/call  (%d calls)\n" avgSpinDisp hn

  -- Pre-loaded payload (no re-injection)
  withHatchery defaultConfig { poolSize = 2 } $ \h -> do
    withPrepared h UseSharedMemfd payload $ \pw -> do
      -- warmup
      mapM_ (\_ -> run pw) [1..10 :: Int]

      avgRun <- timeN hn (run pw)
      printf "  hatchery (pre-loaded): %7.1f ns/call  (%d calls)\n" avgRun hn

  -- Spin-wait pre-loaded payload
  let spinCfg = defaultConfig { poolSize = 2, waitStrategy = SpinWait 10000 }
  withHatchery spinCfg $ \h -> do
    withPrepared h UseSharedMemfd payload $ \pw -> do
      -- warmup
      mapM_ (\_ -> run pw) [1..10 :: Int]

      avgSpin <- timeN hn (run pw)
      printf "  hatchery (spin-wait):  %7.1f ns/call  (%d calls)\n" avgSpin hn

  -- Spin-wait C (unsafe ccall, GCC-inlined atomics)
  let spinCCfg = defaultConfig { poolSize = 2, waitStrategy = SpinWaitC 10000 }
  withHatchery spinCCfg $ \h -> do
    withPrepared h UseSharedMemfd payload $ \pw -> do
      mapM_ (\_ -> run pw) [1..10 :: Int]

      avgSpinC <- timeN hn (run pw)
      printf "  hatchery (spin-C):     %7.1f ns/call  (%d calls)\n" avgSpinC hn

  -- Fault tolerance demo
  putStrLn ""
  putStrLn "=== Fault Tolerance ==="
  let crashPayload = BS.pack [0x0f, 0x0b]  -- ud2
  withHatchery defaultConfig { poolSize = 1 } $ \h -> do
    putStr "  Dispatching crashing code... "
    result <- dispatch h UseSharedMemfd crashPayload
    case result of
      Crashed sig -> putStrLn $ "caught crash (signal " ++ show sig ++ "), host unaffected"
      Completed _ _ -> putStrLn "unexpected: did not crash"
