{-# LANGUAGE RankNTypes #-}
module FRP.Coconut.Core (
  Dynamic,
  pollDynamic,
  subscribeDynamic,
  collector,
  mkDynamic,
  nubDynamic,
  splitDynamic
 ) where

import Control.Applicative
import Control.Monad
import Control.Parallel
import Data.IORef
import Control.Concurrent.MVar
import System.IO.Unsafe
import System.Mem.Weak

-- | Represents a value which can change: equivalent to both Behavior and
-- Event as found in some other FRP libraries.
data Dynamic a = Dynamic (IORef a) (MVar [(IORef (), IO ())])

runTriggers :: MVar [(IORef (), IO ())] -> IO ()
runTriggers v = do
  l <- readMVar v
  forM_ l $ \(_, a) -> a

initialRef :: IO (IORef a)
initialRef = newIORef (error "Tried to use dynamic variable before it was \
  \initialized.")

dropTrigger :: IORef () ->
  MVar [(IORef (), IO ())] ->
  IO ()
dropTrigger sn t = do
  l <- takeMVar t
  let l' = filter ((/= sn) . fst) l
  putMVar t $ l'
  foldr (flip const) () l `par` return ()

addTrigger :: IORef () -> IO () ->
  MVar [(IORef (), IO ())] ->
  IO ()
addTrigger sn u t = do
  l <- takeMVar t
  putMVar t $ (sn,u) : l

instance Functor Dynamic where
  fmap f (Dynamic r t) = unsafePerformIO $ do
    r' <- initialRef
    t' <- newMVar []
    sn <- newIORef ()
    wr <- mkWeakIORef r' $ dropTrigger sn t
    let
      update = deRefWeak wr >>= \mr -> case mr of
        Nothing -> return ()
        Just r1 -> do
          a <- readIORef r
          writeIORef r1 (f a)
          runTriggers t'
    addTrigger sn update t
    update
    return $ Dynamic r' t'

instance Applicative Dynamic where
  pure a = unsafePerformIO $ do
    r <- newIORef a
    t <- newMVar []
    return (Dynamic r t)
  Dynamic rf tf <*> Dynamic ra ta = unsafePerformIO $ do
    r <- initialRef
    t <- newMVar []
    sn <- newIORef ()
    wr <- mkWeakIORef r $ dropTrigger sn tf >> dropTrigger sn ta
    let
      update = deRefWeak wr >>= \mr -> case mr of
        Nothing -> return ()
        Just r1 -> do
          f <- readIORef rf
          a <- readIORef ra
          writeIORef r1 (f a)
          runTriggers t
    addTrigger sn update tf
    addTrigger sn update ta
    update
    return (Dynamic r t)

instance Monad Dynamic where
  return = pure
  Dynamic ra ta >>= f = unsafePerformIO $ do
    r <- initialRef
    t <- newMVar []
    sn <- newIORef ()
    bb <- newEmptyMVar
    wr <- mkWeakIORef r $ do
      dropTrigger sn ta
      ~(Dynamic _ tb) <- takeMVar bb
      dropTrigger sn tb
    let
      update = do
        tryTakeMVar bb >>= \b -> case b of
          Just ~(Dynamic _ tb) -> dropTrigger sn tb
          Nothing -> return ()
        a <- readIORef ra
        let db@(Dynamic rb tb) = f a
        putMVar bb db
        let
          update2 = deRefWeak wr >>= \mr -> case mr of
            Nothing -> return ()
            Just r0 -> do
              b <- readIORef rb
              writeIORef r0 b
              runTriggers t
        addTrigger sn update2 tb
        update2
    addTrigger sn update ta
    update
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
  addTrigger sn (readIORef r >>= h) t
  return $ dropTrigger sn t

-- | Produces a 'Dynamic' object containing the provided value, and an
-- action for updating it.
collector :: a -> IO (Dynamic a, (a -> a) -> IO ())
collector a = do
  r <- newIORef a
  t <- newMVar []
  return (Dynamic r t,
    \f -> atomicModifyIORef r (\a -> (f a,())) >>=
    \u -> u `seq` runTriggers t)

-- | Simplified version of 'collector': the action replaces the current value
-- rather than applying the endofunctor.
mkDynamic :: a -> IO (Dynamic a, a -> IO ())
mkDynamic a = do
  r <- newIORef a
  t <- newMVar []
  return (Dynamic r t, \b -> writeIORef r b >> runTriggers t)

-- | Produces a 'Dynamic' object which does not propagate the update signal if
-- its contents are unchanged.
nubDynamic :: Eq a => Dynamic a -> Dynamic a
nubDynamic (Dynamic r t) = unsafePerformIO $ do
  sn <- newIORef ()
  wr <- mkWeakIORef r $ dropTrigger sn t
  t' <- newMVar []
  a <- readIORef r
  c <- newMVar a
  let
    update = deRefWeak wr >>= \mr -> case mr of
      Nothing -> return ()
      Just r0 -> do
        a1 <- readIORef r0
        a2 <- takeMVar c
        putMVar c a1
        when (a1 == a2) (runTriggers t')
  addTrigger sn update t
  update
  return (Dynamic r t')

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
  addTrigger sn (do
    a <- readIORef sr
    r ct a $ \b (Dynamic tr tt) -> do
      writeIORef tr b
      runTriggers tt
   ) st
  return ct
