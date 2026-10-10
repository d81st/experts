"""Быстрый отсев идей на барах из тестера (ступени 1–2 протокола: вход + выход через N баров,
сравнение со случайными входами).

Использование:
    python3 tester/tools/screen.py --bars bars_XAUUSDm_M5.csv fvg   [--holdout]
    python3 tester/tools/screen.py --bars bars_XAUUSDm_M5.csv sweep [--holdout]
    python3 tester/tools/screen.py --bars bars_XAUUSDm_M5.csv msnr  [--holdout]
    python3 tester/tools/screen.py --bars bars_XAUUSDm_M5.csv osc   [--holdout]

Данные: минутные бары M5 (выгрузка tools/bar-dump), из них собираются M15, H1, H4, D1.
Воскресные бары (22:00–23:59) относятся к понедельнику.

Периоды: 2024, 2025, 2026 январь–май — подбор; 2026 июнь–октябрь — отложенная проверка,
печатается только с --holdout (смотреть один раз, для прошедших отсев).

Сделка: вход по цене открытия следующего бара (или по цене лимитки), выход по закрытию
через N баров. Издержки: COST USD за сделку (спред с запасом: в барах записан минимальный
спред, медиана реальных тиков 2026 года — 0.26) и своп покупки SWAP_LONG USD за унцию за ночь
(в среду тройной); продажа без свопа. Результат — в USD на унцию (× 100 = USD на лот).

Случайные входы: те же число сделок, направления и час входа, тот же период, тот же выход
через N баров; 2000 прогонов. p — доля случайных прогонов со средним не хуже стратегии.
Порог отсева: среднее > 0 в каждом периоде подбора и p ≤ 0.10.
"""
import argparse
import sys

import numpy as np
import pandas as pd

COST = 0.25
SWAP_LONG = 0.537          # 53.7 USD за лот за ночь
RUNS = 2000
PERIODS = [("2024", "2024-01-01", "2025-01-01"),
           ("2025", "2025-01-01", "2026-01-01"),
           ("26a", "2026-01-01", "2026-06-01")]
HOLDOUT = ("26b", "2026-06-01", "2026-12-31")


# ── данные ────────────────────────────────────────────────────────────

def load_m5(path):
    d = pd.read_csv(path)
    point = float(d.columns[-1].split("=")[1])
    d = d.rename(columns={d.columns[-1]: "spread_pts"})
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    d = d.set_index("time")
    d["spread"] = d["spread_pts"] * point
    return d[["open", "high", "low", "close", "spread"]]


def resample(m5, rule):
    if rule == "1D":
        key = m5.index.normalize()
        key = key.where(m5.index.dayofweek != 6, key + pd.Timedelta(days=1))
        g = m5.groupby(key)
    else:
        g = m5.resample(rule, label="left", closed="left")
    out = pd.DataFrame({"open": g["open"].first(), "high": g["high"].max(),
                        "low": g["low"].min(), "close": g["close"].last()}).dropna()
    return out


