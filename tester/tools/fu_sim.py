"""FU-свеча (курс «Bozorni zabt etish», уроки 4 и 9): свеча снимает ликвидность фитилём и в той же
свече ломает структуру; вход лимиткой на 50 % фитиля, стоп за фитилём, большой RR.

Правила (продажа; покупка — зеркально):
  * ликвидность — последний подтверждённый максимум (pivothigh(p, p)), ещё не снятый;
  * FU-свеча — закрытый бар ТФ, у которого максимум выше этого уровня (ликвидность снята) и
    закрытие ниже уровня структуры:
      pivot — последний подтверждённый минимум (pivotlow(p, p)) — слом структуры;
      low3  — минимум трёх предыдущих баров (мягче);
      rangeK — без точек разворота, как на картинках урока: ликвидность — максимум K предыдущих
               свечей (доджи), слом — закрытие ниже их минимума;
  * верхний фитиль w = максимум − max(открытие, закрытие) не меньше wmin × ATR(14) ТФ;
  * лимитка на продажу: максимум − entry × w (entry 0.5 — середина фитиля, 0 — начало фитиля);
    стоп — максимум + 0.3 USD; стоп меньше minSL × ATR расширяем, больше maxSL × ATR — пропуск;
    лимитка живёт N баров ТФ;
  * выход — тейк X R (fvg_sim.bracket: исполнение по M1, спред, своп, неясный бар — стоп).
Случайные входы и p — как в fvg_sim (тот же час, направление, стоп и выход).

Использование:
    python3 tester/tools/fu_sim.py --bars bars_XAUUSDm_M1.csv grid [--holdout]
    python3 tester/tools/fu_sim.py --bars bars_XAUUSDm_M1.csv one --tf 60 --struct pivot --p 2 --entry 0.5 --exit tp5 --N 10
"""
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402
from structure import pivots  # noqa: E402


def fu_signals(tf, p, struct, wmin, entry_frac, buffer, minSL, maxSL):
    """Сигналы: (бар t, направление, цена лимитки, стоп USD)."""
    o, h, l, c = (tf[k].to_numpy() for k in ("open", "high", "low", "close"))
    pc = np.roll(c, 1); pc[0] = c[0]
    atr = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().to_numpy()
    ph, pl = pivots(h, l, p)
    liqH = liqL = None           # непройденные максимум / минимум (ликвидность)
    lastH = lastL = None         # последние подтверждённые — уровни структуры
    out = []
    for t in range(4, len(c)):
        if not np.isnan(ph[t]):
            liqH = lastH = ph[t]
        if not np.isnan(pl[t]):
            liqL = lastL = pl[t]
        a = atr[t]
        if np.isnan(a):
            continue
        if struct.startswith("range"):
            # диапазон k предыдущих свечей: ликвидность — его максимум (минимум), слом — закрытие
            # за противоположной границей
            k = int(struct[5:])
            hi, lo = h[t - k:t].max(), l[t - k:t].min()
            for d, ok, w, e0 in ((-1, h[t] > hi and c[t] < lo, h[t] - max(o[t], c[t]), h[t]),
                                 (1, l[t] < lo and c[t] > hi, min(o[t], c[t]) - l[t], l[t])):
                if ok and w >= wmin * a:
                    e = e0 + d * entry_frac * w
                    sd = max(abs((e0 - d * buffer) - e), minSL * a)
                    if sd <= maxSL * a:
                        out.append((t, d, e, sd))
            continue
        # продажа: снят максимум, закрытие ниже структуры
        if liqH is not None and h[t] > liqH:
            lvl = lastL if struct == "pivot" else l[t - 3:t].min()
            w = h[t] - max(o[t], c[t])
            if lvl is not None and c[t] < lvl and w >= wmin * a:
                e = h[t] - entry_frac * w
                sd = max(h[t] + buffer - e, minSL * a)
                if sd <= maxSL * a:
                    out.append((t, -1, e, sd))
            liqH = None
        if liqL is not None and l[t] < liqL:
            lvl = lastH if struct == "pivot" else h[t - 3:t].max()
            w = min(o[t], c[t]) - l[t]
            if lvl is not None and c[t] > lvl and w >= wmin * a:
                e = l[t] + entry_frac * w
                sd = max(e - (l[t] - buffer), minSL * a)
                if sd <= maxSL * a:
                    out.append((t, 1, e, sd))
            liqL = None
    return out


def run(P, tfmin, p, struct, entry_frac, exit_s, N, wmin=0.2, buffer=0.3, minSL=0.2, maxSL=1.0,
        spread=0.25, single=True):
    tf = P.resample(tfmin)
    sig = fu_signals(tf, p, struct, wmin, entry_frac, buffer, minSL, maxSL)
    tt = tf.index.to_numpy()
    pidx = np.append(np.searchsorted(P.t, tt), P.n)
    exit_ = FS.parse_exit(exit_s)
    trades, busy = [], -1
    for t, d, e, sd in sig:
        if t + 1 >= len(tt):
            continue
        i0, i1 = pidx[t + 1], pidx[min(t + 1 + N, len(tt))]
        if d == 1:
            f = P.first(lambda a, b: P.l[a:b] + spread <= e, i0, i1)
        else:
            f = P.first(lambda a, b: P.h[a:b] >= e, i0, i1)
        if f < 0 or (single and f <= busy):
            continue
        entry = min(e, P.o[f] + spread) if d == 1 else max(e, P.o[f])
        r, ie = FS.bracket(P, f, d, entry, sd, exit_, False, spread)
        busy = ie
        trades.append((f, d, sd, r))
    return trades, len(sig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("one")
    one.add_argument("--tf", type=int, default=60)
    one.add_argument("--p", type=int, default=2)
    one.add_argument("--struct", default="pivot")
    one.add_argument("--entry", type=float, default=0.5)
    one.add_argument("--exit", default="tp5")
    one.add_argument("--N", type=int, default=10)
    one.add_argument("--wmin", type=float, default=0.2)
    sub.add_parser("grid")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P = FS.Path(args.bars)
    if args.cmd == "one":
        tr, ns = run(P, args.tf, args.p, args.struct, args.entry, args.exit, args.N, wmin=args.wmin)
        mk = FS.Monkey(P, args.exit, False, 0.25, rng)
        print(FS.fmt(f"M{args.tf} p{args.p} {args.struct} e{args.entry:g} N{args.N} w{args.wmin:g} {args.exit} "
                     f"сигн {ns}", FS.stats(P, tr, mk, args.holdout), args.holdout))
        return
    monkeys = {}
    for tfm, st, ef, N, ex in itertools.product((15, 30, 60), ("low3", "range1", "range2", "range3"),
                                                (0.5, 0.0), (5, 10), ("tp3", "tp5", "tp10")):
        p = 2
        tr, ns = run(P, tfm, p, st, ef, ex, N)
        mk = monkeys.setdefault(ex, FS.Monkey(P, ex, False, 0.25, rng))
        print(FS.fmt(f"M{tfm} {st} e{ef:g} N{N} {ex} сигн {ns}", FS.stats(P, tr, mk, args.holdout),
                     args.holdout), flush=True)


if __name__ == "__main__":
    main()
