

class Progress:
    def __init__(self):
        # TODO: does it matter that these don't use anything with MVar semantics?
        self.cancelV = False
        self.cancelCB = []
        self.advanceCB = []

    def ifAlive(self, f):
        if self.cancelV:
            f()

    def advance(self):
        for cb in self.advanceCB:
            cb()

    def cancel(self):
        self.cancelV = True
        for cb in self.cancelCB:
            cb()

    def onAdvance(self, handle):
        self.advanceCB.append(handle)

    def onCancel(self, handle):
        self.cancelCB.append(handle)
        
    def linkP(self):
        p = Progress()
        self.onCancel(lambda: p.cancel())
        p.onAdvance(lambda: self.advance())
        return p

    def noEmitP(self):
        p = Progress
        self.onCancel(lambda: p.cancel())
        return p

    def raceP(self):
        p1 = Progress()
        p2 = Progress()
        p1.onAdvance(lambda: [p2.cancel(), self.advance()])
        p2.onAdvance(lambda: [p1.cancel(), self.advance()])
        self.onCancel(lambda: [p1.cancel(), p2.cancel()])
        return (p1, p2)
    
