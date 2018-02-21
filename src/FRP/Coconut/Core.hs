{-# LANGUAGE RankNTypes #-}
module FRP.Coconut.Core (
  Dynamic,
  pollDynamic,
  subscribeDynamic,
  subscribeDynamic',
  collector,
  collectorWithFinalizer,
  mkDynamic,
  mkDynamicWithFinalizer,
  accumulator,
  nubDynamic,
  splitDynamic,
  scatter,
  MonadScatter(..),
  scatterD,
  hold,
  merge
 ) where

import Control.Applicative
import Control.Monad
import Control.Parallel
import Data.Functor.Identity
import Data.IORef
import Control.Concurrent
import Control.Concurrent.MVar
import System.IO.Unsafe
import System.Mem.Weak
import Foreign.StablePtr

import qualified Rank2

-- | Represents a value which can change. Can be thought of as a division of
-- infinite time into a series of discrete blocks: each of which is associated
-- with a value. There is always a detectable update event between these blocks
-- of time: whether or not the stored value has changed.
data Dynamic a = Dynamic (MVar a) (MVar [(IORef (), a -> IO ())])

getTriggers :: MVar [(IORef (), a -> IO ())] -> a -> IO (IO ())
getTriggers v x = do
  l <- readMVar v
  return $ forM_ l $ \(_, a) -> forkIO $ a x

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

collectorWithFinalizer :: a -> IO () -> IO (Dynamic a, (a -> a) -> IO ())
collectorWithFinalizer a f = do
  r <- newMVar a
  t <- newMVar []
  wt <- mkWeakMVar t f
  return (Dynamic r t, \u -> do
    a' <- takeMVar r
    let b = u a
    tr <- deRefWeak wt >>= \mt -> case mt of
      Nothing -> return (return ())
      Just t' -> getTriggers t' b
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

mkDynamicWithFinalizer :: a -> IO () -> IO (Dynamic a, a -> IO ())
mkDynamicWithFinalizer a f = do
  r <- newMVar a
  t <- newMVar []
  wt <- mkWeakMVar t f
  return (Dynamic r t, \b -> do
    _ <- takeMVar r
    tr <- deRefWeak wt >>= \mt -> case mt of
      Nothing -> return (return ())
      Just t' -> getTriggers t' b
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
    ((b -> b) -> t -> m ()) ->
    m ()
   ) ->
  Dynamic a ->
  IO (c (Dynamic b))
splitDynamic d r s = (\(Rank2.Flip c) -> c) <$> scatter (\a n ->
  Rank2.Flip <$> d a n
 ) (\(Rank2.Flip c) a u ->
  r c a u
 ) s

scatter :: forall a c s . Rank2.Traversable c =>
  (forall t m . Monad m =>
    a ->
    (forall b . b -> m (t b)) ->
    m (c t)
   ) ->
  (forall t m . Monad m =>
    c t ->
    a ->
    (forall b . (b -> b) -> t b -> m ()) ->
    m ()
   ) ->
  Dynamic a ->
  IO (c Dynamic)
scatter c u (Dynamic r t) = do
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
  y <- Rank2.traverse (sink $ return ()) x
  addTrigger sn (\a' -> u y a' $ \bf (Sink r' wt) -> do
    b0 <- takeMVar r'
    let b = bf b0
    tx <- deRefWeak wt >>= \mt -> case mt of
      Nothing -> return (return ())
      Just tt -> getTriggers tt b
    putMVar r' b
    tx
   ) t
  putMVar r a
  return x

class Monad m0 => MonadScatter m0 where
  scatterD2 :: forall c s .
    (forall m d . MonadScatter m =>
      (forall b . Dynamic b -> m b) ->
      (forall b . b -> m (d b)) ->
      (forall b . (forall n d1 . MonadScatter n =>
        c d1 -> b ->
        (forall b1 . b1 -> n (d b1)) ->
        (forall b1 . (b1 -> n b1) -> d1 b1 -> n ()) ->
        (c d1 -> n ()) ->
        n ()
       ) -> Dynamic b -> m ()) ->
      m (c d)
     ) ->
    m0 (Dynamic (c Dynamic))

instance MonadScatter IO where
  scatterD2 bf = do
    r <- newEmptyMVar
    t <- newMVar []
    sn <- newIORef ()
    rc <- newMVar 0
    p <- newMVar []
    let
      deref = do
        c <- takeMVar rc
        if c <= 1
          then do
            rr <- takeMVar p
            forM_ rr $ \t -> dropTrigger sn t
            putMVar p []
          else return ()
        putMVar rc (c - 1)
      addParent d = do
        rr <- takeMVar p
        putMVar p (d : rr)
      ref = do
        c <- takeMVar rc
        putMVar rc (c + 1)
      mkDest b = do
        ref
        r' <- newMVar b
        t' <- newMVar []
        mkWeakMVar t' deref
        return (Dynamic r' t')
    ref
    wt <- mkWeakMVar t deref
    bf pollDynamic mkDest
      (\uf (Dynamic r' t') -> addParent t >> addTrigger sn (\v -> do
        c1 <- takeMVar r
        cr <- newIORef c1
        uf c1 v mkDest (\tf (Dynamic rd td) -> do
          v' <- takeMVar rd
          nv <- tf v'
          ff <- getTriggers td nv
          putMVar rd nv
          ff
         ) (\cn -> do
          writeIORef cr cn
          join $ getTriggers t cn
         )
        readIORef cr >>= putMVar r
       ) t'
      ) >>= putMVar r
    return (Dynamic r t)

scatterD :: forall a c s m0 . MonadScatter m0 =>
  (forall m d . MonadScatter m =>
    (forall b . Dynamic b -> m b) ->
    (forall b . b -> m (d b)) ->
    (forall b . (forall n d1 . MonadScatter n =>
      c (d1 a) -> b ->
      (forall b1 . b1 -> n (d b1)) ->
      (forall b1 . (b1 -> n b1) -> d1 b1 -> n ()) ->
      (c (d1 a) -> n ()) ->
      n ()
     ) -> Dynamic b -> m ()) ->
    m (c (d a))
   ) ->
  m0 (Dynamic (c (Dynamic a)))
scatterD bf = do
  r <- scatterD2 (\pk mk dst -> Rank2.Flip <$> bf pk mk (\uf ud ->
    dst (\(Rank2.Flip c0) tv mk' pok uc ->
      uf c0 tv mk' pok (uc . Rank2.Flip)) ud
   ))
  return $ fmap (\(Rank2.Flip c) -> c) r

-- | Create a new 'Dynamic' object containing the current value of the
-- argument, and an 'IO' action. The new 'Dynamic' object will retain its
-- current value, but will update it whenever the accompanying 'IO' action is
-- run.
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

merge :: (a -> b -> c) -> (a -> c -> Maybe c) -> (b -> c -> Maybe c) ->
  Dynamic a -> Dynamic b ->
  IO (Dynamic c)
merge im ua ub (Dynamic ar at) (Dynamic br bt) = do
  a0 <- takeMVar ar
  b0 <- takeMVar br
  r <- newMVar (im a0 b0)
  t <- newMVar []
  sn <- newIORef ()
  wt <- mkWeakMVar t $ dropTrigger sn at >> dropTrigger sn bt
  addTrigger sn (\a -> do
    c1 <- takeMVar r
    case ua a c1 of
      Nothing -> putMVar r c1
      Just c2 -> do
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 c2
        putMVar r c2
        tr
   ) at
  addTrigger sn (\b -> do
    c1 <- takeMVar r
    case ub b c1 of
      Nothing -> putMVar r c1
      Just c2 -> do
        tr <- deRefWeak wt >>= \mt -> case mt of
          Nothing -> return (return ())
          Just t0 -> getTriggers t0 c2
        putMVar r c2
        tr
   ) bt
  putMVar ar a0
  putMVar br b0
  return (Dynamic r t)
