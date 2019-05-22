
{- useful functions for using the simulator -}

module Simulator.Lib where

import HaskellTarget as H

import Simulator.Print
import Simulator.Util
import Simulator.Value

import qualified Data.Text as T
import qualified Data.BitVector as BV

import Data.List (find)
import Data.Maybe (catMaybes)
import System.Environment (getArgs)

-- unit val
tt :: Val
tt = BVVal BV.nil

getArgVal :: String -> Int -> IO Val
getArgVal name n = do
    args <- getArgs

    let ps = catMaybes $ map (binary_split ':') args

    case find (\(x,y) -> x == name) ps of
        Just (_,y) -> return $ BVVal $ hex_to_bv n $ T.pack y
        Nothing -> error $ "Argument value " ++ name ++ " not supplied."

ppr_bin :: Kind -> Val -> String
ppr_bin k = printVal $ H.fullFormatBinary k

ppr_hex :: Kind -> Val -> String
ppr_hex k = printVal $ H.fullFormatHex k

ppr_dec :: Kind -> Val -> String
ppr_dec k = printVal $ H.fullFormatDecimal k