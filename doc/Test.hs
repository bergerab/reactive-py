
import Reactive
import AsyncM
import Control.Monad.IO.Class


test1 = do let s = interval 100 10
           run s print

test1'= do let s = takeS 10 $ foreverS 10
           run s print

test2 = do let s = do s1 <- multicast $ interval 100 10
                      s1
           run s print

test2'= do let s = do s1 <- multicast $ interval 1000 5
                      let s2 = fmap (+) s1
                      s2 <*> s1  
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

test11= do let s = do let s1 = interval 120 10
                      let s2 = interval 40 30
                      (pure (,) `appS` s1) `appS` s2
           run s print

test01= do let s = do s1 <- multicast $ interval 120 10
                      s2 <- multicast $ interval 40 30
                      (pure (,) `appS` s1) `appS` s2
           run s print

test12= do let s = do let s1 = interval 100 2
                      let s2 = interval 50 4
                      let s3 = interval 25 8
                      pure (.) <*> ((,) <$> s1) <*> ((,) <$> s2) <*> s3
           run s print

test13= do let s = do let s1 = interval 100 2
                      let s2 = interval 50 4
                      let s3 = interval 25 8
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

test17= do let s = do s1 <- multicast $ interval 100 10
                      let s2 = interval 50 20 
                      s3 <- multicast $ accumulate 0 (fmap (+) s2)
                      x <- s1
                      y <- s3
                      return (x,y)
           run s print

-- find the throughput of first 1000 ms 
test18= do let s = interval 10 200
           runM_ (countS 1000 s) $ print

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

test21= do let s = do s2 <- multicast $ interval 100 10
                      let s1 = reactimate 50 $ push2pull s2 
                      s1 `untilS` (timeout 500 >> return (return 100))
           run s print

-- fetch delayed signal
test22= do let s = do s1 <- multicast $ interval 100 10
                      let g = fetchG $ (\x -> timeout (10^3) >> return x) <$> s1 
                      reactimate 100 g 
           run s print

sensor s dt = (*dt) <$> s

test23= do let s = do s1 <- multicast $ interval 10 200
                      
                      let f dt = s2 `untilS` ms
                           where s2 = sensor s1 dt 
                                 ms = do timeout 100
                                         x <- countS 100 s2 
                                         if x < div 100 dt 
                                            then return $ f (10*dt) 
                                            else ms
                      f 1

           run (takeS 50 s) print


dataRequest :: Int -> AsyncM Int
dataRequest dt = do timeout $ dt + 150
                    return $ 1 * dt 

test24= do let f dt = do s <- multicast $ requestS dataRequest dt dt
                         let ms = do x <- speedS (dt*10) s
                                     liftIO $ print x
                                     if x < 0.9
                                     then return $ f $ 2*dt
                                     else ms
                         s `untilS` ms 
                           
           run (takeS 30 (f 10)) print 

