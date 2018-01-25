{-# LANGUAGE RankNTypes #-}
module FRP.Coconut.Core (
  Dynamic,
  pollDynamic,
  subscribeDynamic,
  collector,
  mkDynamic,
  nubDynamic,
  splitDynamic,
  hold
 ) where

import Control.Applicative
import Control.Monad
import Control.Parallel
import Data.IORef
import Control.Concurrent.MVar
import System.IO.Unsafe
import System.Mem.Weak
import Foreign.StablePtr

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
-- in the 'Dynamic', and again every time it updates.
subscribeDynamic :: Dynamic a -> (a -> IO ()) -> IO (IO ())
subscribeDynamic d@(Dynamic r t) h = do
  v <- takeMVar r
  u <- subscribeDynamic' d h
  h v
  putMVar r v
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
      tr <- if b == c
        then deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 b
        else return (return ())
      putMVar r' b
      tr
  addTrigger sn update t
  return (Dynamic r' t')

-- | This is intended for creating a collection of 'Dynamic' objects from a
-- single one. The first argument is used to populate the collection, the
-- second argument is used to distribute updates to the collection, the third
-- argument is the source 'Dynamic' object, and the fourth argument is the
-- initial value for the collection contents.
splitDynamic :: forall a b c . Functor c =>
  (forall m t . Monad m => a -> (b -> m t) -> m (c t)) ->
  (forall m t . Monad m => c t ->
    a ->
    (b -> t -> m ()) ->
    m ()
   ) ->
  Dynamic a ->
  c (Dynamic b)
splitDynamic d r s@(Dynamic sr st) = unsafePerformIO $ do
  counter <- newMVar 0 :: IO (MVar Int)
  sn <- newIORef ()
  a <- takeMVar sr
  ct <- d a $ \i -> do
    r' <- newMVar i
    t' <- newMVar []
    c <- takeMVar counter
    _ <- mkWeakMVar t' $ do
      c0 <- takeMVar counter
      let c1 = c0 - 1
      if c1 == 0
        then dropTrigger sn st
        else putMVar counter c1
    return (Dynamic r' t')
  addTrigger sn (\a -> do
    r ct a $ \b (Dynamic tr tt) -> do
      _ <- takeMVar tr
      tx <- getTriggers tt b
      putMVar tr b
      tx
   ) st
  putMVar sr a
  return ct

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
