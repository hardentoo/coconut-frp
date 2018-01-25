{-# LANGUAGE RankNTypes #-}
module Data.Assortment.Class (Assortment(..)) where
import Data.Functor.Identity

class Assortment c where
  cmap :: (forall b . m b -> n b) -> c m -> c n
  cmapM :: Monad m => (forall b . x b -> m (y b)) -> c x -> m (c y)
  cmap f c = runIdentity (cmapM (Identity . f) c)
  {-# MINIMAL cmapM #-}