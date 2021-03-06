{-# LANGUAGE BangPatterns #-}

module Data.HashPSQ.Benchmark
    ( benchmark
    ) where

import           Data.List (foldl')
import qualified Data.HashPSQ as HashPSQ
import           Criterion.Main
import           Prelude hiding (lookup)
import           BenchmarkTypes

benchmark :: String -> [BElem] -> BenchmarkSet
benchmark name elems = BenchmarkSet
    { bGroupName        = name
    , bMinView          = whnf bench_minView              initialPSQ
    , bLookup           = whnf (bench_lookup keys)        initialPSQ
    , bInsertEmpty      = nf   (bench_insert firstElems)  HashPSQ.empty
    , bInsertNew        = nf   (bench_insert secondElems) initialPSQ
    , bInsertDuplicates = nf   (bench_insert firstElems)  initialPSQ
    , bDelete           = nf   (bench_delete firstKeys)   initialPSQ
    }
  where
    (firstElems, secondElems) = splitAt (numElems `div` 2) elems
    numElems  = length elems
    keys      = map (\(x, _, _) -> x) elems
    firstKeys = map (\(x, _, _) -> x) firstElems

    initialPSQ = HashPSQ.fromList firstElems :: HashPSQ.HashPSQ Int Int ()


-- Get the sum of all priorities by getting all elements using 'lookup'
bench_lookup :: [Int] -> HashPSQ.HashPSQ Int Int () -> Int
bench_lookup xs m = foldl' (\n k -> maybe n fst (HashPSQ.lookup k m)) 0 xs

-- Insert a list of elements one-by-one into a PSQ
bench_insert
    :: [BElem] -> HashPSQ.HashPSQ Int Int () -> HashPSQ.HashPSQ Int Int ()
bench_insert xs m0 = foldl' (\m (k, p, v) -> HashPSQ.insert k p v m) m0 xs

-- Get the sum of all priorities by sequentially popping all elements using
-- 'minView'
bench_minView :: HashPSQ.HashPSQ Int Int () -> Int
bench_minView = go 0
  where
    go !n t = case HashPSQ.minView t of
      Nothing             -> n
      Just (k, x, _,  t') -> go (n + k + x) t'

-- Empty a queue by sequentially removing all elements
bench_delete
    :: [Int] -> HashPSQ.HashPSQ Int Int () -> HashPSQ.HashPSQ Int Int ()
bench_delete keys t0 = foldl' (\t k -> HashPSQ.delete k t) t0 keys
