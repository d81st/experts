"""Идея из науки 4 (`docs/ideas-science.md`): скрытые марковские модели (HMM) — режимы рынка на D1.

Гауссова HMM по дневным лог-доходностям золота, своя реализация (Баум–Велч в numpy).
**Обучение — только на 2017–2023** (дневные бары из часовой истории Exness,
`run-37736874591/data/bars_XAUUSDm_H1.zip`); дальше параметры заморожены, и на 2024 — 2026-10-15
считается **фильтрованная** (только по прошлому) вероятность состояний после закрытия каждого дня.
Состояние дня — самое вероятное; бот на минуте входа видит состояние последнего закрытого дня.

Модели и фильтры (заданы заранее):
  * 2 состояния, упорядочены по разбросу: «спокойное» / «бурное»; торговать только в спокойном,
    только в бурном, только если среднее состояния по направлению сделки;
  * 3 состояния, упорядочены по среднему: «падение» / «флэт» / «рост»; торговать по направлению
    состояния (рост — покупки, падение — продажи, флэт — пропуск), только во флэте, только вне флэта.

Боты и порог — как в `science_filters.py`.

    python3 tester/tools/hmm_filter.py --bars bars_XAUUSDm_M1.csv --h1 bars_XAUUSDm_H1.csv
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
from science_filters import at_minutes  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")


def gauss(x, mu, var):
    return np.exp(-0.5 * (x[:, None] - mu) ** 2 / var) / np.sqrt(2 * np.pi * var)


def forward(x, pi, A, mu, var):
    """Фильтрованные вероятности (по прошлому) и лог-правдоподобие."""
    B = gauss(x, mu, var)
    a = np.zeros((len(x), len(pi)))
    ll = 0.0
    prev = pi
    for t in range(len(x)):
        v = (prev @ A if t else pi) * B[t]
        s = v.sum()
        a[t] = v / s
        ll += np.log(s)
        prev = a[t]
    return a, ll, B


def fit_hmm(x, k, iters=200, seed=0):
    rng = np.random.default_rng(seed)
    q = np.quantile(x, np.linspace(0.15, 0.85, k))
    mu = q + rng.normal(0, x.std() * 0.01, k)
    var = np.full(k, x.var())
    A = np.full((k, k), 0.05 / (k - 1)) + np.eye(k) * (0.95 - 0.05 / (k - 1))
    pi = np.full(k, 1 / k)
    last = -np.inf
    for _ in range(iters):
        a, ll, B = forward(x, pi, A, mu, var)
        b = np.zeros_like(a)
        b[-1] = 1.0
        for t in range(len(x) - 2, -1, -1):
            v = A @ (B[t + 1] * b[t + 1])
            b[t] = v / v.sum()
        g = a * b
        g /= g.sum(1, keepdims=True)
        xi = np.zeros((k, k))
        for t in range(len(x) - 1):
            m = a[t][:, None] * A * (B[t + 1] * b[t + 1])[None, :]
            xi += m / m.sum()
        pi = g[0]
        A = xi / xi.sum(1, keepdims=True)
        w = g.sum(0)
        mu = (g * x[:, None]).sum(0) / w
        var = np.maximum((g * (x[:, None] - mu) ** 2).sum(0) / w, 1e-10)
        if ll - last < 1e-6:
            break
        last = ll
    return pi, A, mu, var


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--h1", required=True, help="часовая история Exness для обучения 2017–2023")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    P, df, ctx = C.prepare(args)
    if P.t.max() >= CUTOFF:
        raise SystemExit("в данных есть холдаут (с 2026-10-16) — не читаю")
    h1 = S.load_m5(args.h1)
    d_train = S.resample(h1[(h1.index >= "2017-01-01") & (h1.index < "2024-01-01")], "1D")
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    d_live = S.resample(m1, "1D")
    d_live = d_live[d_live.index >= "2023-01-01"]
    xr = np.diff(np.log(d_train["close"].to_numpy()))
    xl_full = np.diff(np.log(d_live["close"].to_numpy()), prepend=np.log(d_live["close"].iloc[0]))
    mk = C.Monkey(P, np.random.default_rng(args.seed))
    states = {}
    for k in (2, 3):
        pi, A, mu, var = fit_hmm(xr, k)
        order = np.argsort(var) if k == 2 else np.argsort(mu)
        mu, var, pi, A = mu[order], var[order], pi[order], A[np.ix_(order, order)]
        a, _, _ = forward(xl_full[1:], pi, A, mu, var)
        st = np.r_[-1, a.argmax(1)]
        print(f"# HMM {k} состояния (обучение 2017–2023): среднее % в день {np.round(mu * 100, 3)}, "
              f"разброс % {np.round(np.sqrt(var) * 100, 2)}, удержание {np.round(np.diag(A), 3)}")
        yrs = d_live.index.year.to_numpy()
        for y in (2024, 2025, 2026):
            m = yrs == y
            print(f"   {y}: доля дней по состояниям {np.round(np.bincount(st[m][st[m] >= 0], minlength=k) / max((st[m] >= 0).sum(), 1), 2)}")
        states[k] = (at_minutes(P, d_live.index, st.astype(float), pd.Timedelta("1D")), mu)
    ents = C.build_entries(P, df, ["alch-H1", "asia-brk-M15"])
    bots = {"alch-h1x12": (ents["alch-H1"], "time12h", "alch-H1", "struct", 0),
            "alch-long24": (ents["alch-H1"], "time24h", "alch-H1", "struct", 1),
            "asia-5r": (ents["asia-brk-M15"], "tp5", "asia-brk-M15", "off", 0)}
    results, zs = [], []
    for bot, (cands, ex, ename, d1f, side) in bots.items():
        tab = C.outcomes_for(P, cands, ex, ename)
        if side:
            tab = tab[tab[:, 1] == side]
        f, d = tab[:, 0].astype(int), tab[:, 1]
        s2, mu2 = states[2]
        s3, mu3 = states[3]
        s2f, s3f = s2[f], s3[f]
        sign2 = np.where(s2f >= 0, np.sign(mu2[np.clip(s2f, 0, 1).astype(int)]), 0)
        filters = {"база": np.ones(len(f), bool),
                   "HMM-2: спокойное": s2f == 0, "HMM-2: бурное": s2f == 1,
                   "HMM-2: среднее состояния по сделке": sign2 == d,
                   "HMM-3: по направлению состояния": ((s3f == 2) & (d == 1)) | ((s3f == 0) & (d == -1)),
                   "HMM-3: только флэт": s3f == 1, "HMM-3: вне флэта": (s3f == 0) | (s3f == 2)}
        print(f"# {bot}", flush=True)
        for name, m in filters.items():
            r, z = C.evaluate(P, ctx, mk, tab[m], f"{ename}|{d1f}|all|off|off|{ex}", holdout=True)
            r.update(bot=bot, filt=name)
            results.append(r)
            if name != "база" and z is not None:
                zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"\nфильтров {len(zs)}; максимум z случайных: медиана {np.median(zmax):.2f}\n")
    base = {r["bot"]: r for r in results if r["filt"] == "база"}
    for r in results:
        if np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        b = base[r["bot"]]
        ok = r["filt"] != "база" and all(
            r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > b.get(f"R_{lab}", 9) for lab, _, _ in FS.PERIODS
        ) and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        print(f"{r['bot']:12s} {r['filt']:36s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} "
              f"p={r.get('p', np.nan):.3f} p_max={r.get('p_max', np.nan):.3f} | {by} | "
              f"26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)}) {'ПРИНЯТ' if ok else ''}")


if __name__ == "__main__":
    main()
