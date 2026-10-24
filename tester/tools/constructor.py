"""Конструктор ботов: перебор сочетаний «вход × фильтры × выход» из уже проверенных блоков.

Блоки:
  * входы (сигнал → сделка с ценой входа и стопом в USD):
      alch-H1/H2/H4 — Alchemist's Trend (SMA200, HMA21, CCI20 ±100, H4 над/под EMA50), вход по
                      рынку на открытии следующего бара, стоп 3 × ATR14 рабочего ТФ;
      bos-H1/H4     — пробой структуры по тренду (structure.py, len 5, только BOS, не CHoCH),
                      вход и стоп как у Alchemist;
      fvg-M15/M30/H1 — лимитки FVG-робота с его настройками (fvg_sim.run: L50 N20 K3 near,
                      возраст ≥ 10 баров, разрыв ≥ 0.2 ATR, стоп за разрывом + 0.3 USD, 0.3–1.0 ATR);
      liq-streak-M3/M15 — снятие ликвидности по тренду цепочки экстремумов (liq-grab, LEVEL_STREAK:
                      глубина 30, цепочка 5, мин. 3, уровень — ближняя свеча цепочки);
      liq-day-M15 / liq-asia-M15 — снятие максимума/минимума прошлого дня / Азии 00–07 с закрытием
                      обратно, против прокола, одна сделка на сторону в день (liq-grab, RangeSweep);
                      у всех liq — вход по рынку на следующем баре, стоп 1.5 × ATR14 ТФ (не меньше 1 USD);
      asia-brk-M15  — пробой коробки Азии 00–07 (hybrid-asia-breakout v1.1): первое закрытие M15 за
                      коробкой ± 0.2 USD в 07–11, коробка ≥ 3 USD; стоп за противоположной границей
                      + 0.2 USD (не меньше 1 USD);
      chan-H4 / chan-D1 — пробой канала Дончиана 20 (hybrid-trend-channel): закрытие за максимумом/
                      минимумом 20 баров, стоп 2 × ATR20, удержание до 60 суток;
  * фильтры (на минуте входа, по закрытым барам):
      d1   — off / struct (структура D1 len 5 по направлению сделки) / ema (закрытие D1 vs EMA50);
      sess — all / 07–20 (Лондон + Нью-Йорк) / 12–20 (Нью-Йорк), час входа по серверу (UTC+0);
      reg  — off / trend (ER(D1, 20) ≥ 0.3) / flat (ER < 0.3), как MarketRegime;
      news — off / avoid (нет входа за 60 минут до и после NFP, CPI, FOMC, ISM из NewsTimes.mqh);
  * выходы (стоп всегда стоит; позиция держится не дольше 5 суток, потом закрытие по рынку):
      tp3 / tp5 / tp10 — тейк X R;
      part2-6be — половина на 2R, стоп остатка в безубыток, остаток на 6R;
      time12h / time24h — закрытие по времени (как TimeExit), если раньше не сработал стоп;
      trail1-1 / trail2-1.5 — после +a R стоп идёт за лучшей ценой на расстоянии k R, тейка нет;
      own — родной выход бота: у chan — закрытие за каналом 10 баров, у asia-brk — закрытие в 20:00.
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

ENTRIES = ["alch-H1", "alch-H2", "alch-H4", "bos-H1", "bos-H4", "fvg-M15", "fvg-M30", "fvg-H1",
           "liq-streak-M3", "liq-streak-M15", "liq-day-M15", "liq-asia-M15", "asia-brk-M15",
           "chan-H4", "chan-D1"]
D1F = ["off", "struct", "ema"]
SESS = {"all": (0, 24), "07-20": (7, 20), "12-20": (12, 20)}
REG = ["off", "trend", "flat"]
NEWS = ["off", "avoid"]
EXITS = ["tp3", "tp5", "tp10", "part2-6be", "time12h", "time24h", "trail1-1", "trail2-1.5"]
TFMIN = {"M3": 3, "M15": 15, "M30": 30, "H1": 60, "H2": 120, "H4": 240, "D1": 1440}
CAP_DAYS = {"chan": 60}          # трендовые входы держатся дольше 5 суток
OWN_FN = {}                      # родные выходы: имя входа → (минута входа, направление) → минута выхода


def kind_of(name):
    return name.split("-")[0]


def tf_of(name):
    return name.split("-")[-1]


def cap_of(name):
    return CAP_DAYS.get(kind_of(name), 5) * 24 * 60


def exits_of(name):
    return EXITS + (["own"] if name in OWN_FN else [])


# ── выходы ────────────────────────────────────────────────────────────

def exit_trade(P, f, d, entry, sd, ex, cap=CAP_MIN, own=None):
    """Сделка с минуты f. Возврат (R с издержками и свопом, индекс минуты выхода).
    cap — предел удержания, минут; own — родной выход (минута входа, направление) → минута выхода."""
    t0 = P.t[f]
    if ex == "own":
        end = own(f, d)
    elif ex.startswith("time"):
        end = int(np.searchsorted(P.t, t0 + np.timedelta64(int(ex[4:-1]) * 60, "m"))) - 1
    else:
        end = int(np.searchsorted(P.t, t0 + np.timedelta64(cap, "m"))) - 1
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
    elif ex.startswith("time") or ex == "own":
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
    """Сигналы (бар входа i, направление[, стоп USD]) → (минута, направление, цена, стоп USD).
    Без стопа в сигнале — mult × ATR14 сигнального бара."""
    atr = F.atr(14)
    out = []
    for x in sig:
        i, d = x[0], x[1]
        sd = x[2] if len(x) > 2 else mult * atr[i - 1]
        if i >= F.n or not np.isfinite(sd):
            continue
        f = int(np.searchsorted(P.t, F.t[i].to_datetime64()))
        if f >= P.n:
            continue
        entry = P.o[f] + (SPREAD if d == 1 else 0.0)
        out.append((f, d, entry, sd))
    return out


def liq_streak(F, depth=30, lookback=5, min_streak=3, mult=1.5):
    """liq-grab LEVEL_STREAK (StreakSweepSignal, сигнал по закрытой свече j, вход на j+1)."""
    h, l, c = F.h, F.l, F.c
    atr = F.atr(14)
    trend, sig = 0, []
    for j in range(depth, F.n - 1):
        idx = []
        for b in range(j - 1, j - depth + 2, -1):       # серия: rates[2 … depth−2]
            if h[b] > h[b - 1] or l[b] < l[b - 1]:
                idx.append(b)
                if len(idx) == lookback:
                    break
        if len(idx) < min_streak:
            continue
        sh = sl = 1
        for k in range(1, len(idx)):
            if h[idx[k - 1]] > h[idx[k]]:
                sh += 1
            else:
                break
        for k in range(1, len(idx)):
            if l[idx[k - 1]] < l[idx[k]]:
                sl += 1
            else:
                break
        if sh >= min_streak and sl < min_streak:
            trend = 1
        elif sl >= min_streak and sh < min_streak:
            trend = 2
        sd = max(mult * atr[j], 1.0)
        if trend == 1 and l[j] < l[idx[0]] < c[j]:
            sig.append((j + 1, 1, sd))
        elif trend == 2 and h[j] > h[idx[0]] > c[j]:
            sig.append((j + 1, -1, sd))
    return sig


def liq_range(F, D1, mode, mult=1.5):
    """liq-grab LEVEL_PREV_DAY / LEVEL_ASIA_RANGE (RangeSweepSignal): прокол границы и закрытие
    обратно — против прокола, одна сделка на сторону в день."""
    atr = F.atr(14)
    day = F.t.normalize()
    key = day.where(F.t.dayofweek != 6, day + pd.Timedelta(days=1))   # воскресенье — к понедельнику
    if mode == "day":
        prev = D1.shift(1).reindex(key)
        hi, lo = prev["high"].to_numpy(), prev["low"].to_numpy()
        valid = np.ones(F.n, bool)
    else:
        asia = F.df[F.t.hour < 7].groupby(day[F.t.hour < 7]).agg({"high": "max", "low": "min"})
        a = asia.reindex(day)
        hi, lo = a["high"].to_numpy(), a["low"].to_numpy()
        valid = F.t.hour >= 7
    done_h, done_l, sig = None, None, []
    for j in range(F.n - 1):
        if not valid[j] or not np.isfinite(hi[j]) or not np.isfinite(atr[j]):
            continue
        sd = max(mult * atr[j], 1.0)
        if F.h[j] > hi[j] and F.c[j] < hi[j] and done_h != key[j]:
            done_h = key[j]; sig.append((j + 1, -1, sd))
        elif F.l[j] < lo[j] and F.c[j] > lo[j] and done_l != key[j]:
            done_l = key[j]; sig.append((j + 1, 1, sd))
    return sig


def asia_breakout(F, min_box=3.0, buf=0.2, sl_buf=0.2, end_hour=11):
    """hybrid-asia-breakout v1.1 (BREAKOUT_CLOSE, BREAKOUT_SL_OPPOSITE): первая сделка дня."""
    day = F.t.normalize()
    m = F.t.hour < 7
    a = F.df[m].groupby(day[m]).agg({"high": "max", "low": "min"}).reindex(day)
    hi, lo = a["high"].to_numpy(), a["low"].to_numpy()
    hr = F.t.hour.to_numpy()
    done, sig = None, []
    for j in range(F.n - 1):
        if not (7 <= hr[j] < end_hour) or done == day[j] or not np.isfinite(hi[j]) or hi[j] - lo[j] < min_box:
            continue
        if F.c[j] > hi[j] + buf:
            done = day[j]; sig.append((j + 1, 1, max(F.c[j] - lo[j] + sl_buf, 1.0)))
        elif F.c[j] < lo[j] - buf:
            done = day[j]; sig.append((j + 1, -1, max(hi[j] - F.c[j] + sl_buf, 1.0)))
    return sig


def channel(F, n_in=20, mult=2.0):
    """hybrid-trend-channel: закрытие за максимумом/минимумом n_in предыдущих баров."""
    atr = F.atr(20)
    hh = pd.Series(F.h).rolling(n_in).max().shift(1).to_numpy()
    ll = pd.Series(F.l).rolling(n_in).min().shift(1).to_numpy()
    sig = []
    for j in range(n_in, F.n - 1):
        if not np.isfinite(atr[j]):
            continue
        if F.c[j] > hh[j]:
            sig.append((j + 1, 1, max(mult * atr[j], 1.0)))
        elif F.c[j] < ll[j]:
            sig.append((j + 1, -1, max(mult * atr[j], 1.0)))
    return sig


def next_true(flag):
    """Для каждого i — первый индекс ≥ i, где flag истинен (len(flag) — нет)."""
    n = len(flag)
    idx = np.where(flag, np.arange(n), n)
    return np.minimum.accumulate(idx[::-1])[::-1]


def channel_exit(P, F, n_out=10):
    """Родной выход канала: закрытие бара за минимумом (покупка) / максимумом n_out баров до него."""
    hh = pd.Series(F.h).rolling(n_out).max().shift(1).to_numpy()
    ll = pd.Series(F.l).rolling(n_out).min().shift(1).to_numpy()
    nx = {1: next_true(F.c < ll), -1: next_true(F.c > hh)}
    nxt_open = np.r_[F.t[1:].to_numpy(), F.t[-1].to_datetime64() + np.timedelta64(1, "D")]
    end_min = np.searchsorted(P.t, nxt_open) - 1          # последняя минута бара
    ft = F.t.to_numpy()

    def own(f, d):
        i = int(np.searchsorted(ft, P.t[f], side="right")) - 1
        j = nx[d][max(i, 0)]
        return int(end_min[j]) if j < F.n else P.n - 1
    return own


def close_at_hour(P, hour=20):
    def own(f, d):
        t = P.t[f]
        c = t.astype("datetime64[D]") + np.timedelta64(hour, "h")
        if c <= t:
            c += np.timedelta64(1, "D")
        return int(np.searchsorted(P.t, c)) - 1
    return own


def build_entries(P, df, names):
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    out = {}
    h4 = S.resample(m1, "4h")
    for name in names:
        kind, tf = kind_of(name), tf_of(name)
        rule = f"{TFMIN[tf]}min"
        if kind == "fvg":
            out[name] = FS.run(P, TFMIN[tf], 50, 20, 3, "near", "tp10", False, minSL=0.3, maxSL=1.0,
                               mingap=0.2, minage=10, atr_mode=True, raw=True)
            continue
        F = S.Frame(S.resample(m1, "1D" if tf == "D1" else rule), tf)
        if kind == "liq":
            sub = name.split("-")[1]
            sig = liq_streak(F) if sub == "streak" else liq_range(F, S.resample(m1, "1D"), sub)
            out[name] = market_entries(P, F, sig)
            continue
        if kind == "asia":
            out[name] = market_entries(P, F, asia_breakout(F))
            OWN_FN[name] = close_at_hour(P, 20)
            continue
        if kind == "chan":
            out[name] = market_entries(P, F, channel(F))
            OWN_FN[name] = channel_exit(P, F)
            continue
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

    def outcomes(self, k, d, sd, ex, name):
        b = round(np.log(sd) / np.log(1.1))                   # стоп — корзины по 10 %
        cap, own = cap_of(name), OWN_FN.get(name)
        key = (k, d, b, ex, cap, name if ex == "own" else "")
        if key not in self.cache:
            P, sdb = self.P, 1.1 ** b
            res = []
            for f in self.rng.choice(self.idx[k], self.pool, replace=False):
                entry = P.o[f] + (SPREAD if d == 1 else 0.0)
                res.append((P.hour[f], exit_trade(P, f, d, entry, sdb, ex, cap, own)[0]))
            self.cache[key] = np.array(res)
        return self.cache[key]

    def sims(self, rows, ex, name):
        """rows: (период, час, направление, стоп). Средний R случайных входов, RUNS прогонов."""
        acc = np.zeros(RUNS)
        for k, hr, d, sd in rows:
            pool = self.outcomes(int(k), int(d), sd, ex, name)
            same = pool[pool[:, 0] == hr, 1]
            if len(same) < 8:
                same = pool[:, 1]
            acc += same[self.rng.integers(0, len(same), RUNS)]
        return acc / max(len(rows), 1)


# ── перебор ───────────────────────────────────────────────────────────

def combos(entries=ENTRIES):
    for e in entries:
        for d1f, sess, reg, news, ex in itertools.product(D1F, SESS, REG, NEWS, exits_of(e)):
            yield f"{e}|{d1f}|{sess}|{reg}|{news}|{ex}"


def prepare(args):
    P = FS.Path(args.bars, start="2023-01-01")
    df = P.df
    st, ema, er = day_series(P, df)
    ctx = {"st": st, "ema": ema, "er": er, "news": news_mask(P)}
    return P, df, ctx


def outcomes_for(P, cands, ex, name):
    """Все кандидаты одного входа с одним выходом: массивы f, d, sd, R, индекс выхода."""
    cap, own = cap_of(name), OWN_FN.get(name)
    rows = [(f, d, sd) + exit_trade(P, f, d, entry, sd, ex, cap, own) for f, d, entry, sd in cands]
    return np.array(rows, float).reshape(-1, 5)


def evaluate(P, ctx, mk, tab, name, holdout=False):
    e, d1f, sess, reg, news, ex = name.split("|")
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
    sims = mk.sims(rows, ex, e)
    sd = sims.std() if sims.std() > 0 else np.nan
    res.update(rnd=sims.mean(), p=float((sims >= r.mean()).mean()), z=(r.mean() - sims.mean()) / sd)
    if holdout:
        rh = t[per == NP, 3]
        res.update(n_26b=len(rh), R_26b=rh.mean() if len(rh) else np.nan,
                   pf_26b=(rh[rh > 0].sum() / -rh[rh < 0].sum()) if (rh < 0).any() else np.inf)
        if len(rh):
            hs = mk.sims([(NP, P.hour[int(t[i, 0])], t[i, 1], t[i, 2]) for i in np.flatnonzero(per == NP)], ex, e)
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
            r, _ = evaluate(P, ctx, mk, outcomes_for(P, ents[e], ex, e), n, holdout=args.cmd == "final")
            print(line(r, args.cmd == "final"), flush=True)
        return
    entries = args.entries.split(",")
    res, zs = [], []
    for e in entries:
        cands = build_entries(P, df, [e])[e]
        print(f"# {e}: кандидатов {len(cands)}", flush=True)
        for ex in exits_of(e):
            tab = outcomes_for(P, cands, ex, e)
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
