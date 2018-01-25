{-# LANGUAGE RankNTypes #-}
module FRP.Coconut.Core (
  Dynamic,
  pollDynamic,
  subscribeDynamic,
  subscribeDynamic',
  collector,
  mkDynamic,
  accumulator,
  nubDynamic,
  splitDynamic,
  scatter,
  hold
 ) where

import Control.Applicative
import Control.Monad
import Control.Parallel
import Data.Functor.Identity
import Data.IORef
import Control.Concurrent.MVar
import System.IO.Unsafe
import System.Mem.Weak
import Foreign.StablePtr

import Data.Assortment

-- | Represents a value which can change: equivalent to both Behavior and
-- Event as found in some other FRP libraries.
data Dynamic a = Dynamic (MVar a) (MVar [(IORef (), a -> IO ())])

getTriggers :: MVar [(IORef (), a -> IO ())] -> a -> IO (IO ())
getTriggers v x = do
  l <- readMVar v
  return $ forM_ l $ \(_, a) -> a x

initialRef :: IO (IORef a)
initialRef = newIORef (error "Tried to use dynamic variable before it was \
  \initialized.")

dropTrigger :: IORef () ->
  MVar [(IORef (), a -> IO ())] ->
  IO ()
dropTrigger sn t = do
  l <- takeMVar t
  let l' = filter ((/= sn) . fst) l
  putMVar t $ l'
  foldr (flip const) () l `par` return ()

addTrigger :: IORef () -> (a -> IO ()) ->
  MVar [(IORef (), a -> IO ())] ->
  IO ()
addTrigger sn u t = do
  l <- takeMVar t
  putMVar t $ (sn,u) : l

instance Functor Dynamic where
  fmap f (Dynamic r t) = unsafePerformIO $ do
    a0 <- takeMVar r
    r' <- newEmptyMVar
    t' <- newMVar []
    sn <- newIORef ()
    wt <- mkWeakMVar t' $ dropTrigger sn t
    let
      update a = do
        let b = f a
        _ <- takeMVar r'
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 b
        putMVar r' b
        tr
    addTrigger sn update t
    putMVar r' (f a0)
    putMVar r a0
    return $ Dynamic r' t'

instance Applicative Dynamic where
  pure a = unsafePerformIO $ do
    r <- newMVar a
    t <- newMVar []
    return (Dynamic r t)
  Dynamic rf tf <*> Dynamic ra ta = unsafePerformIO $ do
    f0 <- takeMVar rf
    a0 <- takeMVar ra
    fl <- newMVar f0
    al <- newMVar a0
    r <- newMVar (f0 a0)
    t <- newMVar []
    sn <- newIORef ()
    wt <- mkWeakMVar t $ dropTrigger sn tf >> dropTrigger sn ta
    let
      update f a = do
        let b = f a
        _ <- takeMVar r
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t' -> getTriggers t' b
        putMVar r b
        putMVar al a
        putMVar fl f
        tr
      updateA a = do
        f <- takeMVar fl
        _ <- takeMVar al
        update f a
      updateF f = do
        _ <- takeMVar fl
        a <- takeMVar al
        update f a
    addTrigger sn updateF tf
    addTrigger sn updateA ta
    putMVar ra a0
    putMVar rf f0
    return (Dynamic r t)

instance Monad Dynamic where
  return = pure
  Dynamic ra ta >>= f = unsafePerformIO $ do
    r <- newEmptyMVar
    t <- newMVar []
    sn <- newIORef ()
    a0 <- takeMVar ra
    let b0@(Dynamic rb0 tb0) = f a0
    bb <- newMVar b0
    wt <- mkWeakMVar t $ do
      tryTakeMVar bb >>= \mb -> case mb of
        Nothing -> return ()
        Just (Dynamic _ tb) -> dropTrigger sn tb
      dropTrigger sn ta
    let
      update1 a = do
        Dynamic _ tb0 <- takeMVar bb
        dropTrigger sn tb0
        let bn@(Dynamic bnr bnt) = f a
        b <- takeMVar bnr
        _ <- takeMVar r
        addTrigger sn update2 bnt
        putMVar bnr b
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 b
        putMVar r b
        tr
      update2 b = do
        _ <- takeMVar r
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 b
        putMVar r b
        tr    
    b0v <- takeMVar rb0
    addTrigger sn update2 tb0
    addTrigger sn update1 ta
    putMVar r b0v
    putMVar rb0 b0v
    putMVar ra a0
    return (Dynamic r t)

-- | Get the value currently stored in the 'Dynamic' object.
pollDynamic :: Dynamic a -> IO a
pollDynamic ~(Dynamic r _) = readMVar r

-- | Provide a handler which will be run immediately with the current value
-- in the 'Dynamic', and again every time it updates. Returns an IO action
-- which removes the subscription. Calling it more than once is dangerous.
subscribeDynamic :: Dynamic a -> (a -> IO ()) -> IO (IO ())
subscribeDynamic d@(Dynamic r t) h = do
  v <- takeMVar r
  u <- subscribeDynamic' d h
  putMVar r v
  h v
  return u

-- | Provide a handler which will be run with the new value when the 'Dynamic'
-- object updates, but not immediately with the current value.
subscribeDynamic' :: Dynamic a -> (a -> IO ()) -> IO (IO ())
subscribeDynamic' (Dynamic r t) h = do
  sn <- newIORef ()
  sp <- newStablePtr t
  addTrigger sn h t
  return $ dropTrigger sn t >> freeStablePtr sp

-- | Produces a 'Dynamic' object containing the provided value, and an
-- action for updating it.
collector :: a -> IO (Dynamic a, (a -> a) -> IO ())
collector a = do
  r <- newMVar a
  t <- newMVar []
  return (Dynamic r t, \f -> do
    a' <- takeMVar r
    let b = f a'
    tr <- getTriggers t b
    putMVar r b
    tr
   )

-- | Simplified version of 'collector': the action replaces the current value
-- rather than applying the endofunctor.
mkDynamic :: a -> IO (Dynamic a, a -> IO ())
mkDynamic a = do
  r <- newMVar a
  t <- newMVar []
  return (Dynamic r t, \b -> do
    _ <- takeMVar r
    tr <- getTriggers t b
    putMVar r b
    tr
   )

-- | Creates a stateful 'Dynamic' object: useful for implementing counters, etc.
accumulator :: (s -> a -> (s,b)) -> s -> Dynamic a -> IO (Dynamic b)
accumulator u s0 ~(Dynamic r t) = do
  a0 <- takeMVar r
  let (s1, b1) = u s0 a0
  r' <- newMVar b1
  t' <- newMVar []
  sn <- newIORef ()
  sr <- newMVar s1
  wt <- mkWeakMVar t' $ do
    dropTrigger sn t
  let
    update a = do
      _ <- takeMVar r'
      s2 <- takeMVar sr
      let (s3,b3) = u s2 a
      putMVar sr s3
      tr <- deRefWeak wt >>= \mt -> case mt of
        Nothing -> return (return ())
        Just t0 -> getTriggers t0 b3
      putMVar r' b3
      tr
  addTrigger sn update t
  putMVar r a0
  return (Dynamic r' t')

-- | Produces a 'Dynamic' object which does not propagate the update signal if
-- its contents are unchanged.
nubDynamic :: Eq a => Dynamic a -> Dynamic a
nubDynamic (Dynamic r t) = unsafePerformIO $ do
  a <- takeMVar r
  r' <- newMVar a
  t' <- newMVar []
  sn <- newIORef ()
  wt <- mkWeakMVar t' $ dropTrigger sn t
  let
    update b = do
      c <- takeMVar r'
      tr <- if b /= c
        then deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 b
        else return (return ())
      putMVar r' b
      tr
  addTrigger sn update t
  putMVar r a
  return (Dynamic r' t')

data Sink a = Sink (MVar a) (Weak (MVar [(IORef (), a -> IO ())]))

sink :: IO () -> Dynamic a -> IO (Sink a)
sink f (Dynamic r t) = Sink r <$> mkWeakMVar t f

-- | This is intended for creating a collection of 'Dynamic' objects from a
-- single one. The first argument is used to populate the collection, the
-- second argument is used to distribute updates to the collection, the third
-- argument is the source 'Dynamic' object, and the fourth argument is the
-- initial value for the collection contents.
{-# INLINE splitDynamic #-}
splitDynamic :: forall a b c . Traversable c =>
  (forall m t . Monad m => a -> (b -> m t) -> m (c t)) ->
  (forall m t . Monad m => c t ->
    a ->
    (b -> t -> m ()) ->
    m ()
   ) ->
  Dynamic a ->
  c (Dynamic b)
splitDynamic d r s = openAContainer (scatter (\a n -> AContainer <$>
  d a n
 ) (\(AContainer l) a u -> r l a u
 ) s)

scatter :: forall a c s . Assortment c =>
  (forall t m . Monad m =>
    a ->
    (forall b . b -> m (t b)) ->
    m (c t)
   ) ->
  (forall t m . Monad m =>
    c t ->
    a ->
    (forall b . b -> t b -> m ()) ->
    m ()
   ) ->
  Dynamic a ->
  c Dynamic
scatter c u (Dynamic r t) = unsafePerformIO $ do
  a <- takeMVar r
  counter <- newMVar 0
  sn <- newIORef ()
  x <- c a $ \b -> do
    r' <- newMVar b
    t' <- newMVar []
    cv <- takeMVar counter
    putMVar counter (cv + 1)
    _ <- mkWeakMVar t' $ do
      cv' <- takeMVar counter
      let cv1 = cv' - 1
      if cv1 == 0
        then dropTrigger sn t
        else putMVar counter cv1
    return (Dynamic r' t')
  y <- cmapM (sink $ return ()) x
  addTrigger sn (\a' -> u y a' $ \b (Sink r' wt) -> do
    _ <- takeMVar r'
    tx <- deRefWeak wt >>= \mt -> case mt of
      Nothing -> return (return ())
      Just tt -> getTriggers tt b
    putMVar r' b
    tx
   ) t
  putMVar r a
  return x

-- | Create a new 'Dynamic' object containing the current value of the argument,
-- and an 'IO' action. The new 'Dynamic' object will retain its current value,
-- but will update it whenever the accompanying 'IO' action is run.
hold :: Dynamic a -> IO (Dynamic a, IO ())
hold (Dynamic r t) = do
  a <- takeMVar r
  r' <- newMVar a
  t' <- newMVar []
  sp <- newStablePtr t
  _ <- mkWeakMVar t' $ freeStablePtr sp
  putMVar r a
  return (Dynamic r' t', do
    a <- takeMVar r
    tr <- getTriggers t' a
    putMVar r a
    tr
   )
