"""Первая грубая модель сделок из скринов (октябрь 2026): лимитки против резкого движения,
короткий стоп, большой тейк.

Правило v0 (покупка; продажа — зеркально):
  * на закрытии минуты t цена за последние W минут упала не меньше чем на k × ATR(14) H1
    (ATR — последнего закрытого часа);
  * лимитка на покупку на ближайшем круглом уровне (кратном step USD) не ближе gap USD под
    закрытием; или (round = 0) просто на gap USD ниже закрытия;
  * стоп — sl USD (или sl_atr × ATR) под входом, тейк — X × стоп; лимитка живёт life минут;
  * одна сделка за раз; после сигнала новый — не раньше чем через cool минут.
Исполнение — fvg_sim.bracket по M1 (спред 0.25, своп, неясный бар — стоп). Сравнение со
случайными входами того же направления и стопа (fvg_sim.Monkey).

Использование:
    python3 tester/tools/fade_sim.py --bars bars_XAUUSDm_M1.csv grid [--holdout]
"""
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402


def h1_atr_on_m1(P):
    H1 = P.resample(60)
    h, l, c = H1["high"].to_numpy(), H1["low"].to_numpy(), H1["close"].to_numpy()
    pc = np.roll(c, 1); pc[0] = c[0]
    a = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean()
    s = pd.Series(a.to_numpy(), index=H1.index + pd.Timedelta(hours=1))   # известен после закрытия часа
    return s.reindex(pd.DatetimeIndex(P.t), method="ffill").to_numpy()


def run(P, atr, W=60, k=1.5, step=5.0, gap=1.0, round_=True, sl=2.5, sl_atr=0.0, X=5, life=30,
        cool=120, spread=0.25):
    exit_ = ("tp", float(X))
    o, c = P.o, P.c
    trades, busy, nextok = [], -1, 0
    for t in range(W, P.n - life - 1):
        if t < nextok or t <= busy or not np.isfinite(atr[t]):
            continue
        mv = c[t] - o[t - W + 1]
        if abs(mv) < k * atr[t] or (P.t[t] - P.t[t - W + 1]) > np.timedelta64(W + 30, "m"):
            continue
        d = 1 if mv < 0 else -1                      # против движения
        if round_:
            e = (np.floor((c[t] - gap) / step) * step) if d == 1 else (np.ceil((c[t] + gap) / step) * step)
        else:
            e = c[t] - d * gap
        sd = sl_atr * atr[t] if sl_atr > 0 else sl
        nextok = t + cool
        i0, i1 = t + 1, t + 1 + life
        if d == 1:
            f = P.first(lambda a, b: P.l[a:b] + spread <= e, i0, i1)
        else:
            f = P.first(lambda a, b: P.h[a:b] >= e, i0, i1)
        if f < 0:
            continue
        entry = min(e, P.o[f] + spread) if d == 1 else max(e, P.o[f])
        r, ie = FS.bracket(P, f, d, entry, sd, exit_, False, spread)
        busy = ie
        trades.append((f, d, sd, r))
    return trades


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("cmd", choices=["grid"])
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    P = FS.Path(args.bars)
    atr = h1_atr_on_m1(P)
    monkeys = {}
    for (W, k), rnd, (sl, sla), X in itertools.product(((60, 1.0), (60, 1.5), (30, 1.0), (120, 2.0)),
                                                       (True, False), ((2.5, 0.0), (0.0, 0.2)), (4, 6)):
        tr = run(P, atr, W=W, k=k, round_=rnd, sl=sl, sl_atr=sla, X=X)
        mk = monkeys.setdefault(X, FS.Monkey(P, f"tp{X}", False, 0.25, rng))
        name = f"W{W} k{k:g} {'круглое5' if rnd else 'цена−1'} стоп {'2.5$' if sla == 0 else f'{sla:g}ATR'} тейк {X}R"
        print(FS.fmt(name, FS.stats(P, tr, mk, args.holdout), args.holdout), flush=True)


if __name__ == "__main__":
    main()
