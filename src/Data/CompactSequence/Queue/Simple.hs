{-# language DeriveTraversable #-}
{-# language ScopedTypeVariables #-}
{-# language BangPatterns #-}
{-# language MagicHash #-}
{-# language UnboxedTuples #-}
{-# language DataKinds #-}
{-# language PatternSynonyms #-}
{-# language ViewPatterns #-}
{-# language Trustworthy #-}
{-# language TypeFamilies #-}
-- {-# OPTIONS_GHC -Wall #-}

{- |
Space-efficient queues with amortized \( O(\log n) \) operations.  These
directly use an underlying array-based implementation, without doing any
special optimization for the first few and last few elements of the queue.
-}

module Data.CompactSequence.Queue.Simple
  ( Queue (Empty, (:<))
  , (|>)
  , empty
  , snoc
  , uncons
  , fromList
  , fromListN
  ) where

import qualified Data.CompactSequence.Queue.Internal as Q
import qualified Data.CompactSequence.Internal.Array as A
import qualified Data.Foldable as F
import qualified GHC.Exts as Exts
import Control.Monad.Trans.State.Strict

newtype Queue a = Queue (Q.Queue 'A.Mul1 a)
  deriving (Functor, Traversable, Eq, Ord)

empty :: Queue a
empty = Queue Q.empty

snoc :: Queue a -> a -> Queue a
snoc (Queue q) a = Queue $ Q.snocA A.one q (A.singleton a)

(|>) :: Queue a -> a -> Queue a
(|>) = snoc

uncons :: Queue a -> Maybe (a, Queue a)
uncons (Queue q) = case Q.viewA A.one q of
  Q.EmptyA -> Nothing
  Q.ConsA sa q'
    | (# a #) <- A.getSingleton# sa
    -> Just (a, Queue q')

infixr 4 :<
infixl 4 `snoc`

pattern (:<) :: a -> Queue a -> Queue a
pattern x :< xs <- (uncons -> Just (x, xs))

pattern Empty :: Queue a
pattern Empty = Queue Q.Empty
{-# COMPLETE (:<), Empty #-}

instance Foldable Queue where
  -- TODO: Implement more methods.
  foldMap f (Queue q) = foldMap f q
  foldr c n (Queue q) = foldr c n q
  foldl' f b (Queue q) = F.foldl' f b q
  -- Note: length only does O(log n) *unshared* work, but it does O(n) amortized
  -- work because it has to force the entire spine. We could avoid
  -- this, of course, by storing the size with the queue.
  length (Queue q) = go 0 A.one q
    where
      go :: Int -> A.Size m -> Q.Queue m a -> Int
      go !acc !_s Q.Empty = acc
      go !acc !s (Q.Node pr m sf) = go (acc + lpr + lsf) (A.twice s) m
        where
          lpr = case pr of
                  Q.FD1{} -> A.getSize s
                  Q.FD2{} -> 2*A.getSize s
                  Q.FD3{} -> 3*A.getSize s
          lsf = case sf of
                  Q.RD0 -> 0
                  Q.RD1{} -> A.getSize s
                  Q.RD2{} -> 2*A.getSize s

instance Show a => Show (Queue a) where
    showsPrec p xs = showParen (p > 10) $
        showString "fromList " . shows (F.toList xs)

instance Exts.IsList (Queue a) where
  type Item (Queue a) = a
  toList = F.toList
  fromList = fromList
  fromListN = fromListN

instance Semigroup (Queue a) where
  -- This gives us O(m + n) append, which I believe is the best we can do in
  -- general.
  --
  -- TODO: detect when the second queue is short enough that it's better to
  -- just insert all its elements into the first queue. This happens around
  -- when n log m < k (m + n), but finding the appropriate k requires
  -- benchmarking. Can we make that decision without fully calculating
  -- m or log m (using successive lower bounds)?
  Empty <> q = q
  q <> Empty = q
  q <> r = fromListN (length q + length r) (F.toList q ++ F.toList r)

instance Monoid (Queue a) where
  mempty = empty

-- | \( O(n \log n) \). Convert a list to a 'Queue', with the head of the
-- list at the front of the queue.
fromList :: [a] -> Queue a
fromList = F.foldl' snoc empty

-- | \( O(n) \). Convert a list of the given size to a 'Queue', with the
-- head of the list at the front of the queue.
fromListN :: Int -> [a] -> Queue a
fromListN n xs
  | (q,[]) <- runState (fromListQN A.one (intToQueueNum n)) xs
  = Queue q
  | otherwise
  = error "Data.CompactSequence.Queue.fromListN: list too long"

-- We use a similar approach to the one we use for stacks.  We should be able
-- to speed up the calculation of the QueueNum, perhaps even reducing its order
-- of growth, but this is sufficient to get linear-time conversion. Every node
-- of the resulting queue will be safe, except possibly the last one. This
-- should make the resulting queue cheap to work with initially.

data QueueNum
  = EmptyNum
  | NodeNum !FNum !QueueNum !RNum
data FNum = FN1 | FN2 | FN3
data RNum = RN0 | RN1 | RN2

fromListQN :: A.Size n -> QueueNum -> State [a] (Q.Queue n a)
fromListQN !_ EmptyNum = pure Q.empty
fromListQN !n (NodeNum prn mn sfn)
  = case prn of
      FN1 -> do
        sa <- state (A.arraySplitListN n)
        m  <- fromListQN (A.twice n) mn
        sf <- fromListRearQN n sfn
        pure (Q.Node (Q.FD1 sa) m sf)
      FN2 -> do
        sa1 <- state (A.arraySplitListN n)
        sa2 <- state (A.arraySplitListN n)
        m  <- fromListQN (A.twice n) mn
        sf <- fromListRearQN n sfn
        pure (Q.Node (Q.FD2 sa1 sa2) m sf)
      FN3 -> do
        sa1 <- state (A.arraySplitListN n)
        sa2 <- state (A.arraySplitListN n)
        sa3 <- state (A.arraySplitListN n)
        m  <- fromListQN (A.twice n) mn
        sf <- fromListRearQN n sfn
        pure (Q.Node (Q.FD3 sa1 sa2 sa3) m sf)
               
fromListRearQN :: A.Size n -> RNum -> State [a] (Q.RD n a)
fromListRearQN !_ RN0 = pure Q.RD0
fromListRearQN !n RN1 = do
    sa <- state (A.arraySplitListN n)
    pure (Q.RD1 sa)
fromListRearQN !n RN2 = do
    sa1 <- state (A.arraySplitListN n)
    sa2 <- state (A.arraySplitListN n)
    pure (Q.RD2 sa1 sa2)

intToQueueNum :: Int -> QueueNum
intToQueueNum = go EmptyNum
  where
    go !qn 0 = qn
    go !qn n = go (incQueueNum qn) (n - 1)

-- Note: this is not structured at all like `snoc`, because it makes no
-- semantic difference whether an increment occurs at the front or at the rear.
-- We ensure that every node is safe, except possibly the last one. We also
-- lean toward placing elements in the front.
incQueueNum :: QueueNum -> QueueNum
incQueueNum EmptyNum = NodeNum FN1 EmptyNum RN0
incQueueNum (NodeNum FN1 m sf) = NodeNum FN2 m sf
incQueueNum (NodeNum FN2 m sf) = NodeNum FN3 m sf
incQueueNum (NodeNum FN3 m RN0) = NodeNum FN3 m RN1
incQueueNum (NodeNum FN3 m RN1) = NodeNum FN3 (incQueueNum m) RN0
-- The last case is never used by intToQueueNum, because
-- incQueueNum never produces RN2 if it's not given it.
incQueueNum (NodeNum FN3 m RN2) = NodeNum FN3 (incQueueNum m) RN1
