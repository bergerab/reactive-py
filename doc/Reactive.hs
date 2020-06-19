
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
  , interval'
  , accumulate
  , foldS
  , countS
  , untilS
  , appS
  , reactimate
  , fetchG
  , fetchS
  , speedS
  , requestS
  , push2pull
  , takeS
  , foreverS
  , stopS
  ) where

import Control.Monad (join)
import Control.Monad.Reader (ReaderT (..))
import Control.Monad.Cont (liftIO)
import AsyncM (AsyncM (..), ifAliveM, raceM, runM_, timeout, neverM, forkM_, advM, cancelM)
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

joinS :: Stream (Stream a) -> Stream a
joinS ss = Next $ do
   e <- liftIO $ newEmitter_

   let h (s, ss) = raceM (runS s $ emit e) 
                         (do rr <- next ss 
                             advM $ h rr)
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
   where h s = do (a, s') <- next s
                  ifAliveM
                  -- use 'async' to avoid blocking the stream with k.
                  liftIO $ async $ k a
                  h s' 

run :: Stream a -> (a -> IO ()) -> IO ()
run s k = runM_ (runS s k) return 

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

-----------------------------------------------------------------------


appS :: Stream (a -> b) -> Stream a -> Stream b  
appS sf sx = Next $ do
     ef <- liftIO $ newEmitter_
     ex <- liftIO $ newEmitter_
     e <- liftIO $ newEmitter_
     let flr f x = do liftIO $ emit e (f x)
                      raceM (listen ef >>= advM . flip flr x) (listen ex >>= advM . flr f)
     let fr x    = raceM (listen ef >>= advM . flip flr x) (listen ex >>= advM . fr)
     let fl f    = raceM (listen ef >>= advM . fl)         (listen ex >>= advM . flr f)
     let fs      = raceM (listen ef >>= advM . fl)         (listen ex >>= advM . fr)
     forkM_ fs
     forkM_ $ runS sf $ emit ef 
     forkM_ $ runS sx $ emit ex
     next $ receive e

{-
type IStream a = (a, Stream a)

appS :: Stream (a -> b) -> Stream a -> Stream b  
appS sf sx = Next $ do 
     mf <- forkM $ next sf
     mx <- forkM $ next sx
     raceM (do isf <- mf
               advM $ next $ appL isf $ Next mx)
           (do isx <- next sx
               advM $ next $ appR (Next mf) isx)

appL :: IStream (a -> b) -> Stream a -> Stream b
appL (f, sf) sx = Next $ do
     mf <- forkM $ next sf
     mx <- forkM $ next sx
     raceM (do isf <- mf
               advM $ next $ appL isf $ Next mx)
           (do isx <- mx
               advM $ return $ appLR (f, Next mf) isx)

appR :: Stream (a -> b) -> IStream a -> Stream b
appR sf (x, sx) = Next $ do
     mf <- forkM $ next sf
     mx <- forkM $ next sx
     raceM (do isf <- mf
               advM $ return $ appLR isf (x, Next mx))
           (do isx <- mx
               advM $ next $ appR (Next mf) isx)

appLR :: IStream (a -> b) -> IStream a -> IStream b
appLR (f, sf) (x, sx) = (f x, Next $ do 
     mf <- forkM $ next sf
     mx <- forkM $ next sx
     raceM (do isf <- mf
               advM $ return $ appLR isf (x, Next mx))
           (do isx <- mx
               advM $ return $ appLR (f, Next mf) isx))
-}


-----------------------------------------------------------------------

repeatS :: AsyncM a -> Stream a
repeatS m = Next $ do
     a <- m
     ifAliveM
     return (a, repeatS m)

foreverS :: Int -> Stream ()
foreverS dt = repeatS $ timeout dt

zipWithS :: (a -> b -> c) -> [a] -> Stream b -> Stream c
zipWithS f lst s = Next $ h lst s 
  where h [] _ = neverM
        h (a:lst') s = do (b, s') <- next s
                          return (f a b, Next $ h lst' s')

-- take the first n events. If n <= 0, then nothing
-- if 's' has less than n events, the 'takeS n s' emits all events of s
takeS :: Int -> Stream a -> Stream a
takeS n s | n <= 0 = Next cancelM 
          | otherwise = Next $ do (a, s') <- next s
                                  return (a, takeS (n-1) s')

-- drop the first n events
-- if 's' has less than n events, then 'dropS s' never starts.
dropS :: Int -> Stream a -> Stream a
dropS n s | n <= 0 = s 
          | otherwise = Next $ do (_, s') <- next s
                                  next $ dropS (n-1) s' 

-- wait dt milliseconds and then start 's'
waitS :: Time -> Stream a -> Stream a
waitS dt s = Next $ do timeout dt  
                       next s

-- skip the events of the first dt milliseconds  
skipS :: Time -> Stream a -> Stream a
skipS dt s = do s' <- multicast s 
                waitS dt s'

-- delay each event of 's' by dt milliseconds
delayS :: Time -> Stream a -> Stream a
delayS dt s = Next $ do (a, s') <- next s
                        timeout dt
                        return (a, delayS dt s')

-- stop 's' after dt milliseconds
stopS :: Time -> Stream a -> Stream a
stopS dt s = s `untilS` do timeout dt 
                           return $ Next neverM

-- start the first index after dt
interval' dt n = zipWithS const lst $ foreverS dt
  where lst = take n [1..] 

-- start the first index after 1 ms delay
interval :: Int -> Int -> Stream Int
interval dt n = Next $ timeout 1 >> h 1
  where h x = if x > n then neverM
              else do ifAliveM
                      return (x, Next $ timeout dt >> h (x+1))

-----------------------------------------------------------------------

-- fold the functions emitted from s with the initial value a
accumulate :: a -> Stream (a -> a) -> Stream a
accumulate a (Next m) = Next $ do 
     (f, s) <- m
     let a' = f a
     return (a', accumulate a' s)

-- fold the functions emitted from s for dt milli-second with the initial value c 
foldS :: Time -> a -> Stream (a -> a) -> AsyncM a
foldS dt c s = do e <- liftIO $ newEmitter c 
                  raceM (runS (accumulate c s) (emit e))
                        (timeout dt >> advM (return ())) 
                  liftIO $ now e

-- emit the number of events of s for every n milli-second
countS :: Int -> Stream b -> AsyncM Int
countS n s = foldS n 0 $ (\b -> b+1) <$ s 

-- run s until ms occurs and then runs the stream in ms
untilS :: Stream a -> AsyncM (Stream a) -> Stream a
untilS s ms = joinS $ Next $ return (s, liftS ms)

-----------------------------------------------------------------------

-- fetch data by sending requests as a stream of AsyncM and return the results in a stream
fetchS :: Stream (AsyncM a) -> Stream a
fetchS sm = Next $ do
     c <- liftIO newChan
     let h sm = do (m, sm') <- next sm 
                   ifAliveM
                   m' <- forkM m
                   liftIO $ writeChan c m'
                   h sm'
     forkM_ $ h sm
     let f = do m <- liftIO $ readChan c
                a <- m
                return (a, Next f)
     f

-- measure the data speed = total sample time / system time
speedS :: Time -> Stream (Time, a) -> AsyncM Float
speedS dt s = f <$> (foldS dt 0 $ (\(dt',_) t -> t + dt') <$> s)
  where f t = fromIntegral t / fromIntegral dt

-- call f to request samples with 'dt' interval and 'delay' between requests
requestS :: (Time -> AsyncM a) -> Time -> Time -> Stream (Time, a)
requestS f dt delay = (,) dt <$> s
  where s = fetchS $ f dt <$ foreverS delay

-----------------------------------------------------------------------

-- Pull-based stream
newtype Signal m a = Signal { runSignal ::  m (a, Signal m a) }

instance (Monad m) => Functor (Signal m) where
  fmap f (Signal m) = Signal $ do (a, s) <- m 
                                  return (f a, fmap f s)

instance (Monad m) => Applicative (Signal m) where
  pure a = Signal $ return (a, pure a)
 
  Signal mf <*> Signal mx = 
       Signal $ do (f, sf) <- mf
                   (x, sx) <- mx 
                   return (f x, sf <*> sx)

-- buffer events from stream s as a signal
push2pull :: Stream a -> AsyncM (Signal IO a)
push2pull s =  do 
     c <- liftIO newChan
     forkM_ $ runS s $ writeChan c 
     let f = do a <- liftIO $ readChan c
                return (a, Signal f)
     return $ Signal f

-- run k for each event of the signal s
bindG :: Signal IO a -> (a -> IO b) -> Signal IO b
bindG s k = Signal $ do 
     (a, s') <- runSignal s
     b <- k a
     return (b, bindG s' k)

-- fetch data by sending requests as a stream and return the results in the order of the requests
fetchG :: Stream (AsyncM a) -> AsyncM (Signal IO a)
fetchG s = push2pull $ fetchS s

-- run signal with event delay
reactimate :: Time -> AsyncM (Signal IO a) -> Stream a
reactimate delay ag = Next $ ag >>= h  
  where h g = do timeout delay
                 (a, g') <- liftIO $ runSignal g 
                 return (a, Next $ h g')


-----------------------------------------------------------------------
type Time = Int

-- Event is a signal of delta-time and value pairs
type Event a = Signal IO (Time, a)

-- Behavior is a signal of delta-time to value functions
type Behavior a = Signal (ReaderT Time IO) a


-- make an event out of a stream of AsyncM
fetchE :: Time -> (Time -> Stream (AsyncM a)) -> AsyncM (Event a)
fetchE dt k = do e <- fetchG $ k dt 
                 return $ (\b -> (dt, b)) <$> e

-- a behavior that synchronously fetches data, which is blocking and will experience all IO delays
fetchB :: (Time -> IO a) -> Behavior a
fetchB k = Signal $ ReaderT $ \t -> do a <- k t
                                       return (a, fetchB k)

-- Converts an event signal to a behavior signal 
-- downsample by applying the summary function
-- upsample by repeating events
stepper :: ([(Time, a)] -> a) -> Event a -> Behavior a
stepper summary ev = Signal $ ReaderT $ \t -> h t [] ev
 where h t lst ev = do 
         ((t', a), ev') <- runSignal ev   
         if (t == t') then return (f $ (t,a):lst, stepper summary ev') 
         else if (t < t') then return (f $ (t,a):lst, stepper summary $ Signal $ return ((t'-t, a), ev'))
         else h (t-t') ((t',a):lst) ev' 
       f [(t,a)] = a
       f lst = summary lst 
     
-- run behavior with event delay and sample delta-time
reactimateB :: Time -> Time -> AsyncM (Behavior a) -> Stream (Time, a)
reactimateB delay dt ag = Next $ ag >>= h  
  where h g = do timeout delay
                 (a, g') <- liftIO $ (runReaderT $ runSignal g) dt 
                 return ((dt, a), Next $ h g')

-- convert event of batches into event of samples
unbatch :: Event [a] -> Event a
unbatch eb = Signal $ do
     ((dt, b), eb') <- runSignal eb
     h dt b eb'
  where h _ [] eb' = runSignal $ unbatch eb'
        h dt (a:b) eb' = return ((dt, a), Signal $ h dt b eb') 

-- convert behavior to event of batches of provided size and delta-time
batch :: Time -> Int -> Behavior a -> Event [a]
batch dt size g = Signal $ h [] size g
  where h b n g
         | n <= 0 = return ((dt, b), batch dt size g)
         | otherwise = do (a, g') <- (runReaderT $ runSignal g) dt
                          h (b++[a]) (n-1) g'

-- factor >= 1
upsample :: Int -> Behavior a -> Behavior a
upsample factor b = Signal $ ReaderT $ \t -> 
  do (a, b') <- runReaderT (runSignal b) (factor * t)
     return $ h factor a b'
  where h 1 a b = (a, upsample factor b)
        h n a b = (a, Signal $ ReaderT $ \t -> return $ h (n-1) a b)

-- downsample a behavior with a summary function
-- since dt is Int, downsampling factor may not be greater than dt
downsample :: Int -> ([(Int, a)] -> a) -> Behavior a -> Behavior a
downsample factor summary b = Signal $ ReaderT $ \t -> 
  let t' = if t <= factor then 1 else t `div` factor 
      h 0 lst b = return (summary lst, downsample factor summary b)
      h n lst b = do (a, b') <- runReaderT (runSignal b) t'
                     h (n-1) ((t',a):lst) b' 
  in h factor [] b   

-- convert a behavior into event of sample windows of specified size, stride, and sample delta-time
-- resulting delta-time is 't * stride'
window :: Int -> Int -> Time -> Behavior a -> Event [a]
window size stride t b = Signal $ init size [] b
  where init 0 lst b = step 0 lst b
        init s lst b = do (a, b') <- (runReaderT $ runSignal b) t
                          init (s-1) (lst++[a]) b'
        step 0 lst b = return ((t*stride, lst), Signal $ step stride lst b)
        step d lst b = do (a, b') <- (runReaderT $ runSignal b) t
                          step (d-1) (tail lst ++ [a]) b'


-----------------------------------------------------------------------


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

