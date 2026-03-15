module Main where

import Hatchery
import qualified Data.ByteString as BS
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  payload <- BS.readFile "test-payloads/return42.bin"
  putStrLn $ "Payload size: " ++ show (BS.length payload) ++ " bytes"

  withHatchery defaultConfig { poolSize = 1 } $ \h -> do
    -- Test 1: Dispatch via process_vm_writev
    putStrLn "Test 1: dispatch via UseProcessVmWritev..."
    result1 <- dispatch h UseProcessVmWritev payload
    case result1 of
      Completed code _ -> do
        putStrLn $ "  exit_code = " ++ show code
        if code == 42
          then putStrLn "  PASS"
          else do putStrLn "  FAIL: expected 42"; exitFailure
      Crashed sig -> do
        putStrLn $ "  FAIL: worker crashed with signal " ++ show sig
        exitFailure

    -- Test 2: Dispatch via shared memfd
    putStrLn "Test 2: dispatch via UseSharedMemfd..."
    result2 <- dispatch h UseSharedMemfd payload
    case result2 of
      Completed code _ -> do
        putStrLn $ "  exit_code = " ++ show code
        if code == 42
          then putStrLn "  PASS"
          else do putStrLn "  FAIL: expected 42"; exitFailure
      Crashed sig -> do
        putStrLn $ "  FAIL: worker crashed with signal " ++ show sig
        exitFailure

  putStrLn "All tests passed!"
  exitSuccess
