"""Идеи из науки, пункты 1–3 (`docs/ideas-science.md`, раздел 4): фильтры «тренд или шум».

Данные — минутки XAUUSDm строго до 2026-10-16, движок `constructor.py`. Сигнал бота не меняется,
фильтр только пропускает или отбрасывает его. Значения — по последнему закрытому бару H1 (или D1)
на минуте входа. Пороги заданы заранее, не перебирались.

1. **Показатель Хёрста через коэффициент дисперсий (Ло–Маккинли).** VR(q) = дисперсия q-шаговых
   изменений / (q × дисперсия одношаговых) по окну; VR > 1 — у ряда «память» (тренд, H > 0.5),
   VR < 1 — возврат к среднему. H1: окно 240 свечей, q = 8. D1: окно 120 дней, q = 5.
2. **Энтропия Шеннона знаков изменений.** Доля растущих свечей p среди последних 24 H1 (или 20 D1),
   энтропия H = −p·log2 p − (1−p)·log2(1−p): «низкая» < 0.92 (не меньше 2/3 свечей в одну
   сторону) — упорядоченное движение; вариант «низкая и в сторону сделки» и зеркальный «не низкая»
   (добавлен после первого прогона — учитывать как подсмотренный).
3. **Фильтр Калмана (локальный линейный тренд).** Состояние — уровень и скорость; шум измерения
   R — дисперсия одношаговых изменений за всю историю до 2024 года, шум скорости — R/100.
   Фильтр: оценённая скорость по направлению сделки; «уверенно» — скорость больше 2 своих
   стандартных отклонений. H1 и D1. Для Alchemist — ещё «Калман D1 вместо структуры D1».

Боты: Alchemist H1 x12 (структура D1), long x24, пробой Азии 5R. Порог принятия — как у фильтров
волатильности: средний R выше базы во всех трёх периодах подбора (≥ 20 сделок в каждом),
p ≤ 0.05 против случайных входов, p_max ≤ 0.10 (максимум z по всем фильтрам скрипта).

    python3 tester/tools/science_filters.py --bars bars_XAUUSDm_M1.csv
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


def variance_ratio(c, window, q):
    x = np.log(c)
    r1 = pd.Series(np.diff(x, prepend=x[0]))
    rq = pd.Series(x - np.roll(x, q))
    rq[:q] = np.nan
    v1 = r1.rolling(window).var()
    vq = rq.rolling(window).var()
    return (vq / (q * v1)).to_numpy()


def sign_entropy(c, n):
    up = pd.Series((np.diff(c, prepend=c[0]) > 0).astype(float)).rolling(n).mean().to_numpy()
    p = np.clip(up, 1e-9, 1 - 1e-9)
    h = -(p * np.log2(p) + (1 - p) * np.log2(1 - p))
    return h, np.sign(up - 0.5)


def kalman_trend(c, t, train_end="2024-01-01"):
    """Локальный линейный тренд. Возврат: скорость и её стандартное отклонение после каждого бара."""
    d = np.diff(c)
    base = d[: max(10, int(np.searchsorted(t, np.datetime64(train_end))))]
    R = float(np.var(base))
    Q = np.diag([0.0, R / 100.0])
    F = np.array([[1.0, 1.0], [0.0, 1.0]])
    H = np.array([[1.0, 0.0]])
    x = np.array([c[0], 0.0])
    Pm = np.eye(2) * R * 10
    vel, vsd = np.zeros(len(c)), np.zeros(len(c))
    for i, z in enumerate(c):
        x = F @ x
        Pm = F @ Pm @ F.T + Q
        S_ = H @ Pm @ H.T + R
        K = (Pm @ H.T) / S_
        x = x + (K * (z - H @ x)).ravel()
        Pm = (np.eye(2) - K @ H) @ Pm
        vel[i], vsd[i] = x[1], np.sqrt(max(Pm[1, 1], 0.0))
    return vel, vsd


def at_minutes(P, frame_t, values, closed_offset):
    """Значение последнего закрытого бара ТФ на каждой минуте P."""
    close_t = (frame_t + closed_offset).to_numpy()
    k = np.searchsorted(close_t, P.t, side="right") - 1
    return np.where(k >= 0, values[np.clip(k, 0, None)], np.nan)


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
    H1 = S.resample(m1, "60min")
    D1 = S.resample(m1, "1D")
    feats = {}
    for tfname, fr, off, (w, q), n_ent in (("H1", H1, pd.Timedelta("1h"), (240, 8), 24),
                                           ("D1", D1, pd.Timedelta("1D"), (120, 5), 20)):
        c = fr["close"].to_numpy()
        vr = variance_ratio(c, w, q)
        h, side = sign_entropy(c, n_ent)
        vel, vsd = kalman_trend(c, fr.index.to_numpy())
        feats[tfname] = {k: at_minutes(P, fr.index, v, off) for k, v in
                         (("vr", vr), ("ent", h), ("ent_side", side), ("vel", vel), ("vsd", vsd))}

    ents = C.build_entries(P, df, ["alch-H1", "asia-brk-M15"])
    bots = {
        "alch-h1x12": (ents["alch-H1"], "time12h", "alch-H1", "struct", 0),
        "alch-long24": (ents["alch-H1"], "time24h", "alch-H1", "struct", 1),
        "asia-5r": (ents["asia-brk-M15"], "tp5", "asia-brk-M15", "off", 0),
    }
    results, zs = [], []
    for bot, (cands, ex, ename, d1f, side) in bots.items():
        tab = C.outcomes_for(P, cands, ex, ename)
        if side:
            tab = tab[tab[:, 1] == side]
        f = tab[:, 0].astype(int)
        d = tab[:, 1]
        filters = {"база": np.ones(len(f), bool)}
        for tf in ("H1", "D1"):
            F_ = feats[tf]
            filters[f"Хёрст {tf}: VR > 1 (тренд)"] = F_["vr"][f] > 1
            filters[f"Хёрст {tf}: VR < 1"] = F_["vr"][f] < 1
            filters[f"энтропия {tf} низкая"] = F_["ent"][f] < 0.92
            filters[f"энтропия {tf} низкая, в сторону сделки"] = (F_["ent"][f] < 0.92) & (F_["ent_side"][f] == d)
            # зеркальная пара (добавлена после первого прогона, где «низкая» оказалась хуже базы)
            filters[f"энтропия {tf} НЕ низкая"] = F_["ent"][f] >= 0.92
            filters[f"Калман {tf}: скорость по сделке"] = np.sign(F_["vel"][f]) == d
            filters[f"Калман {tf}: уверенно по сделке"] = (np.sign(F_["vel"][f]) == d) & \
                (np.abs(F_["vel"][f]) > 2 * F_["vsd"][f])
        rows = [(name, tab[np.nan_to_num(m, nan=0).astype(bool)], f"{ename}|{d1f}|all|off|off|{ex}")
                for name, m in filters.items()]
        if bot.startswith("alch"):
            # Калман D1 вместо структуры D1: сигналы без фильтра D1, отбор по скорости Калмана D1
            tab0 = C.outcomes_for(P, cands, ex, ename)
            if side:
                tab0 = tab0[tab0[:, 1] == side]
            f0 = tab0[:, 0].astype(int)
            m0 = np.sign(feats["D1"]["vel"][f0]) == tab0[:, 1]
            rows.append(("Калман D1 вместо структуры D1", tab0[m0], f"{ename}|off|all|off|off|{ex}"))
        print(f"# {bot}", flush=True)
        for name, sub, label in rows:
            r, z = C.evaluate(P, ctx, mk, sub, label, holdout=True)
            r.update(bot=bot, filt=name)
            results.append(r)
            if name != "база" and z is not None:
                zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"\nфильтров {len(zs)}; максимум z случайных: медиана {np.median(zmax):.2f}, 90 % {np.quantile(zmax, 0.9):.2f}\n")
    base = {r["bot"]: r for r in results if r["filt"] == "база"}
    for r in results:
        if np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        b = base[r["bot"]]
        ok = r["filt"] != "база" and all(
            r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > b.get(f"R_{lab}", 9) for lab, _, _ in FS.PERIODS
        ) and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        print(f"{r['bot']:12s} {r['filt']:40s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} "
              f"PF={r.get('pf', np.nan):.2f} p={r.get('p', np.nan):.3f} p_max={r.get('p_max', np.nan):.3f} | {by} | "
              f"26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)}) {'ПРИНЯТ' if ok else ''}")


if __name__ == "__main__":
    main()
