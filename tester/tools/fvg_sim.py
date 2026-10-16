"""Лимитки от незакрытых разрывов (FVG): симулятор по минутным барам.

Правила (как в будущем роботе):
  * Разрыв на рабочем ТФ (M15 / M30 / H1) по трём свечам:
      бычий  — low[3] > high[1]: зона [high[1], low[3]], ближний край low[3];
      медвежий — high[3] < low[1]: зона [high[3], low[1]], ближний край high[3].
    Разрыв живёт, пока цена не прошла его дальний край.
  * На закрытии каждого бара ТФ: кандидаты — живые разрывы не старше L баров, ещё без ордера,
    цена снаружи разрыва (медвежий — цена ниже, бычий — выше). В каждую сторону берём K разрывов:
      near   — K ближайших к цене (дальние пропускаем);
      recent — K самых свежих (старые пропускаем).
  * Лимитка на ближнем крае по направлению разрыва: медвежий — продажа, бычий — покупка.
    Стоп — за дальним краем + buffer; меньше minSL — расширяем до minSL, больше maxSL — разрыв
    пропускаем. Лимитка живёт N баров ТФ.
  * Выход: тейк X R, или частичное закрытие: доля part на a R, остаток на b R; после частичного
    закрытия стоп остатка — в безубыток (be=1) или прежний.
Исполнение по минутным барам (Bid) со спредом: покупка — по Ask, стоп продажи и тейк продажи —
по Ask. Бар, задевший и стоп, и цель, считается стопом (осторожно). Своп покупки — по ночёвкам.
Результат каждой сделки — в R (доля риска), с издержками.

Случайные входы: те же направление, стоп в USD, выход и час входа, тот же период; вход по рынку
на случайной минуте. p — доля 2000 прогонов со средним R не хуже стратегии.

Использование:
    python3 tester/tools/fvg_sim.py --bars bars_XAUUSDm_M1.csv grid  [--holdout]
    python3 tester/tools/fvg_sim.py --bars bars_XAUUSDm_M1.csv one --tf 15 --L 50 --N 20 --K 3 \
        --select near --exit part5-10 [--be] [--holdout] [--trades out.csv]
"""
import argparse
import itertools
import sys

import numpy as np
import pandas as pd

SWAP_LONG = 0.537          # USD на унцию за ночь (53.7 за лот), среда — тройная
PERIODS = [("2024", "2024-01-01", "2025-01-01"),
           ("2025", "2025-01-01", "2026-01-01"),
           ("26a", "2026-01-01", "2026-06-01")]
HOLDOUT = ("26b", "2026-06-01", "2027-01-01")
RUNS = 2000


# ── данные ────────────────────────────────────────────────────────────

class Path:
    """Минутные (или M5) бары — путь цены внутри сделок."""

    def __init__(self, path, start="2024-01-01"):
        d = pd.read_csv(path)
        d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
        d = d[d["time"] >= start].reset_index(drop=True)
        self.df = d
        self.t = d["time"].to_numpy()
        self.o = d["open"].to_numpy(float)
        self.h = d["high"].to_numpy(float)
        self.l = d["low"].to_numpy(float)
        self.c = d["close"].to_numpy(float)
        self.n = len(d)
        self.hour = d["time"].dt.hour.to_numpy()
        self.period = np.full(self.n, -1)
        for k, (_, a, b) in enumerate(PERIODS + [HOLDOUT]):
            self.period[(d["time"] >= a) & (d["time"] < b)] = k
        # ночёвки: смена даты между соседними барами, выход из среды — ×3
        date = d["time"].dt.normalize().to_numpy()
        dow = d["time"].dt.dayofweek.to_numpy()
        ch = np.zeros(self.n)
        ch[1:] = np.where(date[1:] != date[:-1], np.where(dow[:-1] == 2, 3, 1), 0)
        self.nights = np.cumsum(ch)

    def resample(self, minutes):
        g = self.df.set_index("time").resample(f"{minutes}min", label="left", closed="left")
        tf = pd.DataFrame({"open": g["open"].first(), "high": g["high"].max(),
                           "low": g["low"].min(), "close": g["close"].last()}).dropna()
        return tf

    def first(self, cond, start, stop=None):
        """Первый индекс ≥ start (и < stop), где cond(i0, i1) → bool-массив истинен; иначе −1."""
        end = self.n if stop is None else min(stop, self.n)
        i, step = start, 512
        while i < end:
            j = min(end, i + step)
            m = cond(i, j)
            if m.any():
                return i + int(np.argmax(m))
            i, step = j, step * 4
        return -1


