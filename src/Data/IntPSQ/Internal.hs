{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE UnboxedTuples #-}
module Data.IntPSQ.Internal
    ( -- * Type
      Nat
    , Key
    , Mask
    , IntPSQ (..)

      -- * Query
    , null
    , size
    , member
    , lookup
    , findMin

      -- * Construction
    , empty
    , singleton

      -- * Insertion
    , insert

      -- * Delete/update
    , delete
    , alter
    , alterMin

      -- * Lists
    , fromList
    , toList
    , keys

      -- * Views
    , insertView
    , deleteView
    , minView

      -- * Traversal
    , map
    , fold'

      -- * Unsafe manipulation
    , unsafeInsertNew
    , unsafeInsertLargerThanMaxPrio
    , unsafeInsertLargerThanMaxPrioView

      -- * Testing
    , valid
    , hasBadNils
    , hasDuplicateKeys
    , hasMinHeapProperty
    , validMask
    ) where

import           Control.DeepSeq (NFData(rnf))
import           Control.Applicative ((<$>), (<*>))

import           Data.BitUtil
import           Data.Bits
import           Data.List (foldl')
import           Data.Maybe (isJust)
import           Data.Word (Word)
import           Data.Foldable (Foldable (foldr))

import qualified Data.List as List

import           Prelude hiding (lookup, map, filter, foldr, foldl, null)

-- TODO (SM): get rid of bang patterns

{-
-- Use macros to define strictness of functions.
-- STRICT_x_OF_y denotes an y-ary function strict in the x-th parameter.
-- We do not use BangPatterns, because they are not in any standard and we
-- want the compilers to be compiled by as many compilers as possible.
#define STRICT_1_OF_2(fn) fn arg _ | arg `seq` False = undefined
-}


------------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------------

-- A "Nat" is a natural machine word (an unsigned Int)
type Nat = Word

type Key = Int


-- | We store masks as the index of the bit that determines the branching.
type Mask = Int

-- | A priority search queue with @Int@ keys and priorities of type @p@ and
-- values of type @v@. It is strict in keys, priorities and values.
data IntPSQ p v
    = Bin {-# UNPACK #-} !Key !p !v {-# UNPACK #-} !Mask !(IntPSQ p v) !(IntPSQ p v)
    | Tip {-# UNPACK #-} !Key !p !v
    | Nil
    deriving (Show)


-- instances
------------

instance (NFData p, NFData v) => NFData (IntPSQ p v) where
    rnf (Bin _k p v _m l r) = rnf p `seq` rnf v `seq` rnf l `seq` rnf r
    rnf (Tip _k p v)        = rnf p `seq` rnf v
    rnf Nil                 = ()

instance (Ord p, Eq v) => Eq (IntPSQ p v) where
    x == y = case (minView x, minView y) of
        (Nothing              , Nothing                ) -> True
        (Just (xk, xp, xv, x'), (Just (yk, yp, yv, y'))) ->
            xk == yk && xp == yp && xv == yv && x' == y'
        (Just _               , Nothing                ) -> False
        (Nothing              , Just _                 ) -> False

instance Foldable (IntPSQ p) where
    foldr _ z Nil               = z
    foldr f z (Tip _ _ v)       = f v z
    foldr f z (Bin _ _ v _ l r) = f v z''
      where
        z' = foldr f z l
        z'' = foldr f z' r

instance Functor (IntPSQ p) where
	fmap f = map (\_ _ v -> f v)


-- bit twiddling
----------------

{-# INLINE natFromInt #-}
natFromInt :: Key -> Nat
natFromInt = fromIntegral

{-# INLINE intFromNat #-}
intFromNat :: Nat -> Key
intFromNat = fromIntegral

{-# INLINE zero #-}
zero :: Key -> Mask -> Bool
zero i m
  = (natFromInt i) .&. (natFromInt m) == 0

{-# INLINE nomatch #-}
nomatch :: Key -> Key -> Mask -> Bool
nomatch k1 k2 m =
    natFromInt k1 .&. m' /= natFromInt k2 .&. m'
  where
    m' = maskW (natFromInt m)

{-# INLINE maskW #-}
maskW :: Nat -> Nat
maskW m = complement (m-1) `xor` m

{-# INLINE branchMask #-}
branchMask :: Key -> Key -> Mask
branchMask k1 k2 =
    intFromNat (highestBitMask (natFromInt k1 `xor` natFromInt k2))


------------------------------------------------------------------------------
-- Query
------------------------------------------------------------------------------

null :: IntPSQ p v -> Bool
null Nil = True
null _   = False

-- | /O(n)/. The number of elements stored in the PSQ.
size :: IntPSQ p v -> Int
size Nil               = 0
size (Tip _ _ _)       = 1
size (Bin _ _ _ _ l r) = 1 + size l + size r
-- TODO (SM): benchmark this against a tail-recursive variant

member :: Key -> IntPSQ p v -> Bool
member k = isJust . lookup k

lookup :: Key -> IntPSQ p v -> Maybe (p, v)
lookup k t = case t of
    Nil                -> Nothing

    Tip k' p' x'
      | k == k'        -> Just (p', x')
      | otherwise      -> Nothing

    Bin k' p' x' m l r
      | nomatch k k' m -> Nothing
      | k == k'        -> Just (p', x')
      | zero k m       -> lookup k l
      | otherwise      -> lookup k r

findMin :: Ord p => IntPSQ p v -> Maybe (Int, p, v)
findMin t = case minView t of
    Nothing           -> Nothing
    Just (k, p, v, _) -> Just (k, p, v)
    -- TODO (jaspervdj): More efficient implementations are possible.

------------------------------------------------------------------------------
--- Construction
------------------------------------------------------------------------------

empty :: IntPSQ p v
empty = Nil

singleton :: Ord p => Key -> p -> v -> IntPSQ p v
singleton = Tip

------------------------------------------------------------------------------
-- Insertion
------------------------------------------------------------------------------

-- | This variant of insert has the most consistent performance. It does at
-- most two root-to-leaf traversals, which are reallocating the nodes on their
-- path.
insert :: Ord p => Key -> p -> v -> IntPSQ p v -> IntPSQ p v
insert k p x t0 = unsafeInsertNew k p x (delete k t0)

-- | Internal function to insert a key that is *not* present in the priority
-- queue.
{-# INLINABLE unsafeInsertNew #-}
unsafeInsertNew :: Ord p => Key -> p -> v -> IntPSQ p v -> IntPSQ p v
unsafeInsertNew k p x t = case t of
  Nil       -> Tip k p x

  Tip k' p' x'
    | (p, k) < (p', k') -> link k  p  x  k' t           Nil
    | otherwise         -> link k' p' x' k  (Tip k p x) Nil

  Bin k' p' x' m l r
    | nomatch k k' m ->
        if (p, k) < (p', k')
          then link k  p  x  k' t           Nil
          else link k' p' x' k  (Tip k p x) (merge m l r)

    | otherwise ->
        if (p, k) < (p', k')
          then
            if zero k' m
              then Bin k  p  x  m (unsafeInsertNew k' p' x' l) r
              else Bin k  p  x  m l (unsafeInsertNew k' p' x' r)
          else
            if zero k m
              then Bin k' p' x' m (unsafeInsertNew k  p  x  l) r
              else Bin k' p' x' m l (unsafeInsertNew k  p  x  r)

-- | Link
link :: Key -> p -> v -> Key -> IntPSQ p v -> IntPSQ p v -> IntPSQ p v
link k p x k' k't otherTree
  | zero m k' = Bin k p x m k't       otherTree
  | otherwise = Bin k p x m otherTree k't
  where
    m = branchMask k k'


------------------------------------------------------------------------------
-- Delete/Alter
------------------------------------------------------------------------------

{-# INLINABLE delete #-}
delete :: Ord p => Key -> IntPSQ p v -> IntPSQ p v
delete k t = case t of
    Nil           -> Nil

    Tip k' _ _
      | k == k'   -> Nil
      | otherwise -> t

    Bin k' p' x' m l r
      | nomatch k k' m -> t
      | k == k'        -> merge m l r
      | zero k m       -> binShrinkL k' p' x' m (delete k l) r
      | otherwise      -> binShrinkR k' p' x' m l            (delete k r)

{-# INLINE alter #-}
alter
    :: Ord p
    => (Maybe (p, v) -> (b, Maybe (p, v)))
    -> Key
    -> IntPSQ p v
    -> (b, IntPSQ p v)
alter f = \k t0 ->
    let (t, mbX) = case deleteView k t0 of
                            Nothing          -> (t0, Nothing)
                            Just (p, v, t0') -> (t0', Just (p, v))
    in case f mbX of
          (b, mbX') ->
            (b, maybe t (\(p, v) -> unsafeInsertNew k p v t) mbX')

{-# INLINE alterMin #-}
alterMin :: Ord p
         => (Maybe (Key, p, v) -> (b, Maybe (Key, p, v)))
         -> IntPSQ p v
         -> (b, IntPSQ p v)
alterMin f t = case t of
    Nil             -> case f Nothing of
                         (b, Nothing)           -> (b, Nil)
                         (b, Just (k', p', x')) -> (b, Tip k' p' x')

    Tip k p x       -> case f (Just (k, p, x)) of
                         (b, Nothing)           -> (b, Nil)
                         (b, Just (k', p', x')) -> (b, Tip k' p' x')

    Bin k p x m l r -> case f (Just (k, p, x)) of
                         (b, Nothing)           -> (b, merge m l r)
                         (b, Just (k', p', x'))
                           | k  /= k'  -> (b, insert k' p' x' (merge m l r))
                           | p' <= p   -> (b, Bin k p' x' m l r)
                           | otherwise -> (b, unsafeInsertNew k p' x' (merge m l r))

-- | Smart constructor for a 'Bin' node whose left subtree could have become
-- 'Nil'.
{-# INLINE binShrinkL #-}
binShrinkL :: Key -> p -> v -> Mask -> IntPSQ p v -> IntPSQ p v -> IntPSQ p v
binShrinkL k p x m Nil r = case r of Nil -> Tip k p x; _ -> Bin k p x m Nil r
binShrinkL k p x m l   r = Bin k p x m l r

-- | Smart constructor for a 'Bin' node whose right subtree could have become
-- 'Nil'.
{-# INLINE binShrinkR #-}
binShrinkR :: Key -> p -> v -> Mask -> IntPSQ p v -> IntPSQ p v -> IntPSQ p v
binShrinkR k p x m l Nil = case l of Nil -> Tip k p x; _ -> Bin k p x m l Nil
binShrinkR k p x m l r   = Bin k p x m l r


------------------------------------------------------------------------------
-- Lists
------------------------------------------------------------------------------

{-# INLINABLE fromList #-}
fromList :: Ord p => [(Key, p, v)] -> IntPSQ p v
fromList = foldl' (\im (k, p, x) -> insert k p x im) empty

toList :: IntPSQ p v -> [(Int, p, v)]
toList =
    go []
  where
    go acc Nil                = acc
    go acc (Tip k' p' x')        = (k', p', x') : acc
    go acc (Bin k' p' x' _m l r) = (k', p', x') : go (go acc r) l

keys :: IntPSQ p v -> [Int]
keys t = [k | (k, _, _) <- toList t]
-- TODO (jaspervdj): More efficient implementations possible


------------------------------------------------------------------------------
-- Views
------------------------------------------------------------------------------

-- | Like insert, but returns the replaced element if any.
insertView :: Ord p => Key -> p -> v -> IntPSQ p v -> (Maybe (p, v), IntPSQ p v)
insertView k p x t0 = case deleteView k t0 of
  Nothing          -> (Nothing,       unsafeInsertNew k p x t0)
  Just (p', v', t) -> (Just (p', v'), unsafeInsertNew k p x t)

-- TODO (SM): verify that it is really worth do do deletion and lookup at the
-- same time.
{-# INLINABLE deleteView #-}
deleteView :: Ord p => Key -> IntPSQ p v -> Maybe (p, v, IntPSQ p v)
deleteView k t0 =
    case delFrom t0 of
      (# _, Nothing     #) -> Nothing
      (# t, Just (p, x) #) -> Just (p, x, t)
  where
    delFrom t = case t of
      Nil -> (# Nil, Nothing #)

      Tip k' p' x'
        | k == k'   -> (# Nil, Just (p', x') #)
        | otherwise -> (# t,   Nothing       #)

      Bin k' p' x' m l r
        | nomatch k k' m -> (# t, Nothing #)
        | k == k'   -> let t' = merge m l r
                       in  t' `seq` (# t', Just (p', x') #)

        | zero k m  -> case delFrom l of
                         (# l', mbPX #) -> let t' = binShrinkL k' p' x' m l' r
                                           in  t' `seq` (# t', mbPX #)

        | otherwise -> case delFrom r of
                         (# r', mbPX #) -> let t' = binShrinkR k' p' x' m l  r'
                                           in  t' `seq` (# t', mbPX #)

{-# INLINE minView #-}
minView :: Ord p => IntPSQ p v -> Maybe (Int, p, v, IntPSQ p v)
minView t = case t of
    Nil             -> Nothing
    Tip k p x       -> Just (k, p, x, Nil)
    Bin k p x m l r -> Just (k, p, x, merge m l r)


------------------------------------------------------------------------------
-- Traversal
------------------------------------------------------------------------------

{-# INLINABLE map #-}
map :: (Int -> p -> v -> w) -> IntPSQ p v -> IntPSQ p w
map f =
    go
  where
    go t = case t of
        Nil             -> Nil
        Tip k p x       -> Tip k p (f k p x)
        Bin k p x m l r -> Bin k p (f k p x) m (go l) (go r)

{-# INLINABLE fold' #-}
fold' :: (Int -> p -> v -> a -> a) -> a -> IntPSQ p v -> a
fold' f = go
  where
    go !acc Nil                   = acc
    go !acc (Tip k' p' x')        = f k' p' x' acc
    go !acc (Bin k' p' x' _m l r) =
        let !acc1 = f k' p' x' acc
            !acc2 = go acc1 l
            !acc3 = go acc2 r
        in acc3


-- | Internal function that merges two *disjoint* 'IntPSQ's that share the
-- same prefix mask.
{-# INLINABLE merge #-}
merge :: Ord p => Mask -> IntPSQ p v -> IntPSQ p v -> IntPSQ p v
merge m l r = case l of
    Nil -> r

    Tip lk lp lx ->
      case r of
        Nil                     -> l
        Tip rk rp rx
          | (lp, lk) < (rp, rk) -> Bin lk lp lx m Nil r
          | otherwise           -> Bin rk rp rx m l   Nil
        Bin rk rp rx rm rl rr
          | (lp, lk) < (rp, rk) -> Bin lk lp lx m Nil r
          | otherwise           -> Bin rk rp rx m l   (merge rm rl rr)

    Bin lk lp lx lm ll lr ->
      case r of
        Nil                     -> l
        Tip rk rp rx
          | (lp, lk) < (rp, rk) -> Bin lk lp lx m (merge lm ll lr) r
          | otherwise           -> Bin rk rp rx m l                Nil
        Bin rk rp rx rm rl rr
          | (lp, lk) < (rp, rk) -> Bin lk lp lx m (merge lm ll lr) r
          | otherwise           -> Bin rk rp rx m l                (merge rm rl rr)


------------------------------------------------------------------------------
-- Improved insert performance for special cases
------------------------------------------------------------------------------

-- TODO (SM): Make benchmarks run again, integrate this function with insert
-- and test how benchmarks times change.

-- | Internal function to insert a key with priority larger than the
-- maximal priority in the heap. This is always the case when using the PSQ
-- as the basis to implement a LRU cache, which associates a
-- access-tick-number with every element.
{-# INLINABLE unsafeInsertLargerThanMaxPrio #-}
unsafeInsertLargerThanMaxPrio
    :: Ord p => Key -> p -> v -> IntPSQ p v -> IntPSQ p v
unsafeInsertLargerThanMaxPrio =
    go
  where
    go k p x t = case t of
      Nil -> Tip k p x

      Tip k' p' x'
        | k == k'   -> Tip k p x
        | otherwise -> link k' p' x' k  (Tip k p x) Nil

      Bin k' p' x' m l r
        | nomatch k k' m -> link k' p' x' k (Tip k p x) (merge m l r)
        | k == k'        -> go k p x (merge m l r)
        | zero k m       -> Bin k' p' x' m (go k p x l) r
        | otherwise      -> Bin k' p' x' m l            (go k p x r)


{-# INLINABLE unsafeInsertLargerThanMaxPrioView #-}
unsafeInsertLargerThanMaxPrioView
    :: Ord p => Key -> p -> v -> IntPSQ p v -> (Maybe (p, v), IntPSQ p v)
unsafeInsertLargerThanMaxPrioView k0 p0 v0 t0 =
  case go k0 p0 v0 t0 of
    (# t, mbPX #) -> (mbPX, t)
  where
    go k p x t = case t of
     Nil -> (# Tip k p x, Nothing #)

     Tip k' p' x'
       | k == k'   -> (# Tip k p x,                        Just (p', x') #)
       | otherwise -> (# link k' p' x' k  (Tip k p x) Nil, Nothing #)

     Bin k' p' x' m l r
       | nomatch k k' m -> let t' = merge m l r
                           in t' `seq`
                             let t'' = link k' p' x' k (Tip k p x) t'
                             in t'' `seq` (# t'', Nothing #)

       | k == k'        -> let t' = merge m l r
                           in t' `seq` case go k p x t' of
                               (# t'', _ #) -> t'' `seq` (# t'', Just (p', x') #)

       | zero k m       -> case go k p x l of
                             (# l', mbPX #) -> l' `seq` (# Bin k' p' x' m l' r, mbPX #)

       | otherwise      -> case go k p x r of
                             (# r', mbPX #) -> r' `seq` (# Bin k' p' x' m l r', mbPX #)


------------------------------------------------------------------------------
-- Validity checks for the datastructure invariants
------------------------------------------------------------------------------


-- check validity of the data structure
valid :: Ord p => IntPSQ p v -> Bool
valid psq =
    not (hasBadNils psq) &&
    not (hasDuplicateKeys psq) &&
    hasMinHeapProperty psq &&
    validMask psq

hasBadNils :: IntPSQ p v -> Bool
hasBadNils psq = case psq of
    Nil                 -> False
    Tip _ _ _           -> False
    Bin _ _ _ _ Nil Nil -> True
    Bin _ _ _ _ l r     -> hasBadNils l || hasBadNils r

hasDuplicateKeys :: IntPSQ p v -> Bool
hasDuplicateKeys psq =
    any ((> 1) . length) (List.group . List.sort $ collectKeys [] psq)
  where
    collectKeys :: [Int] -> IntPSQ p v -> [Int]
    collectKeys ks Nil = ks
    collectKeys ks (Tip k _ _) = k : ks
    collectKeys ks (Bin k _ _ _ l r) =
        let ks' = collectKeys (k : ks) l
        in collectKeys ks' r

hasMinHeapProperty :: Ord p => IntPSQ p v -> Bool
hasMinHeapProperty psq = case psq of
    Nil             -> True
    Tip _ _ _       -> True
    Bin _ p _ _ l r -> go p l && go p r
  where
    go :: Ord p => p -> IntPSQ p v -> Bool
    go _ Nil = True
    go parentPrio (Tip _ prio _) = parentPrio <= prio
    go parentPrio (Bin _ prio _  _ l r) =
        parentPrio <= prio && go prio l && go prio r

data Side = L | R

validMask :: IntPSQ p v -> Bool
validMask Nil = True
validMask (Tip _ _ _) = True
validMask (Bin _ _ _ m left right ) =
    maskOk m left right && go m L left && go m R right
  where
    go :: Mask -> Side -> IntPSQ p v -> Bool
    go parentMask side psq = case psq of
        Nil -> True
        Tip k _ _ -> checkMaskAndSideMatchKey parentMask side k
        Bin k _ _ mask l r ->
            checkMaskAndSideMatchKey parentMask side k &&
            maskOk mask l r &&
            go mask L l &&
            go mask R r

    checkMaskAndSideMatchKey parentMask side key =
        case side of
            L -> parentMask .&. key == 0
            R -> parentMask .&. key == parentMask

    maskOk :: Mask -> IntPSQ p v -> IntPSQ p v -> Bool
    maskOk mask l r = case xor <$> childKey l <*> childKey r of
        Nothing -> True
        Just xoredKeys ->
            fromIntegral mask == highestBitMask (fromIntegral xoredKeys)

    childKey Nil = Nothing
    childKey (Tip k _ _) = Just k
    childKey (Bin k _ _ _ _ _) = Just k
