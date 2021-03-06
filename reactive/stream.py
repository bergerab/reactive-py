import asyncio

from emitter import newEmitter_, listen
from asyncm import neverM, runM_, ifAliveM, runMAsync, asyncM, commitM, forkM_
from haskell import *

class Stream:
    def __init__(self, next):
        '''
        f :: AsyncM (a, Stream a)
        '''
        self.next = next

    @staticmethod
    def lift(x):
        return Stream(lambda: asyncM(lambda p, k: k(Right((x, Stream(lambda: neverM()))))))

    def fmap(self, f):
        def do(xs):
            (a, s) = xs
            return (f(a), s.fmap(f))
        return Stream(lambda: self.next().bind(do))

    def bind(self, k):
        return joinS(self.fmap(k))

def joinS(ss):
    e = newEmitter_()
    def h(s, ss):
        return raceM(noEmit(runS(s, lambda x: emit(e, x))), # TODO: CPython doesn't have TCO -- we will want to write this non-recursively
                     noEmit(ss.next()).bind(lambda rr: commitM().seq(lambda: h(rr))))
    forkM_(ss.next().bind(h))
    return receive(e).next()

def runS(s, k):
    def h(s):
        def run(xs):
            '''
            Launches a coroutine that performs continuation.
            '''
            (a, sp) = xs
            loop = asyncio.get_event_loop()
            async def coro():
                k(a)
            loop.create_task(coro())
            h(sp) # TODO: CPython doesn't have TCO -- we will want to write this non-recursively
        return ifAliveM().seq(lambda: s.next().bind(run))
    return h(s)

def run(s, k):
    runM_(runS(s, k))

async def runSAsync(s, k):
    await runMAsync(runS(s, k))

def receive(e):
    # TODO: CPython doesn't have TCO -- we will want to write this non-recursively    
    return Stream(lambda: listen(e).bind(lambda a: ifAliveM().seq(lambda: (a, receive(e)))))
    
async def test1():
    xs = []
    def test(x):
        assert xs[0] == 3        
    await runSAsync(Stream.lift(3).bind(lambda x: xs.append(x)), test)

async def test2():
    '''
    Test fmap.
    '''
    await runSAsync(Stream.lift(3).fmap(lambda x: x + 3), lambda x: print(x))

async def test3():
    await runSAsync(Stream.lift(3).bind(lambda x: print(x)), lambda x: x)
    
if __name__ == '__main__':
    asyncio.run(test3())
