from asyncm import asyncM, runM_, raceM, timeout
from haskell import *

class Emitter:
    def __init__(self, a=None):
        self.a = liftMaybe(a)
        '''
        Maybe is used to differentiate a value of None and an empty value.
        It could be that someone wants to emit a None value afterall.
        '''
        self.ks = []

    def add(self, k):
        self.ks = [k] + self.ks

def newEmitter(a):
    return Emitter(a)

def newEmitter_():
    return Emitter()

def emit(e, a):
    e.a = Just(a) # TODO: Protect against race condition
    for k in e.ks:
        k(a)
    e.ks = [] # TODO: Protect against race condition

def listen(e):
    return asyncM(lambda p, k: e.add(k))

def waitE(e):
    def do(p, k):
        if is_just(e.a):
            return k(e.a.x)
        else:
            return listen(e)
    return asyncM(do)

def now(e): # assumes that the emitter has a value
    return e.a.x

def forkM(a):
    e = newEmitter_()
    runM_(a, p, lambda x: emit(e, x))
    return k(Right(waitE(e)))

def testsuite():
    # Can get the value using now(...)
    e = newEmitter(3)
    assert now(e) == 3

    # Basic callback registration
    xs = []
    def add():
        e.add(lambda x: xs.append(x))
    add()
    emit(e, 'a')
    assert xs[0] == 'a'

    # If there are two callbacks, both should be called
    xs = []
    add()
    add()
    emit(e, 8)
    assert xs[0] == 8
    assert xs[1] == 8

    # calling "emit" removes all registered callbacks
    # so the following code should do nothing (but set the emitters latest value)
    emit(e, 10)
    assert len(xs) == 2
    assert now(e) == 10

    # One AsyncM listens to an emitter, and appends to the xs list
    # Another AsyncM emits an event to that same emitter
    # When it is done, make sure 
    xs = []
    def checkAssertion(_):
        assert xs == [30]
        print('All tests passed')
        
    runM_(raceM(listen(e).bind(lambda x: xs.append(x)),
                timeout(4000).bind(lambda _: emit(e, Right(30)))) \
          .bind(checkAssertion))

if __name__ == '__main__':
    testsuite()
