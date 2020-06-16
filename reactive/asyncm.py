import time
import threading
import asyncio

from haskell import *

class AsyncM:
    def __init__(self, f):
        '''
        f :: Progress -> (Either String (a -> IO()) -> IO()) -> AsyncM a
        '''
        self.f = f

    def bind(self, mf):
        def lift(a):
            '''
            lift :: (a | AsyncM a) -> AsyncM a
            (where pipe operator means OR)
            
            Idempotently lift values into the monad (not the same as a ~return~ function)

            This is useful for the Python implementation, especially because IO isn't actually a monad here.
            For example, this feels natural in Python:
            
            timeout(100).bind(lambda x: print(x))

            Manually wrapping feels weird and unintuitive:
            
            timeout(100).bind(lambda x: AsyncM.lift(print(x)))

            On top of that ~print~ has the value of None, it isn't an IO Action. Having an AsyncM of type None
            is strange in the first place.
            '''
            if not isinstance(a, AsyncM):
                return AsyncM.lift(a)
            return a
        
        def f(p, k):
            def handle_e(e):
                if is_right(e):
                    return e.bind(lambda x: runM(lift(mf(x)), p, k))
                return k(e) # quit early
            runM(self, p, handle_e)
            
        return asyncM(f)

    def seq(self, mf):
        '''
        seq :: AsyncM a -> AsyncM b -> AsyncM b

        Analogous to >> in Haskell.
        '''
        return self.bind(lambda _: mf())

    @staticmethod
    def lift(x):
        '''
        lift :: a -> AsyncM a
        
        Analogous to ~return~ in Haskell.
        '''
        return asyncM(lambda p, k: k(Right(x)))

    @staticmethod
    def ask():
        '''
        ask :: AsyncM Progress
        
        Reader monad function for retreiving Progress object.
        '''
        return asyncM(lambda p, k: k(Right(p)))

    @staticmethod
    def error(m):
        '''
        error :: String -> AsyncM ()
        
        Indicate an error with message ~m~.
        '''
        return asyncM(lambda p, k: k(Left(m)))

    def local(self, f):
        '''
        local :: AsyncM a -> (Progress -> Progress) -> AsyncM a
        
        Reader monad function for creating an AsyncM with a modified Progress object.
        '''
        return AsyncM(lambda p: self.f(f(p)))

async def run(a):
    '''
    asyncio friendly version of runM

    Whenever the AsyncM completes, this function completes
    '''
    loop = asyncio.get_running_loop()    
    f = loop.create_future()
    runM_(a, None, lambda x: f.set_result(True))
    await f 
    
def runM(a, p=None, k=lambda x: x):
    '''
    runM :: AsyncM a -> Progress -> ((Either String a) -> IO ()) -> IO ()
    '''
    if not p:
        p = Progress()
    a.f(p)(k)

def runM_(a, p=None, k=lambda x: x):
    '''
    Run ~a~ using continuation ~k~.

    If ~a~ has an error, print it.
    Otherwise, continue down the bind chain.
    '''
    if not p:
        p = Progress()
    def kp(e):
        if is_left(e):
            print(e.x)
        else:
            return k(e.x)
    a.f(p)(kp)
    
def asyncM(f):
    '''
    asyncM :: (Progress -> ((Either String a) -> IO()) -> IO()) -> AsyncM a
    '''
    return AsyncM(lambda p: lambda k: f(p, k))

def neverM():
    '''
    neverM :: AsyncM ()

    Never calls the continuation.
    '''
    return asyncM(lambda p, k: Unit())

def noEmit(a):
    '''
    noEmit :: AsyncM a -> AsyncM a

    Make a AsyncM that doesn't advance when inner progress is made.
    '''
    return AsyncM.ask().bind(lambda p: a.local(lambda _: noEmitP(p)))

def oneEmit(a):
    noEmit(a).bind(lambda x: advM().bind(lambda _: x))

def forkM_(a):
    return asyncM(lambda p, k: \
                  AsyncM.lift(runM(a, p, lambda _: Unit())) \
                  .bind(lambda _: k(Right(Unit()))))

def raceM(a1, a2):
    def do(p, k):
        (p1, p2) = raceP(p)
        done = False
        def kp(x):
            nonlocal done
            if not done:
                done = True
                k(x)
        runM(a1, p1, kp)
        runM(a2, p2, kp)
    return asyncM(do)

