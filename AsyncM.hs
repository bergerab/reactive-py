{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module AsyncM 
  (
    AsyncM (..)
  , runM        -- run async monad
  , runM_       -- run async monad with a new progress and print exception 
  , timeout
  , catchM
  , noEmit
--  , forkM
  , forkM_
  , raceM
  , allM
  , ifAliveM
  , advM
  , progress
  , commitM
  , neverM
  , asyncM
  ) where

import Control.Concurrent (threadDelay, takeMVar, readMVar, putMVar, newMVar, newEmptyMVar, isEmptyMVar, modifyMVar_, MVar(..))
import Control.Concurrent.Async (async, wait, race, race_, concurrently)
import Control.Monad (when)
import Control.Monad.Cont (runContT, ContT(..))
import Control.Monad.Except (catchError, throwError, ExceptT(..), MonadError(..), runExceptT)
import Control.Monad.Reader (ask, local, ReaderT(..), MonadReader(..), runReaderT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (catch, displayException, SomeException(..))

-- Progress -> (Either String a -> IO ()) -> IO ()
newtype AsyncM a = AsyncM { runAsyncM :: ExceptT String (ReaderT Progress (ContT () IO)) a } 
                     deriving (Functor, Applicative, Monad, MonadIO, MonadReader Progress, MonadError String) 

runM :: AsyncM a -> Progress -> ((Either String a) -> IO ()) -> IO ()
runM (AsyncM a) p k = runContT (runReaderT (runExceptT a) p) k

runM_ :: AsyncM a -> (a -> IO ()) -> IO ()
runM_ a k = progress >>= \p -> runM a p (either print k)

asyncM :: (Progress -> (Either String a) -> IO ()) -> IO ()
asyncM f =  AsyncM $ ExceptT $ ReaderT $ \p -> ContT $ \k -> f p k 

timeout :: Int        -- number milliseconds
        -> AsyncM () 
timeout x = asyncM $ \p k -> do async $ threadDelay (x*10^3) >> k (Right ()) -- in Python (use async?), in JS (use setTimeout?)
                                return ()
                                `catch` \(SomeException e) -> k (Left $ displayException e)

interval :: Int            -- number of events
         -> Int            -- milliseconds between events
         -> (Int -> IO ()) -- function to consume event index
         -> AsyncM ()
interval n dt k = f 1
  where f i = do ifAliveM
                 if i > n then return ()
                 else do timeout dt 
                         advM 
                         liftIO $ k i
                         f (i+1) 

neverM :: AsyncM a
neverM =  asyncM $ \_ _ -> return ()

catchM :: AsyncM a -> (String -> AsyncM a) -> AsyncM a
catchM a h = do p <- liftIO . linkP =<< ask 
                local (\_ -> p) a `catchError` (\e -> liftIO (cancel p) >> h e)

-- noEmit really means no emission of progress this time.
noEmit :: AsyncM a -> AsyncM a
noEmit a = do p <- liftIO . noEmitP =<< ask
              x <- local (\_ -> p) a 
              -- liftIO $ advance p
              return x

-- no internal emit of progress and then advance whe completed
oneEmit a = do x <- noEmit a 
               advM
               return x

forkM_ :: AsyncM a -> AsyncM ()
forkM_ a = asyncM $ \p k -> do runM a p $ \_ -> return () 
                               k $ Right ()

{-
forkM :: AsyncM a -> AsyncM (Progress, AsyncM a)
forkM a = asyncM $ \p k -> do 
    p' <- linkP p     -- new progress linked to p
    v <- newEmptyMVar -- future value is stored here
    -- run 'a' immediately with progress p' and put results in 'v' 
    runM a p' $ putMVar v
    -- return the progress p' and an async monad as the future value waiting in a new thread
    k $ Right (p', asyncM $ \_ k -> async (readMVar v >>= k) >> return ()) 
-}

-- FIXME: NOT thread safe
raceM :: AsyncM a -> AsyncM a -> AsyncM a
raceM a1 a2 = asyncM $ \p k -> do
    (p1, p2) <- raceP p 
    done <- newEmptyMVar 

    let k' = \x -> do b <- isEmptyMVar done 
                      if b then putMVar done () >> k x 
                           else return () 
    runM a1 p1 k'
    runM a2 p2 k'

-- FIXME: NOT thread safe
-- if a1 throws an exception e, then completes with e
-- if a2 throws an exception e, then completes with e
-- if a1 finishes first, then wait for a2
-- if a2 finishes first, then wait for a1
allM :: AsyncM a -> AsyncM b -> AsyncM (a, b)
allM a1 a2 = asyncM $ \p k -> do 
    m1 <- newEmptyMVar
    m2 <- newEmptyMVar

    let k' m1 m2 pair = \x -> do b <- isEmptyMVar m2
                                 if b then do putMVar m1 x
                                              case x of Left e -> k (Left e) 
                                                        Right _ -> return ()
                                      else do y <- readMVar m2
                                              case y of Left e -> return ()
                                                        Right _ -> k $ pair x y
    runM a1 p (k' m1 m2 pair)
    runM a2 p (k' m2 m1 $ flip pair) 

    where pair x y = pure (,) <*> x <*> y

-- advance the current progress object
advM :: AsyncM ()
advM = liftIO . advance =<< ask 

ifAliveM :: AsyncM ()
ifAliveM = asyncM $ \p k -> ifAlive p $ k $ Right ()

commitM = ifAliveM >> advM

data Progress = Progress { cancelV :: MVar ()        -- cancel flag
                        , cancelCB :: MVar [IO ()]   -- cancel callbacks
                        ,advanceCB :: MVar [IO ()]}  -- advance callbacks

-- creates a blank progress object
progress :: IO Progress
progress = pure Progress <*> newEmptyMVar <*> newMVar [] <*> newMVar []

ifAlive :: Progress -> IO () -> IO ()
ifAlive p a = do { b <- isEmptyMVar $ cancelV p; when b a } -- 'when' is a branching statement

-- advance checks if 'p' is alive and if so, run each one of the callbacks in 'advanceCB'
advance :: Progress -> IO ()
advance p = ifAlive p $ readMVar (advanceCB p) >>= sequence_

-- cancel checks if 'p' is alive and if so, set the 'cancelV' flag and run each of the callbacks in 'cancelCB'
cancel :: Progress -> IO ()
cancel  p = ifAlive p $ putMVar (cancelV p) () >> readMVar (cancelCB p) >>= sequence_ 

-- register an advance callback on a progress object
onAdvance :: Progress -> IO () -> IO ()
onAdvance p handle = modifyMVar_ (advanceCB p) $ \lst -> return (handle : lst)

-- register a cancel callback on a progress object
onCancel :: Progress -> IO () -> IO ()
onCancel  p handle = modifyMVar_ (cancelCB  p) $ \lst -> return (handle : lst)

-- make a new progress so that p -- cancel --> p' 
--                             p'-- advance--> p
linkP :: Progress -> IO Progress
linkP p = do
   p' <- progress
   onCancel p $ cancel p'
   onAdvance p' $ advance p
   return p'

-- make a new progress so that p -- cancel --> p'
noEmitP :: Progress -> IO Progress
noEmitP p = do
   p' <- progress
   onCancel p $ cancel p'
   return p' 
    
-- make a pair of progress objects so that they can cancel each other
-- p -- cancel --> p1
-- p -- cancel --> p2
-- p1-- advance--> p, -- cancel --> p2
-- p2-- advance--> p, -- cancel --> p1
raceP :: Progress -> IO (Progress, Progress)
raceP p = do
   p1 <- progress
   p2 <- progress
   onAdvance p1 $ cancel p2 >> advance p
   onAdvance p2 $ cancel p1 >> advance p
   onCancel  p  $ cancel p1 >> cancel  p2
   return (p1, p2)


