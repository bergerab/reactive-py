'''
Some classes/functions that help make Python feel more Haskell-like
'''

# Either monad

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

# Maybe type

MAYBE_JUST_TYPE = 0
MAYBE_NOTHING_TYPE = 1

class Maybe:
    def __init__(self, x, t):
        self.x = x
        self.t = t

def Just(x):
    return Maybe(x, MAYBE_JUST_TYPE)

def Nothing():
    return Maybe(None, MAYBE_NOTHING_TYPE)

def is_just(m):
    return m.t == MAYBE_JUST_TYPE

def is_nothing(m):
    return m.t == MAYBE_NOTHING_TYPE

def liftMaybe(x):
    '''
    Lifts a Python value into a Maybe type
    '''
    if x == None:
        return Nothing()
    return Just(x)

# Unique unit value

UNIT = object()
def Unit():
    return UNIT
