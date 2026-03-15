module TrustlessFFI.Marshal
  ( -- * Argument marshalling
    encodeInt32
  , decodeInt32
  , encodeInt64
  , decodeInt64
  , encodeByteString
  , decodeByteString
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Int
import Data.Word
import Data.Bits (shiftL, shiftR, (.&.))

-- | Encode an Int32 as 4 bytes (little-endian).
encodeInt32 :: Int32 -> ByteString
encodeInt32 n = BS.pack
  [ fromIntegral (n .&. 0xFF)
  , fromIntegral ((n `shiftR` 8) .&. 0xFF)
  , fromIntegral ((n `shiftR` 16) .&. 0xFF)
  , fromIntegral ((n `shiftR` 24) .&. 0xFF)
  ]

-- | Decode an Int32 from 4 bytes (little-endian).
decodeInt32 :: ByteString -> Maybe Int32
decodeInt32 bs
  | BS.length bs < 4 = Nothing
  | otherwise = Just $ fromIntegral b0
              + fromIntegral b1 `shiftL` 8
              + fromIntegral b2 `shiftL` 16
              + fromIntegral b3 `shiftL` 24
  where
    b0 = BS.index bs 0 :: Word8
    b1 = BS.index bs 1
    b2 = BS.index bs 2
    b3 = BS.index bs 3

-- | Encode an Int64 as 8 bytes (little-endian).
encodeInt64 :: Int64 -> ByteString
encodeInt64 n = BS.pack
  [ fromIntegral (n .&. 0xFF)
  , fromIntegral ((n `shiftR` 8) .&. 0xFF)
  , fromIntegral ((n `shiftR` 16) .&. 0xFF)
  , fromIntegral ((n `shiftR` 24) .&. 0xFF)
  , fromIntegral ((n `shiftR` 32) .&. 0xFF)
  , fromIntegral ((n `shiftR` 40) .&. 0xFF)
  , fromIntegral ((n `shiftR` 48) .&. 0xFF)
  , fromIntegral ((n `shiftR` 56) .&. 0xFF)
  ]

-- | Decode an Int64 from 8 bytes (little-endian).
decodeInt64 :: ByteString -> Maybe Int64
decodeInt64 bs
  | BS.length bs < 8 = Nothing
  | otherwise = Just $ fromIntegral b0
              + fromIntegral b1 `shiftL` 8
              + fromIntegral b2 `shiftL` 16
              + fromIntegral b3 `shiftL` 24
              + fromIntegral b4 `shiftL` 32
              + fromIntegral b5 `shiftL` 40
              + fromIntegral b6 `shiftL` 48
              + fromIntegral b7 `shiftL` 56
  where
    b0 = BS.index bs 0 :: Word8
    b1 = BS.index bs 1
    b2 = BS.index bs 2
    b3 = BS.index bs 3
    b4 = BS.index bs 4
    b5 = BS.index bs 5
    b6 = BS.index bs 6
    b7 = BS.index bs 7

-- | Encode a ByteString with a length prefix (4-byte LE length + data).
encodeByteString :: ByteString -> ByteString
encodeByteString bs = encodeInt32 (fromIntegral (BS.length bs)) <> bs

-- | Decode a length-prefixed ByteString. Returns (decoded, remaining).
decodeByteString :: ByteString -> Maybe (ByteString, ByteString)
decodeByteString bs = do
  len <- decodeInt32 bs
  let len' = fromIntegral len
      payload = BS.drop 4 bs
  if BS.length payload < len'
    then Nothing
    else Just (BS.take len' payload, BS.drop len' payload)
