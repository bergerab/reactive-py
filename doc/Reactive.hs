
module Reactive 
  (
    Stream (..)
  , joinS 
  , runS 
  , run
  , liftS
  , firstS
  , leftApp
  , multicast
  , interval
  , accumulate
  , foldS
  , countS
  , untilS
  ) where

import Control.Monad (join)
-- import Control.Monad.Trans.Class
-- import Control.Concurrent
-- import Control.Concurrent.Async
-- import Data.Time
import Control.Monad.Cont (liftIO)
import AsyncM (AsyncM (..), ifAliveM, commitM, raceM, runM_, noEmit, timeout, neverM, forkM_, advM)
import Emitter (Emitter (..), newEmitter, emit, listen, now, newEmitter_, forkM)
import Control.Monad.IO.Class (MonadIO)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent (threadDelay)

newtype Stream a = Next { next :: AsyncM (a, Stream a) } 

-----------------------------------------------------------------------

instance MonadIO Stream where
  liftIO a = Next $ do x <- liftIO a
                       return (x, Next neverM)

instance Functor Stream where
  fmap f (Next m) = Next $ do (a, s) <- m
                              return (f a, fmap f s)

instance Applicative Stream where
  pure x = Next $ return (x, Next neverM)

  sf <*> sx = do
    f <- sf
    x <- sx
    return $ f x

instance Monad Stream where
  return = pure

  s >>= k = joinS $ fmap k s