class Frame:
    """Бары одного таймфрейма + заранее посчитанные результаты входа на каждом баре."""

    def __init__(self, df, name):
        self.name = name
        self.df = df
        self.t = df.index
        self.o = df["open"].to_numpy()
        self.h = df["high"].to_numpy()
        self.l = df["low"].to_numpy()
        self.c = df["close"].to_numpy()
        self.n = len(df)
        self.hour = self.t.hour.to_numpy()
        self.period = np.full(self.n, -1)
        for k, (_, a, b) in enumerate(PERIODS + [HOLDOUT]):
            self.period[(self.t >= a) & (self.t < b)] = k
        self.date = self.t.normalize()
        self._cache = {}

    def atr(self, n=14):
        key = ("atr", n)
        if key not in self._cache:
            pc = np.roll(self.c, 1); pc[0] = self.c[0]
            tr = np.maximum(self.h - self.l, np.maximum(abs(self.h - pc), abs(self.l - pc)))
            self._cache[key] = pd.Series(tr).rolling(n).mean().to_numpy()
        return self._cache[key]

    def swap_arr(self, N):
        """Своп покупки при входе на баре i и выходе на баре i+N-1: ночёвки = смены даты
        между барами, выход из среды — тройная (своп выходных); USD на унцию."""
        key = ("swap", N)
        if key not in self._cache:
            dn = self.date.to_numpy()
            dow = self.t.dayofweek.to_numpy()
            change = np.zeros(self.n)
            change[1:] = np.where(dn[1:] != dn[:-1], np.where(dow[:-1] == 2, 3, 1), 0)
            cs = np.cumsum(change)
            s = np.zeros(self.n)
            m = self.n - N + 1
            s[:m] = cs[N - 1:] - cs[:m]
            self._cache[key] = s * SWAP_LONG
        return self._cache[key]

    def returns(self, N):
        """Результат входа по открытию бара i и выхода по закрытию бара i+N-1 (покупка, продажа)."""
        key = ("ret", N)
        if key not in self._cache:
            rl = np.full(self.n, np.nan); rs = np.full(self.n, np.nan)
            m = self.n - N + 1
            ex = self.c[N - 1:]
            rl[:m] = ex - self.o[:m] - COST - self.swap_arr(N)[:m]
            rs[:m] = self.o[:m] - ex - COST
            self._cache[key] = (rl, rs)
        return self._cache[key]


# ── сделки и оценка ───────────────────────────────────────────────────

def trade_result(F, i, d, N, price=None):
    """Сделка: вход на баре i (по price или по открытию), выход по закрытию бара i+N-1."""
    j = i + N - 1
    if j >= F.n:
        return None
    entry = F.o[i] if price is None else price
    if d == 1:
        return F.c[j] - entry - COST - F.swap_arr(N)[i]
    return entry - F.c[j] - COST


def evaluate(F, trades, N, rng, holdout=False):
    """trades: список (бар входа, направление, результат)."""
    rl, rs = F.returns(N)
    tr = [x for x in trades if x[2] is not None and F.period[x[0]] >= 0]
    res = {"n": 0}
    if not tr:
        return res
    idx = np.array([x[0] for x in tr]); dr = np.array([x[1] for x in tr]); r = np.array([x[2] for x in tr])
    per = F.period[idx]
    sel = per < len(PERIODS)
    res["n"] = int(sel.sum())
    res["long"] = float((dr[sel] == 1).mean()) if sel.any() else 0.0
    res["by"] = []
    for k in range(len(PERIODS)):
        m = per == k
        res["by"].append((int(m.sum()), float(r[m].mean()) if m.any() else float("nan")))
    rr = r[sel]
    if len(rr) == 0:
        return res
    res["mean"] = float(rr.mean())
    res["win"] = float((rr > 0).mean())
    gp, gl = rr[rr > 0].sum(), -rr[rr < 0].sum()
    res["pf"] = float(gp / gl) if gl > 0 else float("inf")
    res["t"] = float(rr.mean() / (rr.std(ddof=1) / np.sqrt(len(rr)))) if len(rr) > 2 and rr.std() > 0 else 0.0
    # случайные входы: тот же период, час и направление
    groups = {}
    valid = ~np.isnan(rl)
    for k in range(len(PERIODS)):
        for hh in range(24):
            groups[(k, hh)] = np.where(valid & (F.period == k) & (F.hour == hh))[0]
    sims = np.zeros(RUNS)
    for k, hh, d in zip(per[sel], F.hour[idx[sel]], dr[sel]):
        g = groups.get((k, hh))
        if g is None or len(g) == 0:
            g = np.where(valid & (F.period == k))[0]
        pick = g[rng.integers(0, len(g), RUNS)]
        sims += rl[pick] if d == 1 else rs[pick]
    sims /= sel.sum()
    res["p"] = float((sims >= rr.mean()).mean())
    res["rnd"] = float(sims.mean())
    if holdout:
        m = per == len(PERIODS)
        res["hold"] = (int(m.sum()), float(r[m].mean()) if m.any() else float("nan"),
                       float((r[m] > 0).mean()) if m.any() else float("nan"))
    return res