def allM(a1, a2):
    def do(p, k):
        xs = [None, None]
        count = 0
        def kp(i):
            def kpp(x):
                nonlocal count
                
                if is_left(x): # TODO: this error handling isn't exactly the same as the Haskell version
                    return k(x)
                else:
                    xs[i] = x.x
                    
                count += 1
                if count == 2:
                    return k(Right(xs))
            return kpp
        
        runM(a1, p, kp(0))
        runM(a2, p, kp(1))
    return asyncM(do)
    
def advM():
    return AsyncM.ask().bind(lambda p: advance(p))

def ifAliveM():
    return asyncM(lambda p, k: ifAlive(p, lambda: k(Right(Unit()))))

def commitM():
    return ifAliveM().bind(lambda _: advM())

def timeout(ms):
    def f(p, k):
        def g():
            k(Right(Unit()))
        loop = asyncio.get_running_loop()            
        loop.call_later(ms/1000, g)
    return asyncM(f)

class Progress:
    def __init__(self):
        # TODO: does it matter that these don't use anything with MVar semantics?
        self.cancelV = False
        self.cancelCB = []
        self.advanceCB = []

def ifAlive(p, f):
    if p.cancelV:
        f()

def advance(p):
    for cb in p.advanceCB:
        cb()

def cancel(p):
    p.cancelV = True
    for cb in p.cancelCB:
        cb()

def onAdvance(p, handle):
    p.advanceCB.append(handle)

def onCancel(p, handle):
    p.cancelCB.append(handle)
        
def linkP(p1):
    p2 = Progress()
    onCancel(p1, lambda: cancel(p2))
    onAdvance(p2, lambda: advance(p1))
    return p2

def noEmitP(p1):
    p2 = Progress
    onCancel(p1, lambda: cancel(p2))
    return p2

def raceP(p):
    p1 = Progress()
    p2 = Progress()
    onAdvance(p1, lambda: [cancel(p2), advance(p)])
    onAdvance(p2, lambda: [cancel(p1), advance(p)])
    onCancel(p, lambda: [cancel(p1), cancel(p2)])
    return (p1, p2)

async def test1():
    '''
    Wait 10 seconds, then get the system time, map the Progress object to a non-sense value of 3

    This proves that the progress value is threaded properly in AsyncM objects, and that ~local~ works.
    The test should print the system time along with 3.
    '''
    await run(timeout(10000).bind(lambda _: time.time()) \
              .bind(lambda t: AsyncM.ask() \
              .bind(lambda p: print(t, p))).local(lambda p: 3))

async def test2():
    '''
    Tests that errors work. If AsyncM.error is returned in a bind,
    the following computations should be skipped, and the error message should be displayed
    (because we are using runM_ and the behavior is that it prints the error message)
    '''
    runM_(timeout(1000).bind(lambda _: time.time()) \
          .bind(lambda t: AsyncM.error('You should see this message.')) \
          .bind(lambda t: print('This shouldn\'t show.', t)))

async def test3():
    '''
    Test racing AsyncMs
    '''
    await run(raceM(timeout(1000).bind(lambda _: print('First Done')),
                timeout(2000).bind(lambda _: print('Second Done'))) \
          .bind(lambda _: print('Should be immediately after "First Done".')))

async def test4():
    '''
    Basic timeout
    '''
    await run(timeout(5000).bind(lambda _: print('Message delayed by 5s')))

async def test5():
    '''
    Combining timeouts
    '''
    await run(timeout(5000).bind(lambda _: timeout(5000).bind(lambda _: print('5s + 5s = 10s of delay'))))

async def test6():
    '''
    allM should wait to complete after both AsyncM arguments complete.
    '''
    await run(allM(timeout(2000).bind(lambda _: print('First')),
               timeout(5000).bind(lambda _: print('Second'))) \
          .bind(lambda _: print('Should be after both.')))

async def test7():
    '''
    Get two values from different AsyncM and add them together.
    '''
    await run(allM(timeout(2000).bind(lambda _: 10),
               timeout(5000).bind(lambda _: 80)) \
          .bind(lambda xs: print(xs[0], '+', xs[1], '=', sum(xs))))
    
if __name__ == '__main__':
    asyncio.run(test7())

