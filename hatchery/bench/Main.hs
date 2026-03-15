module Main where

import Hatchery
import qualified Data.ByteString as BS
import System.CPUTime
import Text.Printf (printf)
import System.IO (hSetBuffering, stdout, BufferMode(..))

-- | Raw x86_64: mov eax, 42; ret
payload :: BS.ByteString
payload = BS.pack [0xb8, 0x2a, 0x00, 0x00, 0x00, 0xc3]

timeAction :: IO a -> IO (a, Double)
timeAction act = do
  start <- getCPUTime
  r <- act
  end <- getCPUTime
  let usec = fromIntegral (end - start) / 1e6 :: Double
  return (r, usec)

main :: IO ()
main = do
  putStrLn "=== Hatchery Dispatch Latency Benchmark ==="
  putStrLn ""

  withHatchery defaultConfig { poolSize = 1 } $ \h -> do
    -- Warmup
    putStrLn "Warmup (10 dispatches)..."
    mapM_ (\_ -> dispatch h UseSharedMemfd payload) [1..10 :: Int]

    -- Benchmark: SharedMemfd
    putStrLn ""
    putStrLn "--- UseSharedMemfd ---"
    benchMethod h UseSharedMemfd

    -- Benchmark: ProcessVmWritev
    putStrLn ""
    putStrLn "--- UseProcessVmWritev ---"
    benchMethod h UseProcessVmWritev

  -- Fault tolerance: dispatch code that segfaults
  putStrLn ""
  putStrLn "=== Fault Tolerance ==="
  -- ud2 instruction (raises SIGILL)
  let crashPayload = BS.pack [0x0f, 0x0b]
  withHatchery defaultConfig { poolSize = 1 } $ \h -> do
    putStr "Dispatching crashing code... "
    result <- dispatch h UseSharedMemfd crashPayload
    case result of
      Crashed sig -> putStrLn $ "caught crash (signal " ++ show sig ++ "), host unaffected"
      Completed _ _ -> putStrLn "unexpected: did not crash"

benchMethod :: Hatchery -> InjectionMethod -> IO ()
benchMethod h method = do
  let n = 1000
  (_, totalUs) <- timeAction $
    mapM_ (\_ -> dispatch h method payload) [1..n :: Int]
  let avgUs = totalUs / fromIntegral n
  printf "  %d dispatches in %.1f us (%.2f us/dispatch avg)\n" n totalUs avgUs
