import time

import threading

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

    
def runM(a, p=None, k=lambda x: x):
    '''
    runM :: AsyncM a -> Progress -> ((Either String a) -> IO ()) -> IO ()
    '''
    if not p:
        p = Progress()
    a.f(p)(k)

def runM_(a, k=lambda x: x):
    '''
    Run ~a~ using continuation ~k~.

    If ~a~ has an error, print it.
    Otherwise, continue down the bind chain.
    '''
    def k(e):
        if is_left(e):
            print(e.x)
        else:
            return k(e.x)
    a.f(Progress())(k)
    
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
	done = False;
        def kp(x):
            if not done:
                done = True
                k(x)
	runM(a1, p1, kp)
	runM(a2, p2, kp)
    return asyncM(do)

def allM(a1, a2):
    def do(p, k):
        m1 = Unit()
        m2 = Unit()

        def kp(pair):
            def f(x):
                nonlocal m1, m2
                if m2 == Unit():
                    m1 = x
                    if is_left(x):
                        return k(Left(x.x))
                    else:
                        return Unit()
                else:
                    y = m2
                    
            return f
                
                
        runM(a1, p, handle_e)
        
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
            time.sleep(ms/1000)
            k(Right(Unit()))
            
        t = threading.Thread(target=g) # TODO: replace this with some more lightweight form of threads
        t.start()
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

class Either:
    def __init__(self, x, t):
        self.x = x
        self.t = t

    def bind(self, mf):
        if is_right(self):
            return mf(self.x)
        return self
        
EITHER_RIGHT_TYPE = 0
EITHER_LEFT_TYPE = 1

def Left(x):
    return Either(x, EITHER_LEFT_TYPE)

def is_left(e):
    return isinstance(e, Either) and e.t == EITHER_LEFT_TYPE

def Right(x):
    return Either(x, EITHER_RIGHT_TYPE)
    
def is_right(e):
    return isinstance(e, Either) and e.t == EITHER_RIGHT_TYPE

UNIT = object()
def Unit():
    return UNIT

def test1():
    '''
    Wait 10 seconds, then get the system time, map the Progress object to a non-sense value of 3

    This proves that the progress value is threaded properly in AsyncM objects, and that ~local~ works.
    The test should print the system time along with 3.
    '''
    runM_(timeout(10000).bind(lambda _: time.time()) \
        .bind(lambda t: AsyncM.ask() \
              .bind(lambda p: print(t, p))).local(lambda p: 3))

def test2():
    '''
    Tests that errors work. If AsyncM.error is returned in a bind,
    the following computations should be skipped, and the error message should be displayed
    (because we are using runM_ and the behavior is that it prints the error message)
    '''
    runM_(timeout(1000).bind(lambda _: time.time()) \
          .bind(lambda t: AsyncM.error('You should see this message.')) \
          .bind(lambda t: print('This shouldn\'t show.', t)))

if __name__ == '__main__':
    test2()