# ── разрывы ───────────────────────────────────────────────────────────

def find_gaps(tf):
    """Список разрывов: (бар формирования j, направление сделки, ближний край, дальний край)."""
    h, l = tf["high"].to_numpy(), tf["low"].to_numpy()
    out = []
    for j in range(2, len(tf)):
        if l[j] > h[j - 2]:
            out.append((j, 1, l[j], h[j - 2]))     # бычий → покупка от верхнего края
        elif h[j] < l[j - 2]:
            out.append((j, -1, h[j], l[j - 2]))    # медвежий → продажа от нижнего края
    return out


# ── одна сделка ───────────────────────────────────────────────────────

def bracket(P, f, d, entry, sd, exit_, be, spread):
    """Сделка с входа на минуте f (цена entry, направление d, стоп sd USD). Возврат: R, индекс выхода."""
    sl = entry - d * sd
    h, l = P.h, P.l
    if d == 1:
        hit_sl = lambda x: (lambda i, j: l[i:j] <= x)
        hit_tp = lambda x: (lambda i, j: h[i:j] >= x)
    else:
        hit_sl = lambda x: (lambda i, j: h[i:j] + spread >= x)
        hit_tp = lambda x: (lambda i, j: l[i:j] + spread <= x)

    def race(lvl_tp, lvl_sl, start):
        """Что раньше: цель или стоп (тот же бар — стоп). Возврат (кто, индекс): 1 — цель, 0 — стоп, −1 — нет."""
        isl = P.first(hit_sl(lvl_sl), start)
        stop = isl + 1 if isl >= 0 else None
        itp = P.first(hit_tp(lvl_tp), start, stop)
        if itp >= 0 and (isl < 0 or itp < isl):
            return 1, itp
        if isl >= 0:
            return 0, isl
        return -1, P.n - 1

    def swap_r(i_exit):
        if d != 1:
            return 0.0
        return (P.nights[i_exit] - P.nights[f]) * SWAP_LONG / sd

    if exit_[0] == "tp":
        who, ie = race(entry + d * exit_[1] * sd, sl, f)
        r = exit_[1] if who == 1 else (-1.0 if who == 0 else d * (P.c[ie] - entry) / sd)
        return r - swap_r(ie), ie
    # частичное: доля part на a R, остаток на b R
    _, a, b, part = exit_
    who, ia = race(entry + d * a * sd, sl, f)
    if who != 1:
        r = -1.0 if who == 0 else d * (P.c[ia] - entry) / sd
        return r - swap_r(ia), ia
    sl2 = entry if be else sl
    who2, ib = race(entry + d * b * sd, sl2, ia + 1 if be else ia)
    if who2 == 1:
        rest = b
    elif who2 == 0:
        rest = 0.0 if be else -1.0
    else:
        rest = d * (P.c[ib] - entry) / sd
    return part * a + (1 - part) * rest - swap_r(ib), ib


def parse_exit(s):
    if s.startswith("tp"):
        return ("tp", float(s[2:]))
    a, b = s[4:].split("-")           # part5-10
    return ("part", float(a), float(b), 0.5)


# ── стратегия ─────────────────────────────────────────────────────────

