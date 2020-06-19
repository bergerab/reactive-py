
module Progress
 (
   Progress (..)
 , nilP
 , consP
 , cancelP
 , isAliveP
 , ifAliveP
 , tailP
 ) where

import Control.Concurrent (putMVar, newEmptyMVar, isEmptyMVar, MVar(..))

data Progress = NilP (MVar ())
              | ConsP (MVar()) Progress

nilP :: IO Progress
nilP = pure NilP <*> newEmptyMVar 

consP :: Progress -> IO Progress
consP p = do v <- newEmptyMVar
             return $ ConsP v p

tailP (NilP v) = NilP v
tailP (ConsP _ p) = p

cancelP :: Progress -> IO Bool
cancelP p = let v = getV p
            in do b <- isEmptyMVar v
                  if b then putMVar v () >> return True else return False
 where getV (NilP v) = v
       getV (ConsP v _) = v

isAliveP :: Progress -> IO Bool
isAliveP (NilP v) = isEmptyMVar v
isAliveP (ConsP v p) = do b <- isEmptyMVar v 
                          if b then isAliveP p
                               else return False

ifAliveP :: Progress -> IO () -> IO ()
ifAliveP p a = do b <- isAliveP p
                  if b then a else return ()


