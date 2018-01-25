module Data.Assortment (
  Assortment(..),
  collate
 ) where

import Data.Assortment.Class
import Data.Functor.Identity

collate :: (Monad m, Assortment c) => c m -> m (c Identity)
collate c = cmapM (fmap Identity) c
