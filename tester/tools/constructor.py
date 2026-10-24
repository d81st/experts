"""Конструктор ботов: перебор сочетаний «вход × фильтры × выход» из уже проверенных блоков.

Блоки:
  * входы (сигнал → сделка с ценой входа и стопом в USD):
      alch-H1/H2/H4 — Alchemist's Trend (SMA200, HMA21, CCI20 ±100, H4 над/под EMA50), вход по
                      рынку на открытии следующего бара, стоп 3 × ATR14 рабочего ТФ;
      bos-H1/H4     — пробой структуры по тренду (structure.py, len 5, только BOS, не CHoCH),
                      вход и стоп как у Alchemist;
      fvg-M15/M30/H1 — лимитки FVG-робота (fvg_sim.run: L50 N20 K3 near, возраст ≥ 10 баров,
                      стоп за разрывом 2–5 USD);
  * фильтры (на минуте входа, по закрытым барам):
      d1   — off / struct (структура D1 len 5 по направлению сделки) / ema (закрытие D1 vs EMA50);
      sess — all / 07–20 (Лондон + Нью-Йорк) / 12–20 (Нью-Йорк), час входа по серверу (UTC+0);
      reg  — off / trend (ER(D1, 20) ≥ 0.3) / flat (ER < 0.3), как MarketRegime;
      news — off / avoid (нет входа за 60 минут до и после NFP, CPI, FOMC, ISM из NewsTimes.mqh);
  * выходы (стоп всегда стоит; позиция держится не дольше 5 суток, потом закрытие по рынку):
      tp3 / tp5 / tp10 — тейк X R;
      part2-6be — половина на 2R, стоп остатка в безубыток, остаток на 6R;
      time12h / time24h — закрытие по времени (как TimeExit), если раньше не сработал стоп;
      trail1-1 / trail2-1.5 — после +a R стоп идёт за лучшей ценой на расстоянии k R, тейка нет.
Одна позиция за раз в каждом сочетании: сигнал во время открытой позиции пропускается.

Исполнение по минутным барам (Bid), спред 0.25 USD: покупка по Ask, стоп и тейк продажи по Ask;
бар, задевший и стоп, и цель, — стоп. Своп покупки за ночёвки (среда тройная). Результат — в R.

Оценка (только 2024, 2025, январь–май 2026; июнь–октябрь 2026 — контроль, открывается один раз):
  * средний R по каждому периоду;
  * p — случайные входы по рынку с теми же периодом, часом, направлением, стопом и выходом
    (2000 прогонов): доля прогонов со средним R не хуже;
  * поправка на перебор: z = (средний R − среднее случайных) / разброс случайных; для каждого
    прогона берётся максимум z по всем сочетаниям — p_max = доля прогонов, где этот максимум не
    меньше z сочетания. Прогоны разных сочетаний независимы, поэтому оценка осторожная.
Проходит сочетание, у которого средний R > 0 во всех трёх периодах (не меньше 20 сделок в
каждом), p ≤ 0.05 и p_max ≤ 0.10.

Использование:
    python3 tester/tools/constructor.py --bars bars_XAUUSDm_M1.csv search --out combos.csv
    python3 tester/tools/constructor.py --bars bars_XAUUSDm_M1.csv one "alch-H4|struct|all|off|off|time12h"
    python3 tester/tools/constructor.py --bars bars_XAUUSDm_M1.csv final "сочетание" ["сочетание" …]
        — то же плюс июнь–октябрь 2026 (только для финалистов, один раз)
"""
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402
import news_fade as NF  # noqa: E402
import screen as S  # noqa: E402
from structure import structure  # noqa: E402

SPREAD = 0.25
CAP_MIN = 5 * 24 * 60            # предел удержания, минут
RUNS = FS.RUNS
NP = len(FS.PERIODS)             # периоды подбора; индекс NP — контроль

ENTRIES = ["alch-H1", "alch-H2", "alch-H4", "bos-H1", "bos-H4", "fvg-M15", "fvg-M30", "fvg-H1"]
D1F = ["off", "struct", "ema"]
SESS = {"all": (0, 24), "07-20": (7, 20), "12-20": (12, 20)}
REG = ["off", "trend", "flat"]
NEWS = ["off", "avoid"]
EXITS = ["tp3", "tp5", "tp10", "part2-6be", "time12h", "time24h", "trail1-1", "trail2-1.5"]
TFMIN = {"M15": 15, "M30": 30, "H1": 60, "H2": 120, "H4": 240}


# ── выходы ────────────────────────────────────────────────────────────