def fmt(name, res, holdout=False):
    if res.get("n", 0) == 0 or "mean" not in res:
        return f"{name:<44} нет сделок"
    by = " ".join(f"{m:+6.2f}({n})" for n, m in res["by"])
    ok = all(m > 0 for n, m in res["by"] if n > 0) and all(n > 0 for n, m in res["by"]) and res["p"] <= 0.10
    s = (f"{name:<44} n={res['n']:4d} buy={res['long']:.2f} mean={res['mean']:+6.2f} "
         f"win={res['win']:.2f} PF={res['pf']:4.2f} t={res['t']:+5.2f} rnd={res['rnd']:+6.2f} "
         f"p={res['p']:.3f} | {by} {'ПРОШЁЛ' if ok else ''}")
    if holdout and "hold" in res:
        n, m, w = res["hold"]
        s += f" | 26b n={n} mean={m:+.2f} win={w:.2f}"
    return s


# ── 1. Дисбалансы (разрыв между фитилями свечей 1 и 3) ───────────────

def fvg_events(F, min_atr):
    atr = F.atr()
    ev = []
    for j in range(2, F.n):
        if np.isnan(atr[j]):
            continue
        if F.l[j] > F.h[j - 2] and F.l[j] - F.h[j - 2] >= min_atr * atr[j]:
            ev.append((j, 1, F.h[j - 2], F.l[j]))     # бычий: зона [high(1), low(3)]
        elif F.h[j] < F.l[j - 2] and F.l[j - 2] - F.h[j] >= min_atr * atr[j]:
            ev.append((j, -1, F.l[j - 2], F.h[j]))    # медвежий: зона [high(3), low(1)]
    return ev


def fill_stats(F, ev, K, rng):
    """Доля дисбалансов, заполненных полностью за K баров, и та же доля для случайного бара
    того же периода и часа с тем же расстоянием до уровня в ту же сторону."""
    lows = pd.Series(F.l).rolling(K).min().shift(-K).to_numpy()     # мин. low баров i+1..i+K
    highs = pd.Series(F.h).rolling(K).max().shift(-K).to_numpy()
    groups = {}
    for k in range(len(PERIODS)):
        for hh in range(24):
            groups[(k, hh)] = np.where((F.period == k) & (F.hour == hh) & ~np.isnan(lows))[0]
    real, base = [], []
    for j, d, far, near in ev:
        if F.period[j] < 0 or F.period[j] >= len(PERIODS) or np.isnan(lows[j]):
            continue
        dist = (F.c[j] - far) if d == 1 else (far - F.c[j])
        filled = lows[j] <= far if d == 1 else highs[j] >= far
        real.append(filled)
        g = groups[(F.period[j], F.hour[j])]
        pick = g[rng.integers(0, len(g), 50)]
        if d == 1:
            base.append(np.mean(lows[pick] <= F.c[pick] - dist))
        else:
            base.append(np.mean(highs[pick] >= F.c[pick] + dist))
    return len(real), float(np.mean(real)), float(np.mean(base))


def run_fvg(m5, args, rng):
    print("# 1. Дисбалансы: заполняются ли чаще случайного и можно ли на этом торговать\n")
    for tf, rule in [("M15", "15min"), ("H1", "1h"), ("H4", "4h")]:
        F = Frame(resample(m5, rule), tf)
        for min_atr in (0.0, 0.3, 0.6):
            ev = fvg_events(F, min_atr)
            for K in (12, 48):
                n, fr, br = fill_stats(F, ev, K, rng)
                print(f"{tf} размер≥{min_atr} ATR, за {K} баров: дисбалансов {n}, заполнено {fr:.3f}, "
                      f"случайный уровень на том же расстоянии {br:.3f}, разница {fr - br:+.3f}")
            for N in (4, 12):
                # а) против дисбаланса — на заполнение: вход по открытию следующего бара
                tr = [(j + 1, -d, trade_result(F, j + 1, -d, N)) for j, d, far, near in ev if j + 1 < F.n]
                print(fmt(f"{tf} ≥{min_atr} против, N={N}", evaluate(F, tr, N, rng, args.holdout), args.holdout))
                # б) по дисбалансу — лимитка на ближнем крае (возврат в зону), ждём 24 бара
                tr = []
                for j, d, far, near in ev:
                    for i in range(j + 1, min(F.n, j + 25)):
                        hit = (F.l[i] + COST <= near) if d == 1 else (F.h[i] >= near)
                        if hit:
                            tr.append((i, d, trade_result(F, i, d, N, price=near)))
                            break
                print(fmt(f"{tf} ≥{min_atr} по, лимитка, N={N}", evaluate(F, tr, N, rng, args.holdout), args.holdout))
        print()


