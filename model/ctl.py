"""Small explicit-state CTL model checker.

A model is a finite Kripke structure given by
  * initial states (hashable values, e.g. tuples)
  * successors(state) -> iterable of next states
  * atomic propositions: functions state -> bool
The reachable state graph is built by breadth-first search, then CTL formulas are
evaluated with the standard labelling algorithms (Clarke, Emerson, Sistla):
  EX f       states with a successor in [f]
  E[f U g]   least fixpoint     Z = [g] | ([f] & EX Z)
  EG f       greatest fixpoint  Z = [f] & EX Z
All other operators are derived: AX f = !EX !f, EF f = E[true U f], AG f = !EF !f,
AF f = !EG !f, A[f U g] = !(E[!g U (!f & !g)] | EG !g).

Formulas are nested tuples, e.g.  ("AG", ("->", ("ap", "key_valid"), ("ap", "ecc_ok"))).
For a failing AG property a shortest counterexample path from an initial state is
returned (for AG(p -> AG q): the path to a p-state continues to a !q state).
"""

from collections import deque


class Model:
    def __init__(self, initial, successors, props):
        self.props = props
        self.index = {}
        self.states = []
        self.succ = []
        self.parent = {}
        queue = deque()
        for s in initial:
            if s not in self.index:
                self._add(s)
                self.parent[s] = None
                queue.append(s)
        while queue:
            s = queue.popleft()
            nxt = []
            for t in successors(s):
                if t not in self.index:
                    self._add(t)
                    self.parent[t] = s
                    queue.append(t)
                nxt.append(self.index[t])
            self.succ[self.index[s]] = sorted(set(nxt))
        self.pred = [[] for _ in self.states]
        for i, ns in enumerate(self.succ):
            for j in ns:
                self.pred[j].append(i)
        self.init = {self.index[s] for s in initial}

    def _add(self, s):
        self.index[s] = len(self.states)
        self.states.append(s)
        self.succ.append([])

    @property
    def n_states(self):
        return len(self.states)

    @property
    def n_transitions(self):
        return sum(len(s) for s in self.succ)

    # ------------------------------------------------------------- labelling
    def sat(self, f):
        """Set of state indices satisfying formula f."""
        op = f[0]
        all_s = set(range(len(self.states)))
        if op == "true":
            return all_s
        if op == "false":
            return set()
        if op == "ap":
            fn = self.props[f[1]]
            return {i for i, s in enumerate(self.states) if fn(s)}
        if op == "!":
            return all_s - self.sat(f[1])
        if op == "&":
            return self.sat(f[1]) & self.sat(f[2])
        if op == "|":
            return self.sat(f[1]) | self.sat(f[2])
        if op == "->":
            return (all_s - self.sat(f[1])) | self.sat(f[2])
        if op == "EX":
            target = self.sat(f[1])
            return {i for i in all_s if any(j in target for j in self.succ[i])}
        if op == "EU":
            f1, z = self.sat(f[1]), set(self.sat(f[2]))
            work = deque(z)
            while work:
                j = work.popleft()
                for i in self.pred[j]:
                    if i not in z and i in f1:
                        z.add(i)
                        work.append(i)
            return z
        if op == "EG":
            z = set(self.sat(f[1]))
            changed = True
            while changed:                          # greatest fixpoint
                changed = False
                for i in list(z):
                    if not any(j in z for j in self.succ[i]):
                        z.discard(i)
                        changed = True
            return z
        # derived operators
        if op == "AX":
            return self.sat(("!", ("EX", ("!", f[1]))))
        if op == "EF":
            return self.sat(("EU", ("true",), f[1]))
        if op == "AG":
            return self.sat(("!", ("EF", ("!", f[1]))))
        if op == "AF":
            return self.sat(("!", ("EG", ("!", f[1]))))
        if op == "AU":
            nf, ng = ("!", f[1]), ("!", f[2])
            return self.sat(("!", ("|", ("EU", ng, ("&", nf, ng)), ("EG", ng))))
        raise ValueError("unknown operator " + op)

    def holds(self, f):
        return self.init <= self.sat(f)

    # ------------------------------------------------------- counterexamples
    def path_to(self, targets):
        """Shortest path (list of states) from an initial state to any target index."""
        prev = {i: None for i in self.init}
        queue = deque(self.init)
        while queue:
            i = queue.popleft()
            if i in targets:
                path = []
                while i is not None:
                    path.append(self.states[i])
                    i = prev[i]
                return path[::-1]
            for j in self.succ[i]:
                if j not in prev:
                    prev[j] = i
                    queue.append(j)
        return None

    def counterexample(self, f):
        """Witness path for the violation of AG g, or of AG(p -> AG q)."""
        if f[0] != "AG":
            return None
        g = f[1]
        bad = self.sat(("!", g))
        path = self.path_to(bad)
        if path and g[0] == "->" and g[2][0] == "AG":
            # continue from the p-state to a state violating the inner AG
            inner_bad = self.sat(("!", g[2][1]))
            start = self.index[path[-1]]
            prev = {start: None}
            queue = deque([start])
            while queue:
                i = queue.popleft()
                if i in inner_bad:
                    tail = []
                    while i is not None and i != start:
                        tail.append(self.states[i])
                        i = prev[i]
                    return path + tail[::-1]
                for j in self.succ[i]:
                    if j not in prev:
                        prev[j] = i
                        queue.append(j)
        return path


def show(f):
    """Formula as readable text."""
    op = f[0]
    if op in ("true", "false"):
        return op
    if op == "ap":
        return f[1]
    if op == "!":
        return "!" + show(f[1])
    if op in ("&", "|", "->"):
        return "(" + show(f[1]) + " " + op + " " + show(f[2]) + ")"
    if op in ("EU", "AU"):
        return op[0] + "[" + show(f[1]) + " U " + show(f[2]) + "]"
    return op + " " + show(f[1])