def exit_trade(P, f, d, entry, sd, ex):
    """Сделка с минуты f. Возврат (R с издержками и свопом, индекс минуты выхода)."""
    t0 = P.t[f]
    if ex.startswith("time"):
        end = int(np.searchsorted(P.t, t0 + np.timedelta64(int(ex[4:-1]) * 60, "m"))) - 1
    else:
        end = int(np.searchsorted(P.t, t0 + np.timedelta64(CAP_MIN, "m"))) - 1
    end = max(f, min(end, P.n - 1))
    h, l = P.h[f:end + 1], P.l[f:end + 1]
    if d == 1:
        up, dn = (h - entry) / sd, (entry - l) / sd
    else:
        up, dn = (entry - l - SPREAD) / sd, (h + SPREAD - entry) / sd

    def first(m):
        return int(np.argmax(m)) if m.any() else -1

    def close_r(k):
        px = P.c[f + k] + (SPREAD if d == -1 else 0.0)
        return d * (px - entry) / sd

    def race(lvl, stop_r, k0):
        """С бара k0: цель lvl R или стоп stop_r R (тот же бар — стоп). Возврат (R, бар)."""
        ks = first(dn[k0:] >= -stop_r)
        kt = first(up[k0:] >= lvl) if lvl is not None else -1
        if kt >= 0 and (ks < 0 or kt < ks):
            return lvl, k0 + kt
        if ks >= 0:
            return stop_r, k0 + ks
        return close_r(len(up) - 1), len(up) - 1

    if ex.startswith("tp"):
        r, k = race(float(ex[2:]), -1.0, 0)
    elif ex.startswith("time"):
        r, k = race(None, -1.0, 0)
    elif ex == "part2-6be":
        r1, k1 = race(2.0, -1.0, 0)
        if r1 != 2.0:
            r, k = r1, k1
        elif k1 + 1 >= len(up):
            r, k = 0.5 * 2.0 + 0.5 * close_r(k1), k1
        else:
            r2, k = race(6.0, 0.0, k1 + 1)
            r = 0.5 * 2.0 + 0.5 * r2
    else:                                              # trail a-k
        a, kk = (float(x) for x in ex[5:].split("-"))
        cm = np.maximum.accumulate(up)
        prev = np.r_[-np.inf, cm[:-1]]                 # лучшая цена до текущего бара
        lvl = np.where(prev >= a, np.maximum(-1.0, prev - kk), -1.0)
        k = first(-dn <= lvl)
        r = lvl[k] if k >= 0 else close_r(len(up) - 1)
        if k < 0:
            k = len(up) - 1
    ie = f + k
    if d == 1:
        r -= (P.nights[ie] - P.nights[f]) * FS.SWAP_LONG / sd
    return float(r), ie


# ── входы ─────────────────────────────────────────────────────────────

def market_entries(P, F, sig, mult=3.0):
    """Сигналы (бар входа i, направление) → (минута, направление, цена, стоп USD)."""
    atr = F.atr(14)
    out = []
    for i, d in sig:
        if i >= F.n or not np.isfinite(atr[i - 1]):
            continue
        f = int(np.searchsorted(P.t, F.t[i].to_datetime64()))
        if f >= P.n:
            continue
        entry = P.o[f] + (SPREAD if d == 1 else 0.0)
        out.append((f, d, entry, mult * atr[i - 1]))
    return out


def build_entries(P, df, names):
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    out = {}
    h4 = S.resample(m1, "4h")
    for name in names:
        kind, tf = name.split("-")
        rule = f"{TFMIN[tf]}min"
        if kind == "fvg":
            out[name] = FS.run(P, TFMIN[tf], 50, 20, 3, "near", "tp10", False, minage=10, raw=True)
            continue
        F = S.Frame(S.resample(m1, rule), tf)
        if kind == "alch":
            e = h4["close"].ewm(span=50, adjust=False).mean()
            up = (h4["close"] > e).astype(float).shift(1).reindex(F.t, method="ffill").to_numpy()
            dn = (h4["close"] < e).astype(float).shift(1).reindex(F.t, method="ffill").to_numpy()
            sig = S.alch_signals(F, up, dn, 200, 21, 100, cc=S.cci(F, 20))
        else:
            _, ev = structure(F.df, 5)
            sig = [(i + 1, int(np.sign(ev[i]))) for i in range(F.n - 1) if abs(ev[i]) == 1]
        out[name] = market_entries(P, F, sig)
    return out


# ── фильтры ───────────────────────────────────────────────────────────