# ── 2. Направление по снятию ликвидности дня ─────────────────────────

def run_sweep(m5, args, rng):
    print("# 2. Снятие вчерашнего минимума/максимума и закрытие обратно → направление на завтра\n")
    D = Frame(resample(m5, "1D"), "D1")
    o, h, l, c = D.o, D.h, D.l, D.c
    for variant in ("base", "strong", "any"):
        sig = []
        for d in range(1, D.n - 1):
            lo_sw = l[d] < l[d - 1] and c[d] > l[d - 1]
            hi_sw = h[d] > h[d - 1] and c[d] < h[d - 1]
            rng_d = h[d] - l[d]
            if variant == "base":
                bull, bear = lo_sw and not h[d] > h[d - 1], hi_sw and not l[d] < l[d - 1]
            elif variant == "strong":
                bull = lo_sw and not h[d] > h[d - 1] and rng_d > 0 and (c[d] - l[d]) / rng_d >= 0.5
                bear = hi_sw and not l[d] < l[d - 1] and rng_d > 0 and (h[d] - c[d]) / rng_d >= 0.5
            else:   # снят один край, закрытие обратно — независимо от второго края
                bull, bear = lo_sw and not hi_sw, hi_sw and not lo_sw
            if bull:
                sig.append((d + 1, 1))
            elif bear:
                sig.append((d + 1, -1))
        for N in (1, 2, 5):
            tr = [(i, dd, trade_result(D, i, dd, N)) for i, dd in sig]
            print(fmt(f"D1 {variant}, держать {N} дн.", evaluate(D, tr, N, rng, args.holdout), args.holdout))
        # цель — ликвидность с другой стороны: берёт ли завтра вчерашний экстремум с другой стороны
        hit, base = [], []
        for i, dd in sig:
            if i >= D.n or D.period[i] < 0 or D.period[i] >= len(PERIODS):
                continue
            hit.append(h[i] > h[i - 1] if dd == 1 else l[i] < l[i - 1])
        allb = [(h[i] > h[i - 1], l[i] < l[i - 1]) for i in range(1, D.n) if 0 <= D.period[i] < len(PERIODS)]
        bh = np.mean([x[0] for x in allb]); bl = np.mean([x[1] for x in allb])
        nb = sum(1 for _, dd in sig if dd == 1)
        print(f"   завтра снимает вчерашний экстремум по направлению: {np.mean(hit):.3f} "
              f"(любой день: максимум {bh:.3f}, минимум {bl:.3f}; сигналов {len(hit)}, покупок {nb})\n")


# ── 3. MSNR: свежие уровни по телам свечей ───────────────────────────

def msnr_levels(F, k, kind):
    """Уровни: A — бычья свеча, затем медвежья на локальном максимуме (сопротивление, уровень —
    закрытие бычьей); V — наоборот (поддержка). kind='wick' — уровень по экстремуму (для сравнения),
    kind='random' — закрытие случайного бара (контроль)."""
    o, h, l, c = F.o, F.h, F.l, F.c
    out = []   # (бар, когда уровень известен, сторона: -1 сопротивление / +1 поддержка, цена)
    for i in range(k, F.n - k - 1):
        top = max(h[i], h[i + 1]); bot = min(l[i], l[i + 1])
        if kind == "random":
            continue
        if c[i] > o[i] and c[i + 1] < o[i + 1] and top >= h[i - k:i + k + 2].max():
            out.append((i, i + 1 + k, -1, c[i] if kind == "body" else top))
        elif c[i] < o[i] and c[i + 1] > o[i + 1] and bot <= l[i - k:i + k + 2].min():
            out.append((i, i + 1 + k, 1, c[i] if kind == "body" else bot))
    return out