def run(P, tfmin, L, N, K, select, exit_s, be, buffer=0.3, minSL=2.0, maxSL=5.0, spread=0.25,
        single=False, mingap=0.0):
    tf = P.resample(tfmin)
    tt = tf.index.to_numpy()
    th, tl, tc = tf["high"].to_numpy(), tf["low"].to_numpy(), tf["close"].to_numpy()
    gaps = [g for g in find_gaps(tf) if abs(g[2] - g[3]) >= mingap]
    exit_ = parse_exit(exit_s)
    bar_ns = np.timedelta64(tfmin, "m")
    # индекс минуты для начала каждого бара ТФ
    pidx = np.searchsorted(P.t, tt)
    alive = []          # [j, d, near, far, ordered]
    gi = 0
    trades = []
    busy_until = -1
    for t in range(2, len(tf) - 1):
        while gi < len(gaps) and gaps[gi][0] <= t:
            j, d, near, far = gaps[gi]
            alive.append([j, d, near, far, False])
            gi += 1
        # разрыв закрыт насквозь (бар t прошёл дальний край) или устарел
        keep = []
        for g in alive:
            j, d, near, far, used = g
            if j < t and ((d == 1 and tl[t] <= far) or (d == -1 and th[t] >= far)):
                continue
            if t - j >= L and not used:
                continue
            if used:
                continue
            keep.append(g)
        alive = keep
        price = tc[t]
        for side in (1, -1):
            cand = [g for g in alive if g[1] == side and not g[4] and t - g[0] < L and
                    ((side == -1 and price < g[2]) or (side == 1 and price > g[2]))]
            if not cand:
                continue
            if select == "near":
                cand.sort(key=lambda g: abs(g[2] - price))
            else:
                cand.sort(key=lambda g: -g[0])
            for g in cand[:K]:
                g[4] = True
                j, d, near, far, _ = g
                sd = abs(near - far) + buffer
                if sd > maxSL:
                    continue
                sd = max(sd, minSL)
                i0 = pidx[t + 1]
                i1 = np.searchsorted(P.t, tt[t + 1] + N * bar_ns) if t + 1 < len(tt) else P.n
                if d == 1:
                    f = P.first(lambda a, b: P.l[a:b] + spread <= near, i0, i1)
                    if f < 0:
                        continue
                    entry = min(near, P.o[f] + spread)
                else:
                    f = P.first(lambda a, b: P.h[a:b] >= near, i0, i1)
                    if f < 0:
                        continue
                    entry = max(near, P.o[f])
                if single and f <= busy_until:
                    continue
                r, ie = bracket(P, f, d, entry, sd, exit_, be, spread)
                busy_until = max(busy_until, ie)
                trades.append((f, d, sd, r))
    return trades


# ── случайные входы ───────────────────────────────────────────────────

class Monkey:
    def __init__(self, P, exit_s, be, spread, rng, pool=1500):
        self.P, self.exit_, self.be, self.spread = P, parse_exit(exit_s), be, spread
        self.rng, self.pool, self.cache = rng, pool, {}

    def outcomes(self, k, d, sd):
        key = (k, d, round(sd * 2) / 2)
        if key not in self.cache:
            P = self.P
            idx = np.flatnonzero(P.period == k)
            pick = self.rng.choice(idx[:-5000], self.pool, replace=False)
            res = []
            for f in pick:
                entry = P.o[f] + (self.spread if d == 1 else 0.0)
                r, _ = bracket(P, f, d, entry, key[2], self.exit_, self.be, self.spread)
                res.append((P.hour[f], r))
            self.cache[key] = np.array(res)
        return self.cache[key]

    def pvalue(self, trades):
        P = self.P
        sims = np.zeros(RUNS)
        for f, d, sd, r in trades:
            pool = self.outcomes(P.period[f], d, sd)
            same = pool[pool[:, 0] == P.hour[f], 1]
            if len(same) < 10:
                same = pool[:, 1]
            sims += same[self.rng.integers(0, len(same), RUNS)]
        sims /= len(trades)
        return sims