{-
joinS :: Stream (Stream a) -> Stream a
joinS ss = Next $ next ss >>= h
 where h (s, ss) = raceM (do (a, s') <- noEmit $ next s 
                             commitM 
                             return (a, Next $ h (s', ss)))
                         (do rr <- noEmit $ next ss 
                             commitM
                             h rr)
--       f (s, ss) = do mss <- forkM $ next ss
--                      h (s, Next mss)
-}


joinS ss = Next $ do
   e <- liftIO $ newEmitter_

   let h (s, ss) = raceM (noEmit $ runS s $ emit e) 
                         (do rr <- noEmit $ next ss 
                             commitM   
                             h rr)
   forkM_ $ next ss >>= h
   next $ receive e


-----------------------------------------------------------------------

liftS :: AsyncM a -> Stream a
liftS ms = Next $ ms >>= next . pure

-- retrieve the first event of the stream s as a stream
firstS :: Stream a -> Stream a
firstS s = liftS $ fst <$> next s 

leftApp :: Stream (a -> b) -> Stream a -> Stream b
leftApp sf sx = sf <*> firstS sx

-----------------------------------------------------------------------

runS :: Stream a -> (a -> IO ()) -> AsyncM ()
runS s k = h s
   where h s = do ifAliveM
                  (a, s') <- next s
                  -- use 'async' to avoid blocking the stream with k.
                  liftIO $ async $ k a -- we need to use await here in Python
                  h s' 

run :: Stream a -> (a -> IO ()) -> IO ()
run s k = runM_ (runS s k) return 

-----------------------------------------------------------------------

broadcast :: Stream a -> AsyncM (Emitter a)
broadcast s = do 
     e <- liftIO newEmitter_ 
     forkM_ $ runS s $ emit e
     return e

receive :: Emitter a -> Stream a
receive e = Next $ do 
     a <- listen e
     ifAliveM
     return (a, receive e)

multicast :: Stream a -> Stream (Stream a)
multicast s = liftS $ receive <$> broadcast s

interval :: Int -> Int -> Stream Int
interval dt n = Next $ timeout 1 >> h n
     where h x = if x < 1 then neverM
                 else do ifAliveM
                         return (x, Next $ timeout dt >> h (x-1))

-----------------------------------------------------------------------

-- fold the functions emitted from s with the initial value a
accumulate :: a -> Stream (a -> a) -> Stream a
accumulate a (Next m) = Next $ do 
     (f, s) <- m
     let a' = f a
     return (a', accumulate a' s)

-- fold the functions emitted from s for n milli-second with the initial value c 
foldS :: Int -> a -> Stream (a -> a) -> AsyncM a
foldS n c s = do e <- liftIO $ newEmitter_ 
                 raceM (runS (accumulate c s) (emit e))
                       (timeout n >> advM) 
                 liftIO $ now e

-- emit the number of events of s for every n milli-second
countS :: Int -> Stream b -> AsyncM Int
countS n s = foldS n 0 $ (\b -> b+1) <$ s 

-- run s until ms occurs and then runs the stream in ms
untilS :: Stream a -> AsyncM (Stream a) -> Stream a
{-
untilS s ms = Next $ do ms' <- forkM ms
                        next $ joinS $ Next $ return (s, liftS ms')
-}
untilS s ms = joinS $ Next $ return (s, liftS ms)

-----------------------------------------------------------------------

-- fetch data by sending requests as a stream of AsyncM and return the results in a stream
fetchS :: Stream (AsyncM a) -> Stream a
fetchS sm = Next $ do
     c <- liftIO newChan
     let h sm = do (m, sm') <- next sm 
                   m' <- forkM m
                   liftIO $ writeChan c m'
                   h sm'
     forkM_ $ h sm
     let f = do m <- liftIO $ readChan c
                a <- m
                return (a, Next f)
     f

-----------------------------------------------------------------------

-- pull-based stream
newtype Signal a = Signal { runSignal ::  IO (a, Signal a) }

-- buffer events from stream s as a signal
push2pull :: Stream a -> AsyncM (Signal a)
push2pull s =  do 
     c <- liftIO newChan
     forkM_ $ runS s (writeChan c) 
     let f = do a <- liftIO $ readChan c
                return (a, Signal f)
     return $ Signal f

-- run k for each event of the signal s
bindG :: Signal a -> (a -> IO b) -> Signal b
bindG s k = Signal $ do 
     (a, s') <- runSignal s
     b <- k a
     return (b, bindG s' k)

-- fetch data by sending requests as a stream and return the results in the order of the requests
fetch :: Stream a -> (a -> IO b) -> AsyncM (Signal b)
fetch s k = do 
     g <- (push2pull $ s >>= liftIO . async . k) 
     return $ bindG g wait

-- run signal for each event from stream s
reactimate :: Stream b -> AsyncM (Signal a) -> Stream a
reactimate s ag = Next $ ag >>= h s 
  where h s g = do (_, s') <- next s
                   (a, g') <- liftIO $ runSignal g 
                   return (a, Next $ h s' g)

-----------------------------------------------------------------------

test1 = do let s = interval 100 10
           run s print

test2 = do let s = do s1 <- multicast $ interval 100 10
                      s1
           run s print

test3 = do let s = do let s1 = interval 100 10
                      (*10) <$> s1 
           run s print

test4 = do let s = do s1 <- multicast $ interval 100 10
                      (*10) <$> s1 
           run s print

test5 = do let s = do let s1 = interval 100 10
                      let s2 = interval 50 20
                      pure (,) <*> s1 <*> s2
           run s print

test6 = do let s = do s1 <- multicast $ interval 100 10
                      s2 <- multicast $ interval 50 20
                      pure (,) <*> s1 <*> s2
           run s print

test7 = do let s = do let s1 = interval 100 10
                      let s2 = interval 50 20
                      x <- s1
                      y <- s2
                      return (x,y)
           run s print

test8 = do let s = do s1 <- multicast $ interval 100 10
                      s2 <- multicast $ interval 50 20
                      s3 <- multicast $ interval 25 40
                      x <- s1
                      y <- s2
                      z <- s3
                      return (x,y,z)
           run s print

-- flapjax example on glitching
test9 = do let s = do s1 <- multicast $ interval 100 10
                      y <- s1
                      let a = y + 0
                      let b = y + a
                      let c = b + 1
                      let d = mod c 2
                      return (y, a, b, c, d)
           run s print

test10= do let s = do s1 <- multicast $ interval 100 10
                      s2 <- multicast $ interval 100 10
                      pure (,) <*> s1 <*> s2
           run s print

test12= do let s = do let s1 = interval 100 2
                      let s2 = interval 50 4
                      let s3 = interval 25 8
                      pure (.) <*> ((,) <$> s1) <*> ((,) <$> s2) <*> s3
           run s print

test13= do let s = do let s1 = interval 100 10
                      let s2 = interval 50 20
                      let s3 = interval 25 40
                      ((,) <$> s1) <*> (((,) <$> s2) <*> s3)
           run s print

test14= do let s = do s1 <- multicast $ interval 100 10
                      s2 <- multicast $ interval 50 20
                      s3 <- multicast $ interval 25 40
                      pure (.) <*> ((,) <$> s1) <*> ((,) <$> s2) <*> s3
           run s print

test15= do let s = do s1 <- multicast $ interval 100 10
                      s2 <- multicast $ interval 50 20
                      s3 <- multicast $ interval 25 40
                      ((,) <$> s1) <*> (((,) <$> s2) <*> s3)
           run s print

-- fetch delayed signal
test16= do let s = do s1 <- multicast $ interval 100 10
                      let s2 = (\x -> timeout 1000 >> return x) <$> s1
                      fetchS s2
           run s print

test17= do let s = do s1 <- multicast $ interval 50 40
                      let s2 = interval 100 20 
                      s3 <- multicast $ accumulate 0 (fmap (+) s2)
                      x <- s1
                      y <- s3
                      return (x,y)
           run s print

-- find the throughput of first 1000 ms 
test18= do let s = interval 10 200
           runM_ (countS 1000 s) print

test19= do let s = do s1 <- multicast $ interval 100 100
                      s2 <- multicast $ interval 1000 10
                      -- leftApp (s2 >> pure id) s1
                      (pure (,) <*> s2) `leftApp` s1
           run s print

test20= do let s = do let s1 = interval 100 100
                      s2 <- multicast $ interval 1000 10
                      --- leftApp (s2 >> pure id) s1
                      (pure (,) <*> s1) `leftApp` s2
           run s print

test21= do let s = do let s1 = interval 100 10
                      s2 <- multicast $ interval 1000 10
                      reactimate s1 $ push2pull s2
           run s print

-- fetch delayed signal
test22= do let s = do s1 <- multicast $ interval 100 10
                      let s2 = interval 100 10
                      let g = fetch s1 (\x -> threadDelay (10^6) >> return x) 
                      reactimate s2 g 
           run s print

sensor s dt = (*dt) <$> s

test23= do let s = do s1 <- multicast $ interval 10 50
                      
                      let f dt = s2 `untilS` ms
                           where s2 = sensor s1 dt
                                 ms = do timeout 100
                                         x <- countS 100 s2 
                                         if x < div 100 dt 
                                            then return $ f (10*dt) 
                                            else ms
                      f 1

           run s print

{-
main = do 
          -- let s3 = interval 1000 12
          -- let s2 = interval 2000 6
          -- let s1 = interval 3000 4
          let s = do s3 <- multicast $ interval 1000 12
                     s1 <- multicast $ interval 3000 4
                     pure (,) <*> s1 <*> s3
          -- let s = (pure $ (,) 10) <*> s2
          -- let s = do { x <- s1; z <- s3; return (x,z) }
          run s print
-}

