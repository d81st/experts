"""Шаг 3 плана: зона сетки Ганна + подтверждение структурой (CHoCH на младшем ТФ).

Окна и зоны — как в gann_grid.py: экстремум E (ATR-зигзаг H1, k × ATR), зоны 04 (Ганн) в сторону
цены, живут до подтверждения следующей точки.
Сделка (после максимума — покупка, после минимума — продажа, то есть отскок к E):
  1. откат впервые дошёл до зоны (ближний край, подход со стороны E);
  2. в течение X баров младшего ТФ (M15, X = 16 — 4 часа) случился CHoCH в сторону отскока
     (structure.py, len L), а цена ещё не ушла за дальний край зоны + buffer;
  3. вход по рынку на открытии следующего бара; стоп — за экстремумом отката с момента касания
     + buffer, не меньше minSL × ATR(H1); тейк X R (fvg_sim.bracket, исполнение по M1).
Контроль — те же правила для сетки, сдвинутой на ±2…6 USD, и вход по CHoCH без зоны
(любой CHoCH к E внутри окна, первый после подтверждения E).

Использование:
    python3 tester/tools/gann_choch.py --bars bars_XAUUSDm_M1.csv [--k 3] [--holdout]
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402
import gann_grid as G  # noqa: E402
from structure import structure  # noqa: E402


def run(P, W, ev, t15, h15, l15, o15, sv, exit_s, X=16, buffer=0.3, minSL=0.3, kind="gann", nozone=False):
    exit_ = FS.parse_exit(exit_s)
    trades = []
    busy = -1
    for w in W:
        a, b = np.searchsorted(t15, w["a"]), np.searchsorted(t15, w["b"])
        if b - a < 2:
            continue
        sgn, E = w["sgn"], w["E"]
        d = -sgn                                # отскок к E: от максимума (sgn −1) — покупка
        dmx = (h15[a:b] - E) * sgn if sgn == 1 else (E - l15[a:b])     # дальше всего от E на баре
        evw = ev[a:b]
        cands = []
        if nozone:
            hit = np.flatnonzero(evw == 2 * d)
            if len(hit):
                cands.append((0, hit[0], None))
        else:
            lo, hi = G.grid(kind, w["P"], sv, 1.0)
            d0 = dmx[0]
            for zl, zh in zip(lo, hi):
                if d0 >= zl:
                    continue
                tt = np.flatnonzero(dmx >= zl)
                if not len(tt):
                    continue
                t = tt[0]
                end = min(t + X, len(dmx))
                ch = np.flatnonzero(evw[t:end] == 2 * d)
                if not len(ch):
                    continue
                c = t + ch[0]
                if dmx[t:c + 1].max() > zh + buffer:   # зона пробита до подтверждения
                    continue
                cands.append((t, c, zh))
        for t, c, zh in cands:
            if a + c + 1 >= len(t15):
                continue
            f = np.searchsorted(P.t, t15[a + c + 1])
            if f >= P.n or f <= busy:
                continue
            ext = dmx[t:c + 1].max()                # экстремум отката (расстояние от E)
            stop_price = (E - ext - buffer) if d == 1 else (E + ext + buffer)
            entry = P.o[f] + (0.25 if d == 1 else 0.0)
            sd = max(abs(entry - stop_price), minSL * w["atr"])
            r, ie = FS.bracket(P, f, d, entry, sd, exit_, False, 0.25)
            busy = ie
            trades.append((f, d, sd, r))
    return trades


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--k", type=float, default=3.0)
    ap.add_argument("--L", type=int, default=3, help="длина точек разворота M15")
    ap.add_argument("--holdout", action="store_true")
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    m1 = G.load(args.bars)
    H1 = G.resample(m1, "60min")
    W = G.windows(H1, args.k, args.holdout)
    M15 = G.resample(m1, "15min")
    _, ev = structure(M15, args.L)
    t15 = M15.index.to_numpy()
    h15, l15, o15 = M15["high"].to_numpy(), M15["low"].to_numpy(), M15["open"].to_numpy()
    P = FS.Path(args.bars)
    print(f"# Зона Ганна + CHoCH M15 (len {args.L}), экстремумы k = {args.k:g}: окон {len(W)}")
    for ex in ("tp1", "tp2", "tp3"):
        mk = FS.Monkey(P, ex, False, 0.25, rng)
        res = {}
        for sv in [0.0] + [s for s in G.SHIFTS if 2.0 <= abs(s) <= 6.0]:
            tr = run(P, W, ev, t15, h15, l15, o15, sv, ex)
            st = FS.stats(P, tr, mk if sv == 0.0 else None, args.holdout)
            res[sv] = st
            if sv == 0.0:
                print(FS.fmt(f"Ганн s+0 {ex}", st, args.holdout))
        ctrl = [res[s]["mean"] for s in res if s != 0.0 and res[s]]
        print(f"   сдвинутые сетки ±2…6: средний R {np.mean(ctrl):+.3f} (от {min(ctrl):+.3f} до {max(ctrl):+.3f}), "
              f"сделок в среднем {np.mean([res[s]['n'] for s in res if s != 0.0 and res[s]]):.0f}")
        tr = run(P, W, ev, t15, h15, l15, o15, 0.0, ex, nozone=True)
        print(FS.fmt(f"без зоны: первый CHoCH к E {ex}", FS.stats(P, tr, mk, args.holdout), args.holdout))
        print()


if __name__ == "__main__":
    main()
