"""Идеи «случайный вход + математика» (разговор с владельцем 2026-11-28), пункты 1 и 2.

Данные — минутки XAUUSDm строго до 2026-10-16, движок `constructor.py`. Сигналы — на закрытии
H1-свечи, вход по рынку на открытии следующей.

1. **Вход по часам в сторону дня.** Каждые N закрытых свечей (N = 1, 4), направление:
   структура D1 (len 5), закрытие D1 против EMA50, всегда покупка, случайное (эталон).
   Это ответ на вопрос «сколько даёт само направление дня без сигнала бота».
2. **Импульс после крупной свечи.** z = изменение закрытия свечи / разброс изменений за 100
   прошлых свечей; |z| ≥ 1.5 или 2; вход по направлению свечи; фильтры — структура D1 по
   направлению (вкл./выкл.) и время входа (весь день / 07–10 UTC / 12–16 UTC).

Выходы (одинаковые для всех): стоп 1 ATR(14) H1 и тейк 1R / 2R / закрытие через 6 часов;
стоп 3 ATR и закрытие через 12 часов. Одна позиция на сочетание.

Порог: средний R > 0 во всех трёх периодах подбора (2024, 2025, январь–май 2026; ≥ 20 сделок в
каждом), p ≤ 0.05 против случайных входов (тот же период, час, направление, стоп и выход) и
p_max ≤ 0.10 (максимум z по всем сочетаниям скрипта). Июнь–15 октября 2026 — уже смотрели.

    python3 tester/tools/math_ideas.py --bars bars_XAUUSDm_M1.csv
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402
import fvg_sim as FS  # noqa: E402
import screen as S  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")
EXITS = [("tp1", 1.0), ("tp2", 1.0), ("time6h", 1.0), ("time12h", 3.0)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    P, df, ctx = C.prepare(args)
    if P.t.max() >= CUTOFF:
        raise SystemExit("в данных есть холдаут (с 2026-10-16) — не читаю")
    rng = np.random.default_rng(args.seed)
    mk = C.Monkey(P, np.random.default_rng(args.seed + 1))
    F = S.Frame(S.resample(df.set_index("time")[["open", "high", "low", "close"]], "60min"), "H1")
    entry_min = np.searchsorted(P.t, F.t.to_numpy())          # минута открытия каждой свечи
    hour_close = (F.t + pd.Timedelta(hours=1)).hour.to_numpy()  # час закрытия свечи = час входа

    def at_entry(arr, j):
        k = entry_min[j + 1] if j + 1 < F.n else P.n - 1
        return arr[min(k, P.n - 1)]

    combos = []
    # 1. Часы
    for N in (1, 4):
        bars = [j for j in range(200, F.n - 1) if hour_close[j] % N == 0]
        for dname in ("D1 структура", "D1 EMA50", "всегда покупка", "случайно"):
            sig = []
            for j in bars:
                if dname == "D1 структура":
                    d = int(at_entry(ctx["st"], j))
                elif dname == "D1 EMA50":
                    d = int(at_entry(ctx["ema"], j))
                elif dname == "всегда покупка":
                    d = 1
                else:
                    d = int(rng.choice((-1, 1)))
                if d:
                    sig.append((j + 1, d))
            combos.append(("1. часы", f"каждые {N} ч, {dname}", sig))
    # 2. Импульс после крупной свечи
    dc = np.diff(F.c, prepend=F.c[0])
    sd100 = pd.Series(dc).shift(1).rolling(100).std().to_numpy()
    z = dc / sd100
    for zt in (1.5, 2.0):
        for d1 in (False, True):
            for wname, (a, b) in (("весь день", (0, 24)), ("07–10 UTC", (7, 10)), ("12–16 UTC", (12, 16))):
                sig = []
                for j in range(200, F.n - 1):
                    if not np.isfinite(z[j]) or abs(z[j]) < zt or not (a <= hour_close[j] < b):
                        continue
                    d = int(np.sign(z[j]))
                    if d1 and int(at_entry(ctx["st"], j)) != d:
                        continue
                    sig.append((j + 1, d))
                combos.append(("2. импульс", f"|z| ≥ {zt:g}, {'D1 по направлению' if d1 else 'без D1'}, {wname}", sig))

    results, zs = [], []
    for grp, name, sig in combos:
        cands = {m: C.market_entries(P, F, sig, mult=m) for m in (1.0, 3.0)}
        for ex, m in EXITS:
            tab = C.outcomes_for(P, cands[m], ex, "math-H1")
            r, zz = C.evaluate(P, ctx, mk, tab, f"math-H1|off|all|off|off|{ex}", holdout=True)
            r.update(grp=grp, var=name, ex=f"стоп {m:g} ATR, {ex}")
            results.append(r)
            if zz is not None:
                zs.append(zz)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"сочетаний {len(zs)}; максимум z случайных: медиана {np.median(zmax):.2f}, 90 % {np.quantile(zmax, 0.9):.2f}\n")
    for r in results:
        if np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        ok = all(r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > 0 for lab, _, _ in FS.PERIODS) \
            and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        print(f"{r['grp']} {r['var']:44s} {r['ex']:22s} n={r.get('n', 0):5d} R={r.get('mean', np.nan):+.3f} "
              f"rnd={r.get('rnd', np.nan):+.3f} p={r.get('p', np.nan):.3f} z={r.get('z', np.nan):+.2f} "
              f"p_max={r.get('p_max', np.nan):.3f} | {by} | 26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)})"
              f" {'ПРИНЯТ' if ok else ''}", flush=True)


if __name__ == "__main__":
    main()