def stats(P, trades, monkey=None, holdout=False):
    out = {}
    if not trades:
        return out
    tr = np.array(trades)
    per = P.period[tr[:, 0].astype(int)]
    sel = (per >= 0) & (per < len(PERIODS))
    r = tr[sel, 3]
    if len(r) == 0:
        return out
    out["n"] = len(r)
    out["mean"] = r.mean()
    out["win"] = (r > 0).mean()
    gp, gl = r[r > 0].sum(), -r[r < 0].sum()
    out["pf"] = gp / gl if gl > 0 else np.inf
    out["by"] = [(int((per == k).sum()), tr[per == k, 3].mean() if (per == k).any() else np.nan)
                 for k in range(len(PERIODS))]
    eq = np.cumsum(r)
    out["dd"] = float(np.max(np.maximum.accumulate(eq) - eq)) if len(eq) else 0.0
    # длиннейшая серия убытков
    s = m = 0
    for x in r:
        s = s + 1 if x < 0 else 0
        m = max(m, s)
    out["streak"] = m
    if monkey is not None:
        sims = monkey.pvalue([t for t, ok in zip(trades, sel) if ok])
        out["p"] = float((sims >= r.mean()).mean())
        out["rnd"] = float(sims.mean())
    if holdout:
        m2 = per == len(PERIODS)
        out["hold"] = (int(m2.sum()), tr[m2, 3].mean() if m2.any() else np.nan,
                       (tr[m2, 3] > 0).mean() if m2.any() else np.nan)
    return out


def fmt(name, s, holdout=False):
    if not s:
        return f"{name:<46} нет сделок"
    by = " ".join(f"{m:+.3f}({n})" for n, m in s["by"])
    ok = all(n > 0 and m > 0 for n, m in s["by"]) and s.get("p", 1) <= 0.10
    line = (f"{name:<46} n={s['n']:5d} meanR={s['mean']:+.3f} win={s['win']:.3f} PF={s['pf']:.2f} "
            f"DD={s['dd']:.0f}R серия={s['streak']} rnd={s.get('rnd', np.nan):+.3f} p={s.get('p', np.nan):.3f}"
            f" | {by} {'ПРОШЁЛ' if ok else ''}")
    if holdout and "hold" in s:
        n, m, w = s["hold"]
        line += f" | 26b n={n} meanR={m:+.3f} win={w:.3f}"
    return line


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--spread", type=float, default=0.25)
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("one")
    one.add_argument("--tf", type=int, default=15)
    one.add_argument("--L", type=int, default=50)
    one.add_argument("--N", type=int, default=20)
    one.add_argument("--K", type=int, default=3)
    one.add_argument("--select", default="near")
    one.add_argument("--exit", default="part5-10")
    one.add_argument("--be", action="store_true")
    one.add_argument("--single", action="store_true")
    one.add_argument("--minsl", type=float, default=2.0)
    one.add_argument("--maxsl", type=float, default=5.0)
    one.add_argument("--mingap", type=float, default=0.0)
    one.add_argument("--trades")
    grid = sub.add_parser("grid")
    grid.add_argument("--tfs", default="15,30,60")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P = Path(args.bars)
    if args.cmd == "one":
        tr = run(P, args.tf, args.L, args.N, args.K, args.select, args.exit, args.be,
                 minSL=args.minsl, maxSL=args.maxsl, spread=args.spread, single=args.single,
                 mingap=args.mingap)
        mk = Monkey(P, args.exit, args.be, args.spread, rng)
        print(fmt(f"M{args.tf} L{args.L} N{args.N} K{args.K} {args.select} g{args.mingap:g} {args.exit}{' BE' if args.be else ''}{' 1поз' if args.single else ''}",
                  stats(P, tr, mk, args.holdout), args.holdout))
        if args.trades:
            pd.DataFrame([(P.t[f], d, sd, r) for f, d, sd, r in tr],
                         columns=["time", "dir", "stop_usd", "R"]).to_csv(args.trades, index=False)
        return
    monkeys = {}
    for tfm in [int(x) for x in args.tfs.split(",")]:
        for L, N, K, sel, mg, ex, be in itertools.product((30, 50), (10, 20, 40), (1, 3), ("near", "recent"),
                                                          (0.0, 1.0, 2.0),
                                                          ("tp5", "tp7", "tp10", "part5-10", "part5-7"),
                                                          (False, True)):
            if be and not ex.startswith("part"):
                continue
            tr = run(P, tfm, L, N, K, sel, ex, be, spread=args.spread, mingap=mg)
            mk = monkeys.setdefault((ex, be), Monkey(P, ex, be, args.spread, rng))
            print(fmt(f"M{tfm} L{L} N{N} K{K} {sel} g{mg:g} {ex}{' BE' if be else ''}",
                      stats(P, tr, mk, args.holdout), args.holdout), flush=True)


if __name__ == "__main__":
    main()
