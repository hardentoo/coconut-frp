module Data.Assortment (
  Assortment(..),
  AContainer(..),
  collate
 ) where

import Data.Assortment.Class
import Data.Functor.Identity

newtype AContainer f a w = AContainer { openAContainer :: f (w a) }

instance (Traversable f) => Assortment (AContainer f a) where
  cmap f (AContainer c) = AContainer $ fmap f c
  cmapM f (AContainer c) = AContainer <$> traverse f c

collate :: (Monad m, Assortment c) => c m -> m (c Identity)
collate c = cmapM (fmap Identity) c
