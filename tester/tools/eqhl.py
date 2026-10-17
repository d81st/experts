"""Равные вершины и днища (EQH/EQL, LimonFx) против обычных точек разворота: что бывает, когда
цена их снимает.

EQH, как в индикаторе: точка разворота pivothigh(len, len); если она отличается от предыдущей
точки разворота меньше чем на tol × ATR(200) — это пара «равных вершин», уровень — максимум пары.
Остальные точки — «одиночные» уровни. EQL — зеркально.

Уровень живёт с подтверждения точки, пока его не задели, но не дольше 200 баров. На первом баре,
задевшем уровень:
  * «отказ» — фитиль за уровень, закрытие обратно → сделка против (снятие ликвидности);
  * «пробой» — закрытие за уровнем → сделка по пробою.
Вход на открытии следующего бара, выход через N баров (screen.py: издержки, своп, случайные входы
в тот же час и в том же направлении).

Использование:
    python3 tester/tools/eqhl.py --bars bars_XAUUSDm_M1.csv [--holdout]
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import screen as S  # noqa: E402


def piv(h, l, P):
    n = len(h)
    ph, pl = [], []
    for c in range(P, n - P):
        if h[c] > h[c - P:c].max() and h[c] >= h[c + 1:c + P + 1].max():
            ph.append(c)
        if l[c] < l[c - P:c].min() and l[c] <= l[c + 1:c + P + 1].min():
            pl.append(c)
    return ph, pl


def atr(F, n):
    pc = np.roll(F.c, 1); pc[0] = F.c[0]
    tr = np.maximum(F.h - F.l, np.maximum(abs(F.h - pc), abs(F.l - pc)))
    import pandas as pd
    return pd.Series(tr).rolling(n).mean().to_numpy()


def events(F, P, tol, life=200):
    """Сигналы: {(вид, исход): [(бар входа, направление)]}, вид — eq / single, исход — reject / break."""
    h, l, c = F.h, F.l, F.c
    a200 = atr(F, 200)
    ph, pl = piv(h, l, P)
    out = {(k, o): [] for k in ("eq", "single") for o in ("reject", "break")}
    for pts, side in ((ph, 1), (pl, -1)):        # side 1 — вершины (уровень сверху)
        x = h if side == 1 else l
        for a, b in zip([None] + pts[:-1], pts):
            conf = b + P
            if conf >= F.n or np.isnan(a200[conf]):
                continue
            eq = a is not None and abs(x[b] - x[a]) < tol * a200[conf]
            lvl = (max(x[a], x[b]) if side == 1 else min(x[a], x[b])) if eq else x[b]
            end = min(conf + life, F.n - 1)
            seg = h[conf + 1:end] if side == 1 else l[conf + 1:end]
            hit = np.flatnonzero(seg > lvl) if side == 1 else np.flatnonzero(seg < lvl)
            if not len(hit):
                continue
            i = conf + 1 + hit[0]
            back = c[i] < lvl if side == 1 else c[i] > lvl
            kind = "eq" if eq else "single"
            if back:
                out[(kind, "reject")].append((i + 1, -side))
            else:
                out[(kind, "break")].append((i + 1, side))
    for k in out:
        out[k].sort()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    m5 = S.load_m5(args.bars)
    m5 = m5[m5.index >= "2023-11-01"]
    for rule, name, Ns in (("15min", "M15", (4, 12, 24)), ("1h", "H1", (4, 12, 24))):
        F = S.Frame(S.resample(m5, rule), name)
        for P, tol in ((1, 0.1), (3, 0.1), (3, 0.2)):
            ev = events(F, P, tol)
            print(f"# {name}: точки разворота len {P}, «равные» — ближе {tol:g} ATR(200)")
            for (kind, o), sig in ev.items():
                for N in Ns:
                    tr = [(i, d, S.trade_result(F, i, d, N)) for i, d in sig if i < F.n]
                    lab = {"eq": "EQH/EQL", "single": "одиночные"}[kind] + ", " + \
                          {"reject": "отказ → против", "break": "пробой → по пробою"}[o]
                    print(S.fmt(f"{lab}, N={N}", S.evaluate(F, tr, N, rng, args.holdout), args.holdout))
            print()


if __name__ == "__main__":
    main()
