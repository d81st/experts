"""Грубая проверка Alchemist на длинной истории H1 (пункт 3 плана владельца от 2026-11-26).

Данные — часовые бары XAUUSDm Exness 2014-01 — 2026-10-06 (`run-37736874591/data/bars_XAUUSDm_H1.zip`
в ветке `tester-results`). В 2014–2016 баров около 300 в год (история Exness по H1 по сути
начинается в 2017), поэтому эти годы — только прогрев индикаторов, в отчёт не идут. Минуток за
эти годы нет, поэтому исполнение грубое, по H1:

  * сигнал — как в боте (`screen.alch_signals`): закрытие выше / ниже SMA200, HMA21 растёт / падает,
    CCI20 > +100 / < −100, последний закрытый H4 выше / ниже EMA50; фильтр структуры D1 (len 5);
  * вход на открытии следующего бара, спред 0.25 USD (покупка — по Ask);
  * стоп 3 × ATR14 сигнального бара; проверка по максимуму / минимуму каждого часа, при гэпе за
    стоп — выход по открытию; иначе выход по закрытию бара входа + N − 1;
  * своп покупки 0.49 USD на унцию за ночь (среда — тройной); одна позиция за раз.

Результат — в R (доля стопа). Сравнение — случайные входы того же года, часа и направления с тем же
удержанием и стопом (p — доля прогонов не хуже). 2024 и позже уже смотрели — печатаются для сверки.

    python3 tester/tools/alch_h1_history.py --bars bars_XAUUSDm_H1.csv [--spread 0.25]
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import screen as S  # noqa: E402
from structure import htf_on  # noqa: E402

SWAP = 0.49
RUNS = 1000


def simulate(F, sig, N, mult, spread, side, years, nights):
    atr = F.atr(14)
    out, busy = [], -1
    for i, d in sig:
        if i <= busy or i + N - 1 >= F.n or (side and d != side) or not np.isfinite(atr[i - 1]):
            continue
        r, j = trade(F, i, d, N, mult * atr[i - 1], spread, nights)
        out.append((i, d, r, years[i]))
        busy = j
    return out


def trade(F, i, d, N, sd, spread, nights):
    entry = F.o[i] + (spread if d == 1 else 0.0)
    stop = entry - d * sd
    last = i + N - 1
    for j in range(i, last + 1):
        if d == 1:
            if j > i and F.o[j] <= stop:
                px = F.o[j]; break
            if F.l[j] <= stop:
                px = stop; break
        else:
            if j > i and F.o[j] + spread >= stop:
                px = F.o[j] + spread; break
            if F.h[j] + spread >= stop:
                px = stop; break
    else:
        j = last
        px = F.c[j] + (spread if d == -1 else 0.0)
    r = d * (px - entry) / sd
    if d == 1:
        r -= (nights[j] - nights[i]) * SWAP / sd
    return r, j


def baseline(F, trades, N, mult, spread, years, nights, rng):
    atr = F.atr(14)
    hours = F.hour
    pools = {}
    sims = np.zeros(RUNS)
    for i, d, r, y in trades:
        key = (y, hours[i])
        if key not in pools:
            pools[key] = np.flatnonzero((years == y) & (hours == hours[i]) & (np.arange(F.n) < F.n - N - 1)
                                        & np.isfinite(np.r_[np.nan, atr[:-1]]))
        pool = pools[key]
        pick = pool[rng.integers(0, len(pool), RUNS)]
        sims += np.array([trade(F, k, d, N, mult * atr[k - 1], spread, nights)[0] for k in pick])
    return sims / max(len(trades), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--spread", type=float, default=0.25)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    h1 = S.load_m5(args.bars)
    h1 = h1[h1.index < "2026-10-16"]
    F = S.Frame(h1[["open", "high", "low", "close"]], "H1")
    D1 = S.resample(h1, "1D")
    up, dn = S.h4_filter(h1, F)
    raw = S.alch_signals(F, up, dn, 200, 21, 100, cc=S.cci(F, 20))
    d1 = htf_on(F, D1, "1D", 5)
    years = F.t.year.to_numpy()
    date = F.t.normalize().to_numpy()
    dow = F.t.dayofweek.to_numpy()
    ch = np.zeros(F.n)
    ch[1:] = np.where(date[1:] != date[:-1], np.where(dow[:-1] == 2, 3, 1), 0)
    nights = np.cumsum(ch)
    rng = np.random.default_rng(args.seed)
    variants = [("H1 x12, структура D1 (код)", 12, True, 0), ("H1 x12 без фильтра D1", 12, False, 0),
                ("H1 x24, структура D1", 24, True, 0), ("H1 long x24, структура D1 (кандидат)", 24, True, 1)]
    print(f"# Alchemist на H1 Exness, спред {args.spread:g} USD, стоп 3 ATR; R на сделку (сделок)\n")
    for name, N, use_d1, side in variants:
        sig = [(i, d) for i, d in raw if (not use_d1) or d1[i - 1] == d]
        tr = simulate(F, sig, N, 3.0, args.spread, side, years, nights)
        df = pd.DataFrame(tr, columns=["i", "d", "R", "year"])
        print(f"## {name}")
        rows = []
        for y in range(2017, 2027):
            g = df[df.year == y]
            rows.append(f"{y}: {g.R.mean():+.3f} ({len(g)})" if len(g) else f"{y}: —")
        print("   " + " | ".join(rows))
        for lab, lo, hi in (("2017–2022 (не смотрели)", 2017, 2022), ("2023", 2023, 2023), ("2024–2026* (смотрели)", 2024, 2026)):
            g = df[(df.year >= lo) & (df.year <= hi)]
            if not len(g):
                continue
            sims = baseline(F, list(g.itertuples(index=False, name=None)), N, 3.0, args.spread, years, nights, rng)
            r = g.R.to_numpy()
            gp, gl = r[r > 0].sum(), -r[r < 0].sum()
            eq = np.cumsum(r)
            dd = float(np.max(np.maximum.accumulate(np.r_[0, eq]) - np.r_[0, eq]))
            pos_years = sum(df[df.year == y].R.sum() > 0 for y in range(lo, hi + 1))
            print(f"   {lab:24s} n={len(g):4d} R={r.mean():+.3f} PF={gp / gl if gl else np.inf:.2f} итог {eq[-1]:+.1f}R "
                  f"просадка {dd:.1f}R | прибыльных лет {pos_years}/{hi - lo + 1} | случайные {sims.mean():+.3f}, "
                  f"p={float((sims >= r.mean()).mean()):.3f}")
        print()


if __name__ == "__main__":
    main()