def random_levels(F, k, count, rng):
    out = []
    for i in rng.integers(k, F.n - k - 1, count):
        side = -1 if rng.random() < 0.5 else 1
        out.append((int(i), int(i) + 1 + k, side, F.c[i]))
    return out


def level_touches(F, levels, away_atr, max_age, which):
    """Касания уровня: цена уходит от уровня на away_atr × ATR, затем возвращается.
    which=1 — первое касание (свежий уровень), 2 — второе."""
    atr = F.atr()
    ev = []
    for i, known, side, L in levels:
        if np.isnan(atr[i]):
            continue
        need = away_atr * atr[i]
        armed = False; touches = 0
        for t in range(i + 2, min(F.n, i + 2 + max_age)):
            if side == -1:      # сопротивление: уход вниз, касание сверху
                if armed and F.h[t] >= L:
                    touches += 1
                    if t >= known and touches == which:
                        ev.append((t, -1, L))
                    if touches >= which:
                        break
                    armed = False
                    continue
                if not armed and F.h[t] >= L:
                    if which == 1:
                        break   # коснулся до ухода — уровень не свежий
                if F.l[t] <= L - need:
                    armed = True
            else:
                if armed and F.l[t] + COST <= L:
                    touches += 1
                    if t >= known and touches == which:
                        ev.append((t, 1, L))
                    if touches >= which:
                        break
                    armed = False
                    continue
                if not armed and F.l[t] <= L:
                    if which == 1:
                        break
                if F.h[t] >= L + need:
                    armed = True
    return ev


def d1_trend(m5, F, n=50):
    """Направление старшего ТФ: закрытие вчерашнего D1 выше/ниже SMA(n) D1."""
    D = resample(m5, "1D")
    s = (np.sign(D["close"] - D["close"].rolling(n).mean())).shift(1)
    return s.reindex(F.t.normalize(), method="ffill").to_numpy()


def run_msnr(m5, args, rng):
    print("# 3. MSNR: реакция цены на свежий уровень по телам свечей\n")
    for tf, rule, max_age in [("H1", "1h", 240), ("H4", "4h", 120)]:
        F = Frame(resample(m5, rule), tf)
        trend = d1_trend(m5, F)
        lv = {"тело": msnr_levels(F, 3, "body"), "фитиль": msnr_levels(F, 3, "wick")}
        lv["случайный"] = random_levels(F, 3, len(lv["тело"]), rng)
        for away in (1.0, 2.0):
            for name, levels in lv.items():
                for which in (1, 2) if name == "тело" else (1,):
                    ev = level_touches(F, levels, away, max_age, which)
                    for N in (4, 12):
                        tr = [(t, d, trade_result(F, t, d, N, price=L)) for t, d, L in ev]
                        tag = "свежий" if which == 1 else "2-е касание"
                        print(fmt(f"{tf} {name} {tag} уход≥{away} N={N}", evaluate(F, tr, N, rng, args.holdout),
                                  args.holdout))
                        if name == "тело" and which == 1:
                            trf = [x for x in tr if trend[x[0]] == x[1]]
                            print(fmt(f"{tf} тело свежий + тренд D1 уход≥{away} N={N}",
                                      evaluate(F, trf, N, rng, args.holdout), args.holdout))
        print()


# ── 4. Стохастик и фильтры Алхимика ──────────────────────────────────

def sma(x, n):
    return pd.Series(x).rolling(n).mean().to_numpy()


def ema(x, n):
    return pd.Series(x).ewm(span=n, adjust=False).mean().to_numpy()


def wma(x, n):
    w = np.arange(1, n + 1)
    return pd.Series(x).rolling(n).apply(lambda a: np.dot(a, w) / w.sum(), raw=True).to_numpy()


