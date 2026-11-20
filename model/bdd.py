"""Minimal reduced ordered binary decision diagram (ROBDD) package.

A node is (level, low, high): "if variable at this level is 0 go to low, else high".
Nodes 0 and 1 are the constant FALSE / TRUE terminals. Two rules keep it reduced:
  * no node with low == high (that test would be redundant)
  * no two nodes with the same (level, low, high)   (unique table -> sharing)
With a fixed variable order this makes the BDD canonical: two functions are equal
exactly when they are the same node, which is how equivalence is proven.
"""

from itertools import product

import numpy as np

FALSE, TRUE = 0, 1


class BDD:
    def __init__(self, var_order):
        """var_order: variable names, top (tested first) to bottom."""
        self.vars = list(var_order)
        self.level = {v: i for i, v in enumerate(self.vars)}
        n = len(self.vars)
        self.nodes = [(n, None, None), (n, None, None)]   # terminals sit below every level
        self._unique = {}
        self._ite_cache = {}

    # ------------------------------------------------------------ construction
    def mk(self, level, low, high):
        if low == high:
            return low
        key = (level, low, high)
        node = self._unique.get(key)
        if node is None:
            node = len(self.nodes)
            self.nodes.append(key)
            self._unique[key] = node
        return node

    def var(self, name):
        return self.mk(self.level[name], FALSE, TRUE)

    def _cofactor(self, u, level, value):
        lvl, low, high = self.nodes[u]
        if lvl != level:
            return u
        return high if value else low

    def ite(self, f, g, h):
        """if-then-else: the universal BDD operation (f AND g) OR (NOT f AND h)."""
        if f == TRUE:
            return g
        if f == FALSE:
            return h
        if g == h:
            return g
        if g == TRUE and h == FALSE:
            return f
        key = (f, g, h)
        cached = self._ite_cache.get(key)
        if cached is not None:
            return cached
        top = min(self.nodes[f][0], self.nodes[g][0], self.nodes[h][0])
        low = self.ite(*(self._cofactor(x, top, 0) for x in (f, g, h)))
        high = self.ite(*(self._cofactor(x, top, 1) for x in (f, g, h)))
        result = self.mk(top, low, high)
        self._ite_cache[key] = result
        return result

    def NOT(self, f):
        return self.ite(f, FALSE, TRUE)

    def AND(self, f, g):
        return self.ite(f, g, FALSE)

    def OR(self, f, g):
        return self.ite(f, TRUE, g)

    def XOR(self, f, g):
        return self.ite(f, self.NOT(g), g)

    def cube(self, literals):
        """AND of literals given as {name: 0/1}."""
        u = TRUE
        for name, value in literals.items():
            v = self.var(name)
            u = self.AND(u, v if value else self.NOT(v))
        return u

    def from_truth_table(self, inputs, n_out, func):
        """BDDs of all outputs of func by Shannon expansion over the variable order.

        inputs: input names, MSB first, defining how func's integer argument is packed.
        func(value) -> integer whose bit (n_out-1-k) is output k.
        Returns a list of n_out root nodes.
        """
        pos = {name: len(inputs) - 1 - i for i, name in enumerate(inputs)}
        n = len(self.vars)

        def rec(level, value):
            if level == n:
                out = func(value)
                return tuple(TRUE if (out >> (n_out - 1 - k)) & 1 else FALSE for k in range(n_out))
            lo = rec(level + 1, value)
            hi = rec(level + 1, value | (1 << pos[self.vars[level]]))
            return tuple(self.mk(level, l, h) for l, h in zip(lo, hi))

        return list(rec(0, 0))

    # ---------------------------------------------------------------- queries
    def evaluate(self, u, assignment):
        while u > TRUE:
            lvl, low, high = self.nodes[u]
            u = high if assignment[self.vars[lvl]] else low
        return u

    def count_nodes(self, roots):
        """Number of distinct non-terminal nodes reachable from the roots (shared)."""
        seen, stack = set(), list(roots)
        while stack:
            u = stack.pop()
            if u > TRUE and u not in seen:
                seen.add(u)
                _, low, high = self.nodes[u]
                stack += [low, high]
        return len(seen)

    def to_dot(self, roots):
        """Graphviz text for {output name: root}. Dashed edge = 0, solid = 1."""
        lines = ["digraph BDD {", "  rankdir=TB;", '  n0 [label="0", shape=box];', '  n1 [label="1", shape=box];']
        seen, stack = set(), list(roots.values())
        while stack:
            u = stack.pop()
            if u > TRUE and u not in seen:
                seen.add(u)
                lvl, low, high = self.nodes[u]
                lines.append('  n{} [label="{}", shape=circle];'.format(u, self.vars[lvl]))
                lines.append("  n{} -> n{} [style=dashed];".format(u, low))
                lines.append("  n{} -> n{};".format(u, high))
                stack += [low, high]
        for name, u in roots.items():
            lines.append('  "{}" [shape=plaintext];'.format(name))
            lines.append('  "{}" -> n{};'.format(name, u))
        lines.append("}")
        return "\n".join(lines)


def node_count_for_order(table, inputs, order):
    """Shared ROBDD size of a multi-output function for one variable order, without building it.

    Uses the classic characterisation: the number of nodes labelled with the i-th
    variable equals the number of distinct subfunctions, obtained by fixing the first
    i-1 variables, that actually depend on the i-th variable. Fast enough to try all
    8! = 40320 orders of the multiplier.

    table: array of shape (2**n_in, n_out), row index packed MSB-first as in `inputs`.
    """
    n = len(inputs)
    n_out = table.shape[1]
    # axis k of t is input k (MSB first); move axes into BDD order, outputs first
    t = table.reshape((2,) * n + (n_out,))
    t = np.moveaxis(t, -1, 0)
    t = np.transpose(t, [0] + [1 + inputs.index(v) for v in order])
    total = 0
    for i in range(n):
        # rows = every (output, assignment of the first i variables); columns = remaining subtable
        sub = t.reshape(n_out * (2 ** i), 2, 2 ** (n - i - 1))
        depends = np.any(sub[:, 0, :] != sub[:, 1, :], axis=1)
        if np.any(depends):
            total += len(np.unique(sub[depends].reshape(int(depends.sum()), -1), axis=0))
    return total


def all_assignments(names):
    for bits in product((0, 1), repeat=len(names)):
        yield dict(zip(names, bits))
