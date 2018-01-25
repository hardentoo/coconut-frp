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
data Dynamic a = Dynamic (IORef a) (MVar [(IORef (), a -> IO ())])

runTriggers :: MVar [(IORef (), a -> IO ())] -> a -> IO ()
runTriggers v x = do
  l <- readMVar v
  forM_ l $ \(_, a) -> a x

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
    r' <- readIORef r >>= (newIORef . f)
    t' <- newMVar []
    sn <- newIORef ()
    wt <- mkWeakMVar t' $ dropTrigger sn t
    let
      update a = do
        let b = f a
        writeIORef r' b
        deRefWeak wt >>= \mt -> case mt of
          Nothing -> return ()
          Just t0 -> runTriggers t0 b
    addTrigger sn update t
    return $ Dynamic r' t'

instance Applicative Dynamic where
  pure a = unsafePerformIO $ do
    r <- newIORef a
    t <- newMVar []
    return (Dynamic r t)
  Dynamic rf tf <*> Dynamic ra ta = unsafePerformIO $ do
    r <- (readIORef rf <*> readIORef ra) >>= newIORef
    t <- newMVar []
    sn <- newIORef ()
    wt <- mkWeakMVar t $ dropTrigger sn tf >> dropTrigger sn ta
    crf <- readIORef rf >>= newMVar
    cra <- readIORef ra >>= newMVar
    let
      updateF f = do
        _ <- takeMVar crf
        a <- readMVar cra
        let b = f a
        putMVar crf f
        writeIORef r b
        deRefWeak wt >>= \mt -> case mt of
          Nothing -> return ()
          Just t0 -> runTriggers t0 b
      updateA a = do
        f <- takeMVar crf
        _ <- takeMVar cra
        let b = f a
        putMVar cra a
        putMVar crf f
        writeIORef r b
        deRefWeak wt >>= \mt -> case mt of
          Nothing -> return ()
          Just t0 -> runTriggers t0 b
    addTrigger sn updateF tf
    addTrigger sn updateA ta
    return (Dynamic r t)

instance Monad Dynamic where
  return = pure
  Dynamic ra ta >>= f = unsafePerformIO $ do
    t <- newMVar []
    sn <- newIORef ()
    b0@(Dynamic b0r b0t) <- f <$> readIORef ra
    bb <- newMVar b0
    wt <- mkWeakMVar t $ do
      mb <- tryTakeMVar bb
      case mb of
        Nothing -> return ()
        Just (Dynamic _ tb) -> dropTrigger sn tb
      dropTrigger sn ta
    r <- readIORef b0r >>= newIORef
    let
      update1 a = do
        let b@(Dynamic br bt) = f a
        Dynamic _ bt1 <- takeMVar bb
        v <- readIORef br
        putMVar bb b
        dropTrigger sn bt1
        update2 v
        addTrigger sn update2 bt
      update2 b = do
        writeIORef r b
        deRefWeak wt >>= \mt -> case mt of
          Nothing -> return ()
          Just t' -> runTriggers t' b
    addTrigger sn update2 b0t
    addTrigger sn update1 ta
    return (Dynamic r t)

-- | Get the value currently stored in the 'Dynamic' object.
pollDynamic :: Dynamic a -> IO a
pollDynamic ~(Dynamic r _) = readIORef r

-- | Provide a handler which will be run immediately with the current value
-- in the 'Dynamic', and again every time it updates.
subscribeDynamic :: Dynamic a -> (a -> IO ()) -> IO (IO ())
subscribeDynamic d@(Dynamic r t) h = do
  readIORef r >>= h
  subscribeDynamic' d h

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
  r <- newIORef a
  t <- newMVar []
  return (Dynamic r t,
    \f -> atomicModifyIORef r (\a -> let b = f a in (b, b)) >>= runTriggers t)

-- | Simplified version of 'collector': the action replaces the current value
-- rather than applying the endofunctor.
mkDynamic :: a -> IO (Dynamic a, a -> IO ())
mkDynamic a = do
  r <- newIORef a
  t <- newMVar []
  return (Dynamic r t, \b -> writeIORef r b >> runTriggers t b)

-- | Produces a 'Dynamic' object which does not propagate the update signal if
-- its contents are unchanged.
nubDynamic :: Eq a => Dynamic a -> Dynamic a
nubDynamic (Dynamic r t) = unsafePerformIO $ do
  a <- readIORef r
  r' <- newIORef a
  c <- newMVar a
  t' <- newMVar []
  sn <- newIORef ()
  tw <- mkWeakMVar t' $ dropTrigger sn t
  let
    update b = do
      a' <- takeMVar c
      putMVar c b
      when (a' /= b) $ do
        writeIORef r' b
        deRefWeak tw >>= \mt -> case mt of
          Nothing -> return ()
          Just t0 -> runTriggers t0 b
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
  a <- readIORef sr
  ct <- d a $ \i -> do
    r' <- newIORef i
    t' <- newMVar []
    c <- takeMVar counter
    _ <- mkWeakIORef r' $ do
      c0 <- takeMVar counter
      let c1 = c0 - 1
      if c1 == 0
        then dropTrigger sn st
        else putMVar counter c1
    return (Dynamic r' t')
  addTrigger sn (\a -> do
    r ct a $ \b (Dynamic tr tt) -> do
      writeIORef tr b
      runTriggers tt b
   ) st
  return ct

-- | Create a new 'Dynamic' object containing the current value of the argument,
-- and an 'IO' action. The new 'Dynamic' object will retain its current value,
-- but will update it whenever the accompanying 'IO' action is run.
hold :: Dynamic a -> IO (Dynamic a, IO ())
hold (Dynamic r _) = do
  r' <- readIORef r >>= newIORef
  t <- newMVar []
  return (Dynamic r' t,
    readIORef r >>= \v -> writeIORef r' v >> runTriggers t v)