def day_series(P, df):
    """Состояние по закрытым дням на каждой минуте: структура D1, D1 vs EMA50, ER(20) ≥ 0.3."""
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    D1 = S.resample(m1, "1D")
    st, _ = structure(D1, 5)
    ema = np.sign(D1["close"] - D1["close"].ewm(span=50, adjust=False).mean()).to_numpy()
    c = D1["close"].to_numpy()
    path = pd.Series(np.abs(np.diff(c, prepend=c[0]))).rolling(20).sum().to_numpy()
    er = np.abs(c - np.roll(c, 20)) / np.where(path > 0, path, np.nan)
    er[:20] = np.nan
    close_t = (D1.index + pd.Timedelta("1D")).to_numpy()
    k = np.searchsorted(close_t, P.t, side="right") - 1        # последний закрытый день
    ok = k >= 0
    get = lambda a, fill: np.where(ok, a[np.clip(k, 0, None)], fill)
    return get(st, 0), get(ema, 0), get(er, np.nan)


def news_mask(P, minutes=60):
    ts = sorted(t for v in NF.news_times().values() for t in v)
    ev = np.array([np.datetime64(t) for t in ts])
    j = np.searchsorted(ev, P.t)
    w = np.timedelta64(minutes, "m")
    near_next = (j < len(ev)) & (ev[np.minimum(j, len(ev) - 1)] - P.t <= w)
    near_prev = (j > 0) & (P.t - ev[np.maximum(j - 1, 0)] <= w)
    return near_next | near_prev


def filter_mask(P, ctx, cand, d1f, sess, reg, news):
    f = cand[:, 0].astype(int); d = cand[:, 1].astype(int)
    m = np.ones(len(f), bool)
    if d1f == "struct":
        m &= ctx["st"][f] == d
    elif d1f == "ema":
        m &= ctx["ema"][f] == d
    a, b = SESS[sess]
    m &= (P.hour[f] >= a) & (P.hour[f] < b)
    if reg != "off":
        er = ctx["er"][f]
        m &= (er >= 0.3) if reg == "trend" else (er < 0.3)
    if news == "avoid":
        m &= ~ctx["news"][f]
    return m


def one_position(f, ie, keep):
    out, busy = [], -1
    for i in np.flatnonzero(keep):
        if f[i] > busy:
            out.append(i); busy = ie[i]
    return np.array(out, int)


# ── случайные входы ───────────────────────────────────────────────────

class Monkey:
    def __init__(self, P, rng, pool=400):
        self.P, self.rng, self.pool, self.cache = P, rng, pool, {}
        self.idx = {k: np.flatnonzero(P.period == k)[:-8000] for k in range(NP + 1)}

    def outcomes(self, k, d, sd, ex):
        b = round(np.log(sd) / np.log(1.1))                   # стоп — корзины по 10 %
        key = (k, d, b, ex)
        if key not in self.cache:
            P, sdb = self.P, 1.1 ** b
            res = []
            for f in self.rng.choice(self.idx[k], self.pool, replace=False):
                entry = P.o[f] + (SPREAD if d == 1 else 0.0)
                res.append((P.hour[f], exit_trade(P, f, d, entry, sdb, ex)[0]))
            self.cache[key] = np.array(res)
        return self.cache[key]

    def sims(self, rows, ex):
        """rows: (период, час, направление, стоп). Средний R случайных входов, RUNS прогонов."""
        acc = np.zeros(RUNS)
        for k, hr, d, sd in rows:
            pool = self.outcomes(int(k), int(d), sd, ex)
            same = pool[pool[:, 0] == hr, 1]
            if len(same) < 8:
                same = pool[:, 1]
            acc += same[self.rng.integers(0, len(same), RUNS)]
        return acc / max(len(rows), 1)


# ── перебор ───────────────────────────────────────────────────────────

def combos(entries=ENTRIES):
    for e, d1f, sess, reg, news, ex in itertools.product(entries, D1F, SESS, REG, NEWS, EXITS):
        yield f"{e}|{d1f}|{sess}|{reg}|{news}|{ex}"


def prepare(args):
    P = FS.Path(args.bars, start="2023-01-01")
    df = P.df
    st, ema, er = day_series(P, df)
    ctx = {"st": st, "ema": ema, "er": er, "news": news_mask(P)}
    return P, df, ctx


def outcomes_for(P, cands, ex):
    """Все кандидаты одного входа с одним выходом: массивы f, d, sd, R, индекс выхода."""
    rows = [(f, d, sd) + exit_trade(P, f, d, entry, sd, ex) for f, d, entry, sd in cands]
    return np.array(rows, float).reshape(-1, 5)


