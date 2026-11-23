"""Шаг 4 плана (docs/roadmap-2026-11.md, 7.6, 7.7, 12.3): новые входы и фильтры.

Данные — минутки XAUUSDm строго до 2026-10-16. Движок `constructor.py`. Откат по тренду и
вечерняя покупка уже проверены (`pullback.md`) — здесь не повторяются.

A. **Connors RSI(2)** на H1 и H4: покупка при закрытии выше SMA200 и RSI(2) < 6 (или < 10),
   продажа при закрытии ниже SMA200 и RSI(2) > 95 (или > 90); вход на открытии следующего бара;
   стоп 3 ATR(14); выход — закрытие за SMA5 (`own`) или через 24 часа. Стороны отдельно.
B. **Возврат к среднему во флэте:** закрытие за полосой Боллинджера (20, 2) только при ER(D1, 20)
   < 0.3; выход — закрытие за средней линией (`own`) или тейк 2R; стоп 2 ATR(14). H1 и H4.
C. **Направление старшего ТФ для M15-входов:** FVG M15 (тейк 10R), BOS M15 (тейк 5R), пробой Азии
   (тейк 5R) — только по направлению H1 или H4 (EMA50 vs EMA200 или структура len 5, последний
   закрытый бар старшего ТФ).
D. **Окна сессий** для живых ботов (Alchemist H1 x12, long x24, FVG H1): 07–10 и 12–16 UTC
   фиксированно; первые 3 часа Лондона и 08:00–12:00 Нью-Йорка по местному времени (с переходом
   на летнее / зимнее время).

Порог: для новых входов (A, B) — средний R > 0 во всех трёх периодах подбора (не меньше 20 сделок
в каждом), p ≤ 0.05 против случайных входов, p_max ≤ 0.10 (максимум z по всем испробованным
сочетаниям этого скрипта). Для фильтров (C, D) — то же плюс средний R выше, чем у бота без
фильтра, в каждом периоде. Июнь–15 октября 2026 печатается как уже смотревшееся сравнение.

    python3 tester/tools/entries4.py --bars bars_XAUUSDm_M1.csv
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
from structure import structure  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")


def rsi(close, n=2):
    d = np.diff(close, prepend=close[0])
    up = pd.Series(np.clip(d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    dn = pd.Series(np.clip(-d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    return (100 - 100 / (1 + up / dn.replace(0, np.nan))).fillna(50).to_numpy()


def cond_exit(P, F, exit_long, exit_short):
    """Выход по условию на закрытии бара ТФ (с бара входа и дальше)."""
    nx = {1: C.next_true(exit_long), -1: C.next_true(exit_short)}
    nxt_open = np.r_[F.t[1:].to_numpy(), F.t[-1].to_datetime64() + np.timedelta64(1, "D")]
    end_min = np.searchsorted(P.t, nxt_open) - 1
    ft = F.t.to_numpy()

    def own(f, d):
        i = int(np.searchsorted(ft, P.t[f], side="right")) - 1
        j = nx[d][max(i, 0)]
        return int(end_min[j]) if j < F.n else P.n - 1
    return own


def htf_dir_at(P, F, kind):
    """Направление старшего ТФ на минуте P.t (последний закрытый бар): +1 / −1 / 0."""
    if kind == "ema":
        c = pd.Series(F.c)
        v = np.sign(c.ewm(span=50, adjust=False).mean() - c.ewm(span=200, adjust=False).mean()).to_numpy()
    else:
        v, _ = structure(F.df, 5)
    close_t = np.r_[F.t[1:].to_numpy(), F.t[-1].to_datetime64() + np.timedelta64(1, "D")]
    k = np.searchsorted(close_t, P.t, side="right") - 1
    return np.where(k >= 0, v[np.clip(k, 0, None)], 0)


def local_hour(P, tz):
    return pd.DatetimeIndex(P.t).tz_localize("UTC").tz_convert(tz).hour.to_numpy()


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
    fr = {tf: S.Frame(S.resample(m1, rule), tf) for tf, rule in (("M15", "15min"), ("H1", "60min"), ("H4", "240min"))}
    rows = []                       # (группа, бот, вариант, таблица, имя для evaluate, база)

    # A. Connors RSI(2)
    for tf in ("H1", "H4"):
        F = fr[tf]
        r2, sma200 = rsi(F.c), pd.Series(F.c).rolling(200).mean().to_numpy()
        sma5 = pd.Series(F.c).rolling(5).mean().to_numpy()
        name = f"rsi2-{tf}"
        C.OWN_FN[name] = cond_exit(P, F, F.c > sma5, F.c < sma5)
        for lo, hi in ((6, 95), (10, 90)):
            sig = []
            for j in range(200, F.n - 1):
                if F.c[j] > sma200[j] and r2[j] < lo:
                    sig.append((j + 1, 1))
                elif F.c[j] < sma200[j] and r2[j] > hi:
                    sig.append((j + 1, -1))
            cands = C.market_entries(P, F, sig, mult=3.0)
            for ex in ("own", "time24h"):
                tab = C.outcomes_for(P, cands, ex, name)
                for side, lab in ((1, "покупки"), (-1, "продажи")):
                    rows.append(("A", f"RSI2 {tf}", f"{lo}/{hi} {ex} {lab}", tab[tab[:, 1] == side],
                                 f"{name}|off|all|off|off|{ex}", None))

    # B. Возврат к среднему во флэте
    for tf in ("H1", "H4"):
        F = fr[tf]
        mid = pd.Series(F.c).rolling(20).mean()
        sd = pd.Series(F.c).rolling(20).std()
        lower, upper, mid = (mid - 2 * sd).to_numpy(), (mid + 2 * sd).to_numpy(), mid.to_numpy()
        name = f"bbmr-{tf}"
        C.OWN_FN[name] = cond_exit(P, F, F.c >= mid, F.c <= mid)
        sig = [(j + 1, 1) for j in range(20, F.n - 1) if F.c[j] < lower[j]]
        sig += [(j + 1, -1) for j in range(20, F.n - 1) if F.c[j] > upper[j]]
        sig.sort()
        cands = C.market_entries(P, F, sig, mult=2.0)
        for ex in ("own", "tp2"):
            tab = C.outcomes_for(P, cands, ex, name)
            er = ctx["er"][tab[:, 0].astype(int)]
            rows.append(("B", f"Боллинджер {tf}", f"флэт {ex}", tab[er < 0.3], f"{name}|off|all|off|off|{ex}", None))

    # C. Направление старшего ТФ для M15-входов
    dirs = {f"{tf} {k}": htf_dir_at(P, fr[tf], k) for tf in ("H1", "H4") for k in ("ema", "struct")}
    ents = C.build_entries(P, df, ["fvg-M15", "bos-M15", "asia-brk-M15"])
    for ename, ex in (("fvg-M15", "tp10"), ("bos-M15", "tp5"), ("asia-brk-M15", "tp5")):
        tab = C.outcomes_for(P, ents[ename], ex, ename)
        label = f"{ename}|off|all|off|off|{ex}"
        rows.append(("C", ename, "база", tab, label, "base"))
        for dn, dv in dirs.items():
            keep = dv[tab[:, 0].astype(int)] == tab[:, 1]
            rows.append(("C", ename, f"по {dn}", tab[keep], label, None))

    # D. Окна сессий для живых ботов
    hour_utc = P.hour
    lon, ny = local_hour(P, "Europe/London"), local_hour(P, "America/New_York")
    windows = {"07–10 UTC": (hour_utc >= 7) & (hour_utc < 10), "12–16 UTC": (hour_utc >= 12) & (hour_utc < 16),
               "Лондон 08–11 мест.": (lon >= 8) & (lon < 11), "Нью-Йорк 08–12 мест.": (ny >= 8) & (ny < 12)}
    alch = C.build_entries(P, df, ["alch-H1", "fvg-H1"])
    for bot, ename, ex, d1f, side in (("alch-h1x12", "alch-H1", "time12h", "struct", 0),
                                      ("alch-long24", "alch-H1", "time24h", "struct", 1),
                                      ("fvg-h1", "fvg-H1", "tp10", "off", 0)):
        tab = C.outcomes_for(P, alch[ename], ex, ename)
        if side:
            tab = tab[tab[:, 1] == side]
        label = f"{ename}|{d1f}|all|off|off|{ex}"
        rows.append(("D", bot, "база", tab, label, "base"))
        for wn, wm in windows.items():
            rows.append(("D", bot, wn, tab[wm[tab[:, 0].astype(int)]], label, None))

    results, zs = [], []
    for grp, bot, var, tab, label, kind in rows:
        r, z = C.evaluate(P, ctx, mk, tab, label, holdout=True)
        r.update(grp=grp, bot=bot, var=var, base=kind == "base")
        results.append(r)
        if kind != "base" and z is not None:
            zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"сочетаний (без баз) {len(zs)}; максимум z случайных: медиана {np.median(zmax):.2f}, "
          f"90 % {np.quantile(zmax, 0.9):.2f}\n")
    bases = {(r["grp"], r["bot"]): r for r in results if r["base"]}
    for r in results:
        if np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        ok = all(r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > 0 for lab, _, _ in FS.PERIODS) \
            and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        b = bases.get((r["grp"], r["bot"]))
        if b is not None and not r["base"]:
            ok = ok and all(r.get(f"R_{lab}", -9) > b.get(f"R_{lab}", 9) for lab, _, _ in FS.PERIODS)
        if r["base"]:
            ok = False
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        print(f"{r['grp']} {r['bot']:16s} {r['var']:24s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} "
              f"PF={r.get('pf', np.nan):.2f} p={r.get('p', np.nan):.3f} p_max={r.get('p_max', np.nan):.3f} | {by} | "
              f"26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)}) {'ПРИНЯТ' if ok else ''}", flush=True)


if __name__ == "__main__":
    main()