def hma(x, n):
    return wma(2 * wma(x, n // 2) - wma(x, n), int(np.sqrt(n)))


def cci(F, n=20):
    tp = (F.h + F.l + F.c) / 3
    s = pd.Series(tp)
    ma = s.rolling(n).mean()
    md = s.rolling(n).apply(lambda a: np.mean(np.abs(a - a.mean())), raw=True)
    return ((s - ma) / (0.015 * md)).to_numpy()


def run_osc(m5, args, rng):
    print("# 4. Стохастик и Alchemist's Trend\n")
    for tf, rule in [("H1", "1h"), ("M15", "15min")]:
        F = Frame(resample(m5, rule), tf)
        e50, e200 = ema(F.c, 50), ema(F.c, 200)
        for k, dd, sl in [(14, 3, 3), (9, 3, 3), (21, 5, 5)]:
            ll = pd.Series(F.l).rolling(k).min().to_numpy(); hh = pd.Series(F.h).rolling(k).max().to_numpy()
            raw = 100 * (F.c - ll) / np.where(hh - ll > 0, hh - ll, np.nan)
            K = sma(raw, sl); D = sma(K, dd)
            for lo, hi in [(20, 80), (30, 70)]:
                sig = []
                for i in range(1, F.n - 1):
                    if np.isnan(D[i - 1]):
                        continue
                    if K[i - 1] <= D[i - 1] and K[i] > D[i] and min(K[i - 1], D[i - 1]) < lo:
                        sig.append((i + 1, 1))
                    elif K[i - 1] >= D[i - 1] and K[i] < D[i] and max(K[i - 1], D[i - 1]) > hi:
                        sig.append((i + 1, -1))
                for N in (4, 12):
                    tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
                    print(fmt(f"{tf} стох {k},{dd},{sl} {lo}/{hi} N={N}", evaluate(F, tr, N, rng, args.holdout),
                              args.holdout))
                    trf = [x for x in tr if (e50[x[0] - 1] > e200[x[0] - 1]) == (x[1] == 1)]
                    print(fmt(f"{tf} стох {k},{dd},{sl} {lo}/{hi} +EMA50/200 N={N}",
                              evaluate(F, trf, N, rng, args.holdout), args.holdout))
        # Alchemist's Trend: MA200, HMA растёт, CCI > порога, H4 выше EMA50 — сигнал, когда все четыре сошлись
        H4 = resample(m5, "4h")
        h4up = (H4["close"] > H4["close"].ewm(span=50, adjust=False).mean()).astype(float)
        h4dn = (H4["close"] < H4["close"].ewm(span=50, adjust=False).mean()).astype(float)
        # последний закрытый бар H4 к началу текущего бара
        h4up = h4up.shift(1).reindex(F.t, method="ffill").to_numpy()
        h4dn = h4dn.shift(1).reindex(F.t, method="ffill").to_numpy()
        m200 = sma(F.c, 200)
        cc = cci(F, 20)
        for hp in (21, 55):
            hm = hma(F.c, hp)
            for thr in (0, 100):
                up = (F.c > m200) & (hm > np.roll(hm, 1)) & (cc > thr) & (h4up == 1)
                dn = (F.c < m200) & (hm < np.roll(hm, 1)) & (cc < -thr) & (h4dn == 1)
                sig = []
                for i in range(201, F.n - 1):
                    if up[i] and not up[i - 1]:
                        sig.append((i + 1, 1))
                    elif dn[i] and not dn[i - 1]:
                        sig.append((i + 1, -1))
                for N in (4, 12, 24):
                    tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
                    print(fmt(f"{tf} Alchemist HMA{hp} CCI±{thr} N={N}", evaluate(F, tr, N, rng, args.holdout),
                              args.holdout))
        print()



def alch_signals(F, h4up, h4dn, ma_n, hp, thr, use_h4=True, use_hma=True, use_cci=True, cc=None):
    m = sma(F.c, ma_n)
    up = F.c > m
    dn = F.c < m
    if use_hma:
        hm = hma(F.c, hp)
        up &= hm > np.roll(hm, 1); dn &= hm < np.roll(hm, 1)
    if use_cci:
        up &= cc > thr; dn &= cc < -thr
    if use_h4:
        up &= h4up == 1; dn &= h4dn == 1
    sig = []
    for i in range(ma_n + 1, F.n - 1):
        if up[i] and not up[i - 1]:
            sig.append((i + 1, 1))
        elif dn[i] and not dn[i - 1]:
            sig.append((i + 1, -1))
    return sig


def h4_filter(m5, F, span=50):
    H4 = resample(m5, "4h")
    e = H4["close"].ewm(span=span, adjust=False).mean()
    up = (H4["close"] > e).astype(float).shift(1).reindex(F.t, method="ffill").to_numpy()
    dn = (H4["close"] < e).astype(float).shift(1).reindex(F.t, method="ffill").to_numpy()
    return up, dn


def run_alch(m5, args, rng):
    """Устойчивость Alchemist's Trend: сетка соседних настроек, издержки ×2, стороны,
    вклад каждого фильтра."""
    global COST
    print("# 4б. Alchemist's Trend: соседние настройки и вклад фильтров\n")
    F = Frame(resample(m5, "1h"), "H1")
    h4up, h4dn = h4_filter(m5, F)
    cc = cci(F, 20)
    rows = []
    for ma_n in (100, 200, 300):
        for hp in (14, 21, 34, 55, 89):
            for thr in (0, 50, 100, 150):
                sig = alch_signals(F, h4up, h4dn, ma_n, hp, thr, cc=cc)
                for N in (4, 12, 24):
                    tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
                    r = evaluate(F, tr, N, rng)
                    rows.append((ma_n, hp, thr, N, r))
                    print(fmt(f"MA{ma_n} HMA{hp} CCI±{thr} N={N}", r))
    ok = [r for *_, r in rows if "mean" in r]
    pos = sum(r["mean"] > 0 for r in ok)
    allp = sum(all(m > 0 for n, m in r["by"]) for r in ok)
    passed = sum(all(m > 0 for n, m in r["by"]) and r["p"] <= 0.10 for r in ok)
    print(f"\nсетка: {len(ok)} вариантов, среднее > 0: {pos}, > 0 во всех трёх периодах: {allp}, "
          f"прошли отсев: {passed}\n")
    print("# вклад фильтров (MA200, HMA21, CCI±100)")
    for name, kw in [("все четыре", {}), ("без H4", {"use_h4": False}), ("без HMA", {"use_hma": False}),
                     ("без CCI", {"use_cci": False}), ("только MA200 + H4", {"use_hma": False, "use_cci": False}),
                     ("только MA200", {"use_hma": False, "use_cci": False, "use_h4": False})]:
        sig = alch_signals(F, h4up, h4dn, 200, 21, 100, cc=cc, **kw)
        for N in (4, 12, 24):
            tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
            print(fmt(f"{name} N={N}", evaluate(F, tr, N, rng)))
    print("\n# стороны и издержки ×2 (MA200 HMA21 CCI±100)")
    sig = alch_signals(F, h4up, h4dn, 200, 21, 100, cc=cc)
    for N in (4, 12, 24):
        tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
        print(fmt(f"только покупки N={N}", evaluate(F, [x for x in tr if x[1] == 1], N, rng)))
        print(fmt(f"только продажи N={N}", evaluate(F, [x for x in tr if x[1] == -1], N, rng)))
    COST *= 2
    F._cache.clear()
    for N in (4, 12, 24):
        tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
        print(fmt(f"издержки ×2 N={N}", evaluate(F, tr, N, rng)))
    COST /= 2
    F._cache.clear()
    if args.holdout:
        print("\n# отложенная проверка 2026 июнь–октябрь")
        for hp, thr in ((21, 0), (21, 100), (55, 0)):
            sig = alch_signals(F, h4up, h4dn, 200, hp, thr, cc=cc)
            for N in (4, 12, 24):
                tr = [(i, d, trade_result(F, i, d, N)) for i, d in sig]
                print(fmt(f"MA200 HMA{hp} CCI±{thr} N={N}", evaluate(F, tr, N, rng, True), True))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("what", choices=["fvg", "sweep", "msnr", "osc", "alch"])
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    m5 = load_m5(args.bars)
    m5 = m5[m5.index >= "2024-01-01"]
    {"fvg": run_fvg, "sweep": run_sweep, "msnr": run_msnr, "osc": run_osc, "alch": run_alch}[args.what](m5, args, rng)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