def evaluate(P, ctx, mk, tab, name, holdout=False):
    _, d1f, sess, reg, news, ex = name.split("|")
    keep = filter_mask(P, ctx, tab, d1f, sess, reg, news)
    per = P.period[tab[:, 0].astype(int)]
    keep &= (per >= 0) & ((per <= NP) if holdout else (per < NP))
    sel = one_position(tab[:, 0].astype(int), tab[:, 4].astype(int), keep)
    t = tab[sel]; per = per[sel]
    ins = per < NP
    r = t[ins, 3]
    res = {"name": name, "n": int(ins.sum())}
    for k, (lab, _, _) in enumerate(FS.PERIODS):
        rk = t[per == k, 3]
        res[f"n_{lab}"] = len(rk); res[f"R_{lab}"] = rk.mean() if len(rk) else np.nan
    if len(r) == 0:
        return res, None
    gl = -r[r < 0].sum()
    eq = np.cumsum(r)
    res.update(mean=r.mean(), win=(r > 0).mean(), pf=r[r > 0].sum() / gl if gl > 0 else np.inf,
               dd=float(np.max(np.maximum.accumulate(np.r_[0, eq]) - np.r_[0, eq])), total=eq[-1])
    rows = [(per[i], P.hour[int(t[i, 0])], t[i, 1], t[i, 2]) for i in np.flatnonzero(ins)]
    sims = mk.sims(rows, ex)
    sd = sims.std() if sims.std() > 0 else np.nan
    res.update(rnd=sims.mean(), p=float((sims >= r.mean()).mean()), z=(r.mean() - sims.mean()) / sd)
    if holdout:
        rh = t[per == NP, 3]
        res.update(n_26b=len(rh), R_26b=rh.mean() if len(rh) else np.nan,
                   pf_26b=(rh[rh > 0].sum() / -rh[rh < 0].sum()) if (rh < 0).any() else np.inf)
        if len(rh):
            hs = mk.sims([(NP, P.hour[int(t[i, 0])], t[i, 1], t[i, 2]) for i in np.flatnonzero(per == NP)], ex)
            res["p_26b"] = float((hs >= rh.mean()).mean())
    return res, (sims - sims.mean()) / sd


def passed(r):
    return (all(r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -1) > 0 for lab, _, _ in FS.PERIODS)
            and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10)


def line(r, holdout=False):
    if "mean" not in r:
        return f"{r['name']:<44} нет сделок"
    by = " ".join(f"{r[f'R_{lab}']:+.2f}({r[f'n_{lab}']})" for lab, _, _ in FS.PERIODS)
    s = (f"{r['name']:<44} n={r['n']:4d} R={r['mean']:+.3f} PF={r['pf']:.2f} win={r['win']:.2f} "
         f"DD={r['dd']:.0f}R rnd={r['rnd']:+.3f} p={r['p']:.3f} z={r['z']:+.2f}"
         + (f" p_max={r['p_max']:.3f}" if "p_max" in r else "") + f" | {by}")
    if holdout and "n_26b" in r:
        s += f" | 26b n={r['n_26b']} R={r['R_26b']:+.3f} PF={r['pf_26b']:.2f} p={r.get('p_26b', np.nan):.3f}"
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--seed", type=int, default=1)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("search")
    s.add_argument("--out", required=True)
    s.add_argument("--entries", default=",".join(ENTRIES))
    for c in ("one", "final"):
        sub.add_parser(c).add_argument("names", nargs="+")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P, df, ctx = prepare(args)
    mk = Monkey(P, rng)
    if args.cmd in ("one", "final"):
        names = args.names
        ents = build_entries(P, df, sorted({n.split("|")[0] for n in names}))
        for n in names:
            e, ex = n.split("|")[0], n.split("|")[-1]
            r, _ = evaluate(P, ctx, mk, outcomes_for(P, ents[e], ex), n, holdout=args.cmd == "final")
            print(line(r, args.cmd == "final"), flush=True)
        return
    entries = args.entries.split(",")
    res, zs = [], []
    for e in entries:
        cands = build_entries(P, df, [e])[e]
        print(f"# {e}: кандидатов {len(cands)}", flush=True)
        for ex in EXITS:
            tab = outcomes_for(P, cands, ex)
            for n in combos([e]):
                if not n.endswith("|" + ex):
                    continue
                r, z = evaluate(P, ctx, mk, tab, n)
                res.append(r)
                if z is not None:
                    zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    for r in res:
        if "z" in r and np.isfinite(r["z"]):
            r["p_max"] = float((zmax >= r["z"]).mean())
    out = pd.DataFrame(res)
    out["passed"] = [passed(r) for r in res]
    out.sort_values("z", ascending=False).to_csv(args.out, index=False)
    print(f"\nсочетаний {len(res)}, со сделками {len(zs)}, прошли {int(out['passed'].sum())}")
    print(f"максимум z случайных: медиана {np.median(zmax):.2f}, 90 % {np.quantile(zmax, 0.9):.2f}")
    for r in sorted([r for r in res if "z" in r and np.isfinite(r["z"])], key=lambda r: -r["z"])[:25]:
        print(line(r) + ("  ПРОШЛО" if passed(r) else ""))


if __name__ == "__main__":
    main()
