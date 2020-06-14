import time

import threading


class AsyncM:
    def __init__(self, e):
        # f :: Progress -> (() -> IO()) -> IO ()
        self.e = e

    def bind(self, mf):
        pass

def runM(a, p, k):
    a.e.bind(lambda f: f(p)(k))

def runM_(a, p, k):
    runM(a, p, lambda e: e.bind(lambda x: k(x)))
    
def asyncM(f):
    return AsyncM(Right(lambda p: lambda k: f(p, k)))

def neverM():
    return asyncM(lambda p, k: Unit())

def ifAliveM():
    asyncM(lambda p, k: ifAlive(p, lambda: k(Right(Unit()))))

def timeout(ms):
    def f(p, k):
        def g():
            time.sleep(ms/1000)
            k(Right(Unit()))
            
        t = threading.Thread(target=g) # TODO: replace this with some more lightweight form of threads
        t.start()
    return asyncM(f)



# Progress Object

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


# Either Monad

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

if __name__ == '__main__':
   a = timeout(1000)
   runM_(a, Progress(), lambda x: print(x))
