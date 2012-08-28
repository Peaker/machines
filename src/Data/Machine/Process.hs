{-# LANGUAGE GADTs #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleInstances #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Machine.Process
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  Rank 2 Types, GADTs
--
----------------------------------------------------------------------------
module Data.Machine.Process
  (
  -- * Processes
    Process
  , ProcessT
  , Automaton(..)
  , process
  -- ** Common Processes
  , after
  , supply
  , prepended
  , filtered
  , dropping
  , taking
  , droppingWhile
  , takingWhile
  , buffered
  ) where

import Control.Applicative
import Control.Category
import Control.Monad (liftM, when, replicateM_)
import Data.Foldable
import Data.Machine.Is
import Data.Machine.Plan
import Data.Machine.Type
import Prelude hiding ((.),id)

-------------------------------------------------------------------------------
-- Processes
-------------------------------------------------------------------------------

-- | A @'Process' a b@ is a stream transducer that can consume values of type @a@
-- from its input, and produce values of type @b@ for its output.
type Process a b = Machine Is a b

-- | A @'ProcessT' m a b@ is a stream transducer that can consume values of type @a@
-- from its input, and produce values of type @b@ and has side-effects in the
-- 'Monad' @m@.
type ProcessT m a b = MachineT m Is a b

-- | An 'Automaton' is can be automatically lifted into a 'Process'
class Automaton k where
  auto :: k a b -> Process a b

instance Automaton (->) where
  auto f = repeatedly $ do
    i <- await
    yield (f i)

instance Automaton Is where
  auto Refl = repeatedly $ do
    i <- await
    yield i

-- | A 'Process' that prepends the elements of a 'Foldable' onto its input, then repeats its input from there.
prepended :: Foldable f => f a -> Process a a
prepended = before id . traverse_ yield

-- | A 'Process' that only passes through inputs that match a predicate.
filtered :: (a -> Bool) -> Process a a
filtered p = repeatedly $ do
  i <- await
  when (p i) $ yield i

-- | A 'Process' that drops the first @n@, then repeats the rest.
dropping :: Int -> Process a a
dropping n = before id $ replicateM_ n await

-- | A 'Process' that passes through the first @n@ elements from its input then stops
taking :: Int -> Process a a
taking n = construct . replicateM_ n $ await >>= yield

-- | A 'Process' that passes through elements until a predicate ceases to hold, then stops
takingWhile :: (a -> Bool) -> Process a a
takingWhile p = repeatedly $ await >>= \v -> if p v then yield v else stop

-- | A 'Process' that drops elements while a predicate holds
droppingWhile :: (a -> Bool) -> Process a a
droppingWhile p = before id loop where
  loop = await >>= \v -> if p v then loop else yield v

-- | Chunk up the input into `n` element lists.
--
-- Avoids returning empty lists and deals with the truncation of the last group.
buffered :: Int -> Process a [a]
buffered = repeatedly . go [] where
  go [] 0  = stop
  go acc 0 = yield (reverse acc)
  go acc n = do
    i <- await <|> yield (reverse acc) *> stop
    go (i:acc) $! n-1

-- | Build a new 'Machine' by adding a 'Process' to the output of an old 'Machine'
--
-- @
-- after :: 'Process' a b   -> 'Process' b c -> 'Process' a c
-- after :: 'Data.Machine.Tee.Tee' a b c     -> 'Process' c d -> 'Data.Machine.Tee.Tee' a b d
-- after :: 'Machine' k a b -> 'Process' b c -> 'Machine' k a c
-- @
after :: Monad m => MachineT m k a b -> ProcessT m b c -> MachineT m k a c
after ma mp = MachineT $ runMachineT mp >>= \v -> case v of
  Stop          -> return Stop
  Yield o k     -> return $ Yield o (after ma k)
  Await f Refl ff -> runMachineT ma >>= \u -> case u of
    Stop          -> runMachineT $ after stopped ff
    Yield o k     -> runMachineT . after k $ f o
    Await g kg fg -> let mv = MachineT (return v) in
      return $ Await (\a -> after (g a) mv) kg (after fg mv)

-- | Feed a 'Process' some input.
supply :: Monad m => [a] -> ProcessT m a b -> ProcessT m a b
supply []         m = m
supply xxs@(x:xs) m = MachineT $ runMachineT m >>= \v -> case v of
  Stop -> return Stop
  Await f Refl _ -> runMachineT $ supply xs (f x)
  Yield o k -> return $ Yield o (supply xxs k)

-- |
-- Convert a machine into a process, with a little bit of help.
--
-- @'process' 'id' = 'id'@
--
-- @
-- 'process' 'Data.Machine.Tee.L' :: 'Data.Machine.Process.Process' a c -> 'Data.Machine.Tee.Tee' a b c
-- 'process' 'Data.Machine.Tee.R' :: 'Data.Machine.Process.Process' b c -> 'Data.Machine.Tee.Tee' a b c
-- 'process' 'id' :: 'Data.Machine.Process.Process' a b -> 'Data.Machine.Process.Process' a b
-- @
process :: Monad m => (forall a. k i a -> i' -> a) -> MachineT m k i o -> ProcessT m i' o
process f (MachineT m) = MachineT (liftM f' m) where
  f' (Yield o k)     = Yield o (process f k)
  f' Stop            = Stop
  f' (Await g kir h) = Await (process f . g . f kir) Refl (process f h)

