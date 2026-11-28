"""Оставшиеся непроверенные идеи из `docs/ideas-science.md` (2026-11-28).

Данные — минутки XAUUSDm строго до 2026-10-16, движок `constructor.py`, боты — Alchemist H1 x12
(структура D1), long x24, пробой Азии 5R. Всё задано заранее, без перебора порогов.

a. **Трение / период полураспада.** Отклонение закрытия H1 от EMA50 как процесс Орнштейна–Уленбека:
   по окну 240 свечей регрессия Δy на y(t−1), полураспад = −ln 2 / ln(1 + β). Выход Alchemist —
   через полураспад часов (не меньше 4, не больше 48) вместо фиксированных 12 / 24 баров.
b. **Фазовый переход — детектор CUSUM на D1.** S⁺ = max(0, S⁺ + r − k), S⁻ = min(0, S⁻ + r + k),
   k = 0.5σ, тревога при |S| > 4σ (σ — разброс доходностей за 60 дней); после тревоги — режим «рост»
   или «падение», суммы обнуляются. Фильтры: сделка по направлению режима; только первые 10 дней
   после смены режима («свежий тренд»).
c. **Цепи Маркова на D1.** Фильтры: прошлый день закрылся по направлению сделки / против; не
   входить после 3 и более дней подряд в сторону сделки («растянуто»).
d. **Байесовские веса портфеля.** Раз в месяц вес бота ∝ апостериорному среднему его R
   (нормальное априорное со средним 0 и разбросом 0.1R, обновление по сделкам до начала месяца),
   общий риск 2 %; сравнение с «по 1 % каждому» (Alchemist x12 + Азия, сделки MT5).

Порог для a–c — как у прочих фильтров: лучше базы во всех трёх периодах подбора (≥ 20 сделок),
p ≤ 0.05, p_max ≤ 0.10 (максимум z по всем вариантам a–c).

    python3 tester/tools/science_rest.py --bars bars_XAUUSDm_M1.csv
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402
import fvg_sim as FS  # noqa: E402
import portfolio as PF  # noqa: E402
import screen as S  # noqa: E402
from science_filters import at_minutes  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")


def ou_half_life(c, window=240):
    y = pd.Series(c - pd.Series(c).ewm(span=50, adjust=False).mean().to_numpy())
    dy, ylag = y.diff(), y.shift(1)
    cov = (dy * ylag).rolling(window).mean() - dy.rolling(window).mean() * ylag.rolling(window).mean()
    beta = (cov / ylag.rolling(window).var()).to_numpy()
    with np.errstate(invalid="ignore", divide="ignore"):
        hl = -np.log(2) / np.log1p(beta)
    return np.where(np.isfinite(hl) & (beta < 0), hl, np.nan)


def cusum_regime(r, sd):
    reg, since = np.zeros(len(r)), np.full(len(r), 999)
    sp = sn = 0.0
    cur, last = 0, -999
    for i in range(len(r)):
        if np.isfinite(sd[i]) and sd[i] > 0:
            k, h = 0.5 * sd[i], 4 * sd[i]
            sp, sn = max(0.0, sp + r[i] - k), min(0.0, sn + r[i] + k)
            if sp > h:
                cur, last, sp, sn = 1, i, 0.0, 0.0
            elif sn < -h:
                cur, last, sp, sn = -1, i, 0.0, 0.0
        reg[i], since[i] = cur, i - last
    return reg, since


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    P, df, ctx = C.prepare(args)
    if P.t.max() >= CUTOFF:
        raise SystemExit("в данных есть холдаут (с 2026-10-16) — не читаю")
    mk = C.Monkey(P, np.random.default_rng(args.seed))
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    H1F = S.Frame(S.resample(m1, "60min"), "H1")
    D1 = S.resample(m1, "1D")
    dc = D1["close"].to_numpy()
    dr = np.diff(np.log(dc), prepend=np.log(dc[0]))
    sd60 = pd.Series(dr).rolling(60).std().shift(1).to_numpy()
    reg, since = cusum_regime(dr, sd60)
    up_day = np.sign(np.diff(dc, prepend=dc[0]))
    streak = np.zeros(len(dc))
    for i in range(1, len(dc)):
        streak[i] = streak[i - 1] + up_day[i] if np.sign(streak[i - 1]) == up_day[i] else up_day[i]
    off = pd.Timedelta("1D")
    reg_m, since_m = at_minutes(P, D1.index, reg, off), at_minutes(P, D1.index, since.astype(float), off)
    prev_m, streak_m = at_minutes(P, D1.index, up_day, off), at_minutes(P, D1.index, streak, off)
    hl = ou_half_life(H1F.c)

    ents = C.build_entries(P, df, ["alch-H1", "asia-brk-M15"])
    # a. выход по полураспаду для Alchemist
    ft = H1F.t.to_numpy()

    def hl_exit(f, d):
        i = int(np.searchsorted(ft, P.t[f], side="right")) - 2      # сигнальный бар
        h = hl[i] if i >= 0 and np.isfinite(hl[i]) else 12.0
        hrs = int(round(min(max(h, 4.0), 48.0)))
        return int(np.searchsorted(P.t, P.t[f] + np.timedelta64(hrs * 60, "m"))) - 1
    C.OWN_FN["alch-H1"] = hl_exit
    bots = {"alch-h1x12": (ents["alch-H1"], "time12h", "alch-H1", "struct", 0),
            "alch-long24": (ents["alch-H1"], "time24h", "alch-H1", "struct", 1),
            "asia-5r": (ents["asia-brk-M15"], "tp5", "asia-brk-M15", "off", 0)}
    results, zs = [], []
    for bot, (cands, ex, ename, d1f, side) in bots.items():
        tab = C.outcomes_for(P, cands, ex, ename)
        if side:
            tab = tab[tab[:, 1] == side]
        f, d = tab[:, 0].astype(int), tab[:, 1]
        rows = [("база", tab, ex)]
        rows += [("CUSUM: по режиму", tab[reg_m[f] == d], ex),
                 ("CUSUM: свежий режим ≤ 10 дней, по нему", tab[(reg_m[f] == d) & (since_m[f] <= 10)], ex),
                 ("Марков: прошлый день по сделке", tab[prev_m[f] == d], ex),
                 ("Марков: прошлый день против", tab[prev_m[f] == -d], ex),
                 ("Марков: не после ≥ 3 дней в сторону сделки", tab[~(streak_m[f] * d >= 3)], ex)]
        if bot.startswith("alch"):
            th = C.outcomes_for(P, cands, "own", ename)
            if side:
                th = th[th[:, 1] == side]
            rows.append(("выход по полураспаду (4–48 ч)", th, "own"))
        print(f"# {bot}", flush=True)
        for name, sub, exn in rows:
            r, z = C.evaluate(P, ctx, mk, sub, f"{ename}|{d1f}|all|off|off|{exn}", holdout=True)
            r.update(bot=bot, filt=name)
            results.append(r)
            if name != "база" and z is not None:
                zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"\nвариантов {len(zs)}; максимум z случайных: медиана {np.median(zmax):.2f}\n")
    base = {r["bot"]: r for r in results if r["filt"] == "база"}
    for r in results:
        if np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        b = base[r["bot"]]
        ok = r["filt"] != "база" and all(
            r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > b.get(f"R_{lab}", 9) for lab, _, _ in FS.PERIODS
        ) and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        print(f"{r['bot']:12s} {r['filt']:44s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} "
              f"p={r.get('p', np.nan):.3f} p_max={r.get('p_max', np.nan):.3f} | {by} | "
              f"26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)}) {'ПРИНЯТ' if ok else ''}")
    h = hl[np.isfinite(hl)]
    print(f"\nполураспад отклонения от EMA50 (H1): медиана {np.median(h):.1f} ч, 10–90 % {np.quantile(h, 0.1):.1f}–{np.quantile(h, 0.9):.1f} ч")

    # d. байесовские веса портфеля
    trades = {n: PF.mt5_trades(P, n) for n in ("alch-h1x12", "asia-5r")}
    days = pd.date_range("2024-01-01", "2026-10-15", freq="D")
    months = pd.period_range("2024-01", "2026-10", freq="M")
    dly_eq = sum(PF.daily(trades[n], 1.0, days) for n in trades)
    dly_b = pd.Series(0.0, index=days)
    wlog = []
    for mth in months:
        start = mth.start_time
        post = {}
        for n, t in trades.items():
            past = t[t["exit"] < np.datetime64(start)]["R"].to_numpy()
            prior_var, noise_var = 0.1 ** 2, max(np.var(past), 0.5) if len(past) > 5 else 1.0
            post[n] = (past.sum() / noise_var) / (1 / prior_var + len(past) / noise_var) if len(past) else 0.0
        pos = {n: max(v, 0.0) for n, v in post.items()}
        tot = sum(pos.values())
        w = {n: (pos[n] / tot if tot > 0 else 0.5) for n in trades}
        wlog.append((str(mth), {n: round(w[n], 2) for n in w}))
        for n, t in trades.items():
            m = (pd.DatetimeIndex(t["entry"]).to_period("M") == mth)
            if m.any():
                dly_b = dly_b.add(PF.daily(t[m], 2.0 * w[n], days), fill_value=0.0)
    for lab, dd_ in (("по 1 % каждому", dly_eq), ("байесовские веса, всего 2 %", dly_b)):
        st = PF.curve_stats(dd_)
        print(f"портфель {lab:30s} итог {st['итог%']:+6.1f}% просадка {st['просадка%']:5.1f}% "
              f"итог/просадка {st['итог/просадка']:5.2f} худший мес. {st['худший месяц%']:+5.1f}%")
    print("веса (начало, середина, конец):", wlog[0], wlog[len(wlog) // 2], wlog[-1])


if __name__ == "__main__":
    main()
