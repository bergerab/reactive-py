{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module AsyncM 
  (
    AsyncM (..)
  , runM        -- run async monad
  , runM_       -- run async monad with a new progress and print exception 
  , timeout
  , forkM_
  , raceM
  , allM
  , ifAliveM
  , advM
  , cancelM
  , neverM
  , asyncM
  ) where

import Control.Concurrent (threadDelay, readMVar, putMVar, newEmptyMVar, isEmptyMVar, MVar(..))
import Control.Concurrent.Async (async)
import Control.Monad.Cont (runContT, ContT(..))
import Control.Monad.Except (catchError, ExceptT(..), MonadError(..), runExceptT)
import Control.Monad.Reader (ask, local, ReaderT(..), MonadReader(..), runReaderT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (catch, displayException, SomeException(..))
import Progress

-- Progress -> (Either String a -> IO ()) -> IO ()
newtype AsyncM a = AsyncM { runAsyncM :: ExceptT String (ReaderT Progress (ContT () IO)) a } 
                     deriving (Functor, Applicative, Monad, MonadIO, MonadReader Progress, MonadError String) 

runM :: AsyncM a -> Progress -> (Either String a -> IO ()) -> IO ()
runM (AsyncM a) p k = runContT (runReaderT (runExceptT a) p) k

runM_ :: AsyncM a -> (a -> IO ()) -> IO ()
runM_ a k = nilP >>= \p -> runM a p (either print k)

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
                         advM $ do liftIO $ k i
                                   f (i+1) 

neverM :: AsyncM a
neverM =  asyncM $ \_ _ -> return ()

-- do not cancel 'a' anymore. Handler may decide what to do with cancelling the associated progress of 'a'
catchM :: AsyncM a -> (String -> AsyncM a) -> AsyncM a
catchM = catchError 

forkM_ :: AsyncM a -> AsyncM ()
forkM_ a = asyncM $ \p k -> do runM a p $ \_ -> return () 
                               k $ Right ()
-- FIXME: NOT thread safe
raceM :: AsyncM a -> AsyncM a -> AsyncM a
raceM a1 a2 = asyncM $ \p k -> do
    p' <- consP p 
    done <- newEmptyMVar 

    let k' = \x -> do b <- isEmptyMVar done 
                      if b then putMVar done () >> k x 
                           else return () 
    runM a1 p' k'
    runM a2 p' k'

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

-- advance the current ConsP progress object
-- do nothing if the progress object is NilP
advM :: AsyncM a -> AsyncM a
advM a = do p <- ask 
            case p of NilP v -> a
                      ConsP v p' ->
                         do b <- liftIO $ cancelP p 
                            if b then local (\_ -> p') a
                                 else neverM

cancelM :: AsyncM a
cancelM = asyncM $ \p _ -> cancelP p >> return ()

ifAliveM :: AsyncM ()
ifAliveM = asyncM $ \p k -> ifAliveP p $ k $ Right ()

