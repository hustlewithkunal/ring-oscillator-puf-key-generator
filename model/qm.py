"""Quine-McCluskey two-level minimisation with an exact unate-covering step (our own
implementation, for comparison with ESPRESSO on the GF(2^4) blocks).

For each single output:
  1. prime implicants by iterated merging of cubes (Quine-McCluskey)
  2. prime implicant table (rows = ON-set minterms, columns = primes)
  3. unate covering problem (UCP): essential primes, row and column dominance,
     then branch and bound on the cyclic core (lower bound = maximal independent set
     of rows), giving a provably minimum number of product terms

Run from the project root:  python -m model.qm
"""

import itertools
import os
import time

from . import gf16 as gf


def primes(on, n):
    """Prime implicants of the ON-set as (value, mask) cubes: mask bit 1 = don't care."""
    current = {(m, 0) for m in on}
    result = set()
    while current:
        merged = set()
        used = set()
        groups = {}
        for v, m in current:
            groups.setdefault(m, []).append(v)
        for m, vals in groups.items():
            s = set(vals)
            for v in vals:
                for b in range(n):
                    bit = 1 << b
                    if m & bit or v & bit:
                        continue
                    if v | bit in s:
                        merged.add((v, m | bit))
                        used.add((v, m))
                        used.add((v | bit, m))
        result |= current - used
        current = merged
    return result


def covers(cube, minterm):
    v, m = cube
    return (minterm & ~m) == v


def literals(cube, n):
    return n - bin(cube[1]).count("1")


def min_cover(on, prime_list):
    """Exact minimum unate cover; returns the chosen primes."""
    rows = {m: frozenset(i for i, p in enumerate(prime_list) if covers(p, m)) for m in on}
    best = [None]

    def solve(rows, chosen):
        rows = dict(rows)
        chosen = list(chosen)
        changed = True
        while changed and rows:
            changed = False
            # essential columns: a row covered by a single column
            for r, cols in list(rows.items()):
                if r not in rows:
                    continue
                if len(cols) == 1:
                    c = next(iter(cols))
                    chosen.append(c)
                    for r2 in [r2 for r2, c2 in rows.items() if c in c2]:
                        del rows[r2]
                    changed = True
            # row dominance: drop a row whose column set contains another row's set
            items = list(rows.items())
            for r1, c1 in items:
                for r2, c2 in items:
                    if r1 != r2 and r1 in rows and r2 in rows and c2 < c1:
                        del rows[r1]
                        changed = True
                        break
            # column dominance: drop column j if some column k covers all rows of j
            cols = {}
            for r, cs in rows.items():
                for c in cs:
                    cols.setdefault(c, set()).add(r)
            for j, rj in cols.items():
                for k, rk in cols.items():
                    if j != k and rj <= rk and (rj < rk or j > k):
                        for r in rj:
                            if j in rows.get(r, ()):
                                rows[r] = rows[r] - {j}
                        changed = True
                        break
        if not rows:
            if best[0] is None or len(chosen) < len(best[0]):
                best[0] = chosen
            return
        # lower bound: greedy maximal set of pairwise column-disjoint rows
        indep, used_cols = 0, set()
        for r, cs in sorted(rows.items(), key=lambda t: len(t[1])):
            if not (cs & used_cols):
                indep += 1
                used_cols |= cs
        if best[0] is not None and len(chosen) + indep >= len(best[0]):
            return
        # branch on the row with the fewest columns
        r = min(rows, key=lambda x: len(rows[x]))
        for c in sorted(rows[r]):
            sub = {r2: cs for r2, cs in rows.items() if c not in cs}
            solve(sub, chosen + [c])

    solve(rows, [])
    return [prime_list[i] for i in best[0]]


def minimise(fn, n_in, n_out):
    """Per-output exact minimisation: list of (n_primes, n_terms, n_literals, seconds)."""
    out = []
    for k in range(n_out):
        on = [v for v in range(1 << n_in) if (fn(v) >> (n_out - 1 - k)) & 1]
        t0 = time.time()
        p = sorted(primes(on, n_in))
        cover = min_cover(on, p)
        assert all(any(covers(c, m) for c in cover) for m in on)
        assert not any(covers(c, m) for c in cover for m in range(1 << n_in) if m not in on)
        out.append((len(on), len(p), len(cover), sum(literals(c, n_in) for c in cover), time.time() - t0))
    return out


def main():
    rows = []
    for name, fn, n_in in (("gf_inv", lambda v: gf.INV_TABLE[v], 4),
                           ("gf_mul", lambda v: gf.MUL_TABLE[v >> 4][v & 0xF], 8)):
        res = minimise(fn, n_in, 4)
        for k, (on, np_, nt, nl, sec) in enumerate(res):
            rows.append("{:<7} output {}: {:>3} ON-minterms, {:>3} primes, minimum cover {:>3} terms / {:>3} literals ({:.2f} s)".format(
                name, 3 - k, on, np_, nt, nl, sec))
        rows.append("{:<7} total (no sharing between outputs): {} terms / {} literals".format(
            name, sum(r[2] for r in res), sum(r[3] for r in res)))
    text = "\n".join(rows)
    print(text)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "docs", "reports", "qm_results.txt")
    with open(path, "w", newline="\n") as f:
        f.write(text + "\n")
    print("saved", os.path.relpath(path, root))


if __name__ == "__main__":
    main()
