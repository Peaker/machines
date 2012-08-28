{-# LANGUAGE GADTs #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleInstances #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Machine.Type
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  rank-2, GADTs
--
----------------------------------------------------------------------------
module Data.Machine.Type
  (
  -- * Machines
    MachineT(..)
  , Step(..)
  , Machine
  , runT_
  , runT
  , run
  , runMachine
  , encased

  -- ** Building machines from plans
  , construct
  , repeatedly
  , before
--  , sink

  -- * Reshaping machines
  , fit
  , pass

  , stopped
  ) where

import Control.Applicative
import Control.Category
import Control.Monad (liftM)
import Data.Foldable
import Data.Functor.Identity
import Data.Machine.Is
import Data.Machine.Plan
import Data.Monoid
import Data.Profunctor
import Prelude hiding ((.),id)

-------------------------------------------------------------------------------
-- Transduction Machines
-------------------------------------------------------------------------------

-- | This is the base functor for a 'Machine' or 'MachineT'.
--
-- Note: Machines are usually constructed from 'Plan', so this does not need to be CPS'd.
data Step k i o r
  = Stop
  | Yield o r
  | forall t. Await (t -> r) (k i t) r

instance Functor (Step k i o) where
  fmap _ Stop = Stop
  fmap f (Yield o k) = Yield o (f k)
  fmap f (Await g kg fg) = Await (f . g) kg (f fg)

-- | A 'MachineT' reads from a number of inputs and may yield results before stopping
-- with monadic side-effects.
newtype MachineT m k i o = MachineT { runMachineT :: m (Step k i o (MachineT m k i o)) }

-- | A 'Machine' reads from a number of inputs and may yield results before stopping.
--
-- A 'Machine' can be used as a @'MachineT' m@ for any @'Monad' m@.
type Machine k i o = forall m. Monad m => MachineT m k i o

-- | @'runMachine' = 'runIdentity' . 'runMachineT'@
runMachine :: MachineT Identity k i o -> Step k i o (MachineT Identity k i o)
runMachine = runIdentity . runMachineT

-- | Pack a Step of a Machine into a Machine.
encased :: Monad m => Step k i o (MachineT m k i o) -> MachineT m k i o
encased = MachineT . return

instance Monad m => Functor (MachineT m k i) where
  fmap f (MachineT m) = MachineT (liftM f' m) where
    f' (Yield o xs)    = Yield (f o) (f <$> xs)
    f' (Await k kir e) = Await (fmap f . k) kir (f <$> e)
    f' Stop            = Stop

{-
apMachines :: Maybe (Seq i) -> Seq a -> MachineT m k i (a -> b) -> MachineT m k i a -> MachineT m k i b
apMachines is as m n = MachineT $ runMachineT m >>= \u -> case u of
  Stop -> return Stop
  Yield f m' -> case viewl as of
    a :< as' -> return $ Yield (f a) (apMachines is as' m' n)
    EmptyL   -> paMachines is (Seq.singleton f) m' n
  Await k Refl kf -> case is of
    Nothing ->

paMachines :: Maybe (Seq i) -> Seq (a -> b) -> MachineT m k i (a -> b) -> MachineT m k i a -> MachineT m k i b
paMachines is fs m n = MachineT $ runMachineT n >>= \v -> case v of
  Stop -> return Stop
  Yield a n' -> case viewl fs of
    f :< fs' -> return $ Yield (f a) (paMachines is fs' m n')
    EmptyL   -> apMachines is (Seq.singleton a) m n'

instance (k ~ Is, Monad m) => Applicative (MachineT m k i) where
  pure = repeatedly . yield
  m <*>  n = runMachineT m >>= \u -> case u of
    Stop       -> return stopped
    Yield f xs ->
    Await f Refl ff ->
-}

instance (Monad m, Profunctor k) => Profunctor (MachineT m k) where
  rmap = fmap
  lmap f (MachineT m) = MachineT (liftM f' m) where
    f' (Yield o xs)    = Yield o (lmap f xs)
    f' (Await k kir e) = Await (lmap f . k) (lmap f kir) (lmap f e)
    f' Stop            = Stop

-- | Stop feeding input into model, taking only the effects.
runT_ :: Monad m => MachineT m k a b -> m ()
runT_ (MachineT m) = m >>= \v -> case v of
  Stop        -> return ()
  Yield _ k   -> runT_ k
  Await _ _ e -> runT_ e

-- | Stop feeding input into model and extract an answer
runT :: Monad m => MachineT m k a b -> m [b]
runT (MachineT m) = m >>= \v -> case v of
  Stop        -> return []
  Yield o k   -> liftM (o:) (runT k)
  Await _ _ e -> runT e

-- | Run a pure machine and extract an answer.
run :: MachineT Identity k a b -> [b]
run = runIdentity . runT

-- | This permits toList to be used on a Machine.
instance (m ~ Identity) => Foldable (MachineT m k i) where
  foldMap f (MachineT (Identity m)) = go m where
    go Stop = mempty
    go (Yield o k) = f o `mappend` foldMap f k
    go (Await _ _ fg) = foldMap f fg

-- |
-- Connect different kinds of machines.
--
-- @'fit' 'id' = 'id'@
--
-- @
-- 'fit' 'id' :: 'Data.Machine.Process.Process' a b -> 'Data.Machine.Process.Process' a b
-- @
fit :: Monad m => (forall a. k i a -> k' i' a) -> MachineT m k i o -> MachineT m k' i' o
fit f (MachineT m) = MachineT (liftM f' m) where
  f' (Yield o k)     = Yield o (fit f k)
  f' Stop            = Stop
  f' (Await g kir h) = Await (fit f . g) (f kir) (fit f h)

-- | Compile a machine to a model.
construct :: Monad m => PlanT k i o m a -> MachineT m k i o
construct m = MachineT $ runPlanT m
  (const (return Stop))
  (\o k -> return (Yield o (MachineT k)))
  (\f k g -> return (Await (MachineT . f) k (MachineT g)))
  (return Stop)

-- | Generates a model that runs a machine until it stops, then start it up again.
--
-- @'repeatedly' m = 'construct' ('Control.Monad.forever' m)@
repeatedly :: Monad m => PlanT k i o m a -> MachineT m k i o
repeatedly m = r where
  r = MachineT $ runPlanT m
    (const (runMachineT r))
    (\o k -> return (Yield o (MachineT k)))
    (\f k g -> return (Await (MachineT . f) k (MachineT g)))
    (return Stop)

-- | Evaluate a machine until it stops, and then yield answers according to the supplied model.
before :: Monad m => MachineT m k i o -> PlanT k i o m a -> MachineT m k i o
before (MachineT n) m = MachineT $ runPlanT m
  (const n)
  (\o k -> return (Yield o (MachineT k)))
  (\f k g -> return (Await (MachineT . f) k (MachineT g)))
  (return Stop)

-- | Given a handle, ignore all other inputs and just stream input from that handle.
--
-- @
-- 'pass' 'id' :: 'Data.Machine.Process.Process' a a
-- 'pass' 'Data.Machine.Tee.L'  :: 'Data.Machine.Tee.Tee' a b a
-- 'pass' 'Data.Machine.Tee.R'  :: 'Data.Machine.Tee.Tee' a b b
-- 'pass' 'Data.Machine.Wye.X'  :: 'Data.Machine.Wye.Wye' a b a
-- 'pass' 'Data.Machine.Wye.Y'  :: 'Data.Machine.Wye.Wye' a b b
-- 'pass' 'Data.Machine.Wye.Z'  :: 'Data.Machine.Wye.Wye' a b (Either a b)
-- @
pass :: k i o -> Machine k i o
pass input = repeatedly $ do
  a <- awaits input
  yield a

-- | Eventually this will probably revert to @instance 'Monad' m => 'Category' ('MachineT' m 'Is')@
instance (k ~ Is, Monad m) => Category (MachineT m k) where
  id = repeatedly $ do
    i <- await
    yield i

  m . n = MachineT $ runMachineT m >>= \v -> case v of
    Stop          -> return Stop
    Yield a as    -> return $ Yield a (as . n)
    Await f Refl k -> runMachineT n >>= \u -> case u of
      Stop          -> runMachineT $ k . stopped
      Yield b bs    -> runMachineT $ f b . bs
      Await g Refl fg -> return $ Await (\a -> encased v . g a) Refl (encased v . fg)

-- | This is a stopped 'Machine'
stopped :: Machine k a b
stopped = encased Stop

-------------------------------------------------------------------------------
-- Sink
-------------------------------------------------------------------------------

{-
-- |
-- A Sink in this model is a 'Data.Machine.Process.Process'
-- (or 'Data.Machine.Tee.Tee', etc) that produces a single answer.
--
-- \"Is that your final answer?\"
sink :: Monad m => (forall o. PlanT k i o m a) -> MachineT m k i a
sink m = runPlanT m (\a -> Yield a Stop) id (Await id) Stop
-}