"""Модель v1 по скринам (октябрь 2026): лимитки на старых уровнях — точках разворота H1 (или M15)
за последние дни, короткий стоп, большой тейк.

Правило (продажа; покупка — зеркально):
  * уровень — подтверждённый максимум H1 (pivot len L), ещё не пробитый; живёт age часов;
  * лимитка на продажу на уровне − off USD (off > 0 — чуть раньше уровня);
  * стоп — sl USD над входом (или sl_atr × ATR H1), тейк — X × стоп;
  * исполнение — первое касание входа; уровень после этого отработан. Если цена прошла
    уровень + стоп без исполнения (гэп) — уровень снят;
  * фильтр импульса (k > 0): за 60 минут до касания цена прошла к уровню ≥ k × ATR H1;
  * одна позиция за раз (single) или все сделки.
Исполнение — fvg_sim.bracket по M1 (спред 0.25, своп, неясный бар — стоп). Случайные входы
(fvg_sim.Monkey) — для сравнения.

Использование:
    python3 tester/tools/levels_sim.py --bars bars_XAUUSDm_M1.csv grid [--holdout]
"""
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fade_sim as FD  # noqa: E402
import fvg_sim as FS  # noqa: E402
from structure import pivots  # noqa: E402


def levels(P, tfmin, L):
    """Уровни: (минута подтверждения в P, цена, сторона сделки: −1 продажа от максимума, +1 покупка от минимума)."""
    tf = P.resample(tfmin)
    h, l = tf["high"].to_numpy(), tf["low"].to_numpy()
    ph, pl = pivots(h, l, L)
    conf_t = tf.index + pd.Timedelta(minutes=tfmin)        # бар подтверждения закрыт
    out = []
    for i in range(len(tf)):
        f = np.searchsorted(P.t, conf_t[i].to_datetime64())
        if not np.isnan(ph[i]):
            out.append((f, ph[i], -1))
        if not np.isnan(pl[i]):
            out.append((f, pl[i], 1))
    return out


def run(P, atr, lv, off=0.0, sl=2.5, sl_atr=0.0, X=5, age_h=72, k=0.0, single=True, spread=0.25, exit_s=None, be=False):
    exit_ = FS.parse_exit(exit_s) if exit_s else ("tp", float(X))
    trades, busy = [], -1
    res = []
    for f0, p, d in lv:
        if f0 >= P.n or not np.isfinite(atr[min(f0, P.n - 1)]):
            continue
        e = p + d * off                          # продажа (d −1): чуть ниже максимума
        end = min(P.n, f0 + age_h * 60)
        sd = sl_atr * atr[f0] if sl_atr > 0 else sl
        if d == -1:
            f = P.first(lambda a, b: P.h[a:b] >= e, f0, end)
        else:
            f = P.first(lambda a, b: P.l[a:b] + spread <= e, f0, end)
        if f < 0:
            continue
        if k > 0:
            j = max(0, f - 60)
            mv = P.c[f - 1] - P.o[j] if f > 0 else 0.0
            if -d * mv < k * atr[f]:             # к уровню: для продажи — рост
                continue
        res.append((f, d, e, sd))
    res.sort()
    for f, d, e, sd in res:
        if single and f <= busy:
            continue
        entry = min(e, P.o[f] + spread) if d == 1 else max(e, P.o[f])
        r, ie = FS.bracket(P, f, d, entry, sd, exit_, be, spread)
        busy = max(busy, ie)
        trades.append((f, d, sd, r))
    return trades


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("cmd", choices=["grid", "manage"])
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    P = FS.Path(args.bars)
    atr = FD.h1_atr_on_m1(P)
    lvs = {(tf, L): levels(P, tf, L) for tf in (15, 60) for L in (3, 5)}
    if args.cmd == "manage":
        # ведение как на скринах: часть позиции рано, стоп остатка в безубыток
        for (tf, L), ex in itertools.product(((15, 5), (15, 3), (60, 3)), ("part1-4", "part2-6", "part1-6", "tp4")):
            for be in ((True, False) if ex.startswith("part") else (False,)):
                tr = run(P, atr, lvs[(tf, L)], sl=2.5, exit_s=ex, be=be, age_h=72)
                mk = FS.Monkey(P, ex, be, 0.25, rng)
                print(FS.fmt(f"M{tf} L{L} стоп 2.5$ {ex}{' безубыток' if be else ''}", FS.stats(P, tr, mk, args.holdout),
                             args.holdout), flush=True)
        return
    monkeys = {}
    for (tf, L), off, (sl, sla), X, k, age in itertools.product(lvs, (0.0, 0.5), ((2.5, 0.0), (0.0, 0.2)), (4, 6),
                                                                (0.0, 1.0), (24, 72)):
        tr = run(P, atr, lvs[(tf, L)], off=off, sl=sl, sl_atr=sla, X=X, k=k, age_h=age)
        mk = monkeys.setdefault(X, FS.Monkey(P, f"tp{X}", False, 0.25, rng))
        name = (f"M{tf} L{L} отступ {off:g} стоп {'2.5$' if sla == 0 else f'{sla:g}ATR'} тейк {X}R "
                f"импульс {k:g} жизнь {age}ч")
        print(FS.fmt(name, FS.stats(P, tr, mk, args.holdout), args.holdout), flush=True)


if __name__ == "__main__":
    main()
