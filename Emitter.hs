
module Emitter
  ( 
    Emitter (..)
  , newEmitter
  , emit
  , listen
  , now
  , runE
  , foldE
  , newEmitter_
  , forkM
--  , waitE
  ) where

import Control.Monad (forM_)
import Control.Monad.Cont (ContT (..), liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Concurrent (MVar (..), newMVar, swapMVar, modifyMVar_, readMVar, newEmptyMVar, tryTakeMVar, putMVar)
import AsyncM (AsyncM (..), ifAliveM, runM, asyncM)

data Emitter a = Emitter (MVar a) -- the previous event value
                         (MVar [a -> IO ()]) -- registered callback
 
-- new emitter has an initial value
-- but there is no registered callback
newEmitter a = pure Emitter <*> newMVar a <*> newMVar [] 

-- make a blank emitter
newEmitter_ = pure Emitter <*> newEmptyMVar <*> newMVar [] 

-- save 'a' as the previous event
-- emit 'a' to registered callbacks if exist
emit :: Emitter a -> a -> IO ()
emit (Emitter av kv) a = do 
    tryTakeMVar av
    putMVar av a 
    lst <- swapMVar kv []
    forM_ lst $ \k -> k a

-- register callback 'k' on the emitter
listen :: Emitter a -> AsyncM a
listen (Emitter _ kv) = AsyncM $ lift $ lift $ ContT (\k -> modifyMVar_ kv $ \lst -> return (k:lst)) 

-- check whether an event value already exists, if so, return that value
-- otherwise, listen to new event value
waitE :: Emitter a -> AsyncM a
waitE (Emitter av kv) = AsyncM $ lift $ lift $ ContT (\k -> 
          do a <- tryTakeMVar av 
             case a of Just x -> putMVar av x >> k x
                       Nothing -> modifyMVar_ kv $ \lst -> return (k:lst)) 

-- This is blocking!
now (Emitter av _) = readMVar av 

runE :: Emitter a -> (a -> IO ()) -> AsyncM ()
runE e k = let h = do x <- listen e 
                      ifAliveM
                      liftIO $ k x
                      h 
           in h

foldE :: Emitter a -> (b -> a -> IO b) -> b -> AsyncM ()
foldE e f b = let h b = do a <- listen e
                           ifAliveM
                           b <- liftIO $ f b a
                           h b
              in h b
                           
-- run 'm' and put its value inside an emitter 'e', and return a new AsyncM that waits for the result in 'e'
forkM :: AsyncM a -> AsyncM (AsyncM a)
forkM m = asyncM $ \p k -> do
   e <- newEmitter_
   runM m p (either print $ emit e) -- use 'async' here ?
   k $ Right $ waitE e

