"""Разбор чужих сделок по скринам: с какими уровнями совпала цена входа.

Для каждой сделки (время UTC+0 = время сервера, направление, цена входа, стоп) по минутным барам,
известным ДО времени входа, считает кандидатов-уровней и печатает ближайшие к цене входа:
  * максимум/минимум прошлого дня, прошлой недели, открытие дня;
  * максимум/минимум сессий текущего и прошлого дня: Азия 00–07, Лондон 07–12, Нью-Йорк 12–21;
  * точки разворота M15 и H1 (pivot len 3) за последние 3 дня;
  * края незакрытых FVG M15 и H1 за последние 3 дня;
  * круглые числа (×5, ×10 USD);
  * уровни Фибоначчи 61.8 / 78.6 / 88.6 % и 127.2 / 161.8 % последнего размаха H1-зигзага
    (2 ATR);
  * длина импульса: сколько прошла цена за 30 / 60 / 120 минут до входа (USD и в ATR H1).

Использование:
    python3 tester/tools/level_probe.py --bars bars.csv --trades trades.csv
    trades.csv: id,time,dir,entry,sl   (time — 'YYYY-MM-DD HH:MM', dir — buy/sell)
"""
import argparse

import numpy as np
import pandas as pd


def load(path):
    d = pd.read_csv(path)
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    return d.set_index("time")[["open", "high", "low", "close"]]


def ohlc(m1, rule):
    r = m1.resample(rule, label="left", closed="left")
    return pd.DataFrame({"open": r["open"].first(), "high": r["high"].max(), "low": r["low"].min(),
                         "close": r["close"].last()}).dropna()


def atr(df, n=14):
    pc = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"], (df["high"] - pc).abs(), (df["low"] - pc).abs()], axis=1).max(axis=1)
    return tr.rolling(n).mean()


def pivots(df, L=3):
    h, l = df["high"].to_numpy(), df["low"].to_numpy()
    out = []
    for c in range(L, len(df) - L):
        if h[c] == h[c - L:c + L + 1].max():
            out.append(("max", df.index[c], h[c]))
        if l[c] == l[c - L:c + L + 1].min():
            out.append(("min", df.index[c], l[c]))
    return out


def fvgs(df, until):
    """Незакрытые к моменту until FVG: (вид, время, нижний край, верхний край)."""
    h, l, t = df["high"].to_numpy(), df["low"].to_numpy(), df.index
    out = []
    for j in range(2, len(df)):
        if l[j] > h[j - 2]:
            lo, hi, kind = h[j - 2], l[j], "бычий"
            after = df.iloc[j + 1:]
            after = after[after.index < until]
            if after.empty or after["low"].min() > lo:
                out.append((kind, t[j], lo, hi))
        elif h[j] < l[j - 2]:
            lo, hi, kind = h[j], l[j - 2], "медвежий"
            after = df.iloc[j + 1:]
            after = after[after.index < until]
            if after.empty or after["high"].max() < hi:
                out.append((kind, t[j], lo, hi))
    return out


def zigzag_last(df, th):
    """Последний подтверждённый размах ATR-зигзага: (начало, конец) цен."""
    h, l = df["high"].to_numpy(), df["low"].to_numpy()
    piv, d = [], 0
    hi, lo = h[0], l[0]
    for i in range(1, len(df)):
        t = th[i]
        if not np.isfinite(t):
            continue
        if d >= 0:
            if h[i] > hi:
                hi = h[i]
            if hi - l[i] >= t and d != -1:
                piv.append(hi); d = -1; lo = l[i]; continue
        if d <= 0:
            if l[i] < lo:
                lo = l[i]
            if h[i] - lo >= t and d != 1:
                piv.append(lo); d = 1; hi = h[i]
    return piv[-2:] if len(piv) >= 2 else None


def probe(m1, tr):
    T = pd.Timestamp(tr["time"])
    past = m1[m1.index < T]
    H1, M15, D1 = ohlc(past, "60min"), ohlc(past, "15min"), ohlc(past, "1D")
    a = atr(H1).iloc[-1]
    e, d = float(tr["entry"]), 1 if tr["dir"] == "buy" else -1
    lv = []
    day0 = T.normalize()
    prevd = D1[D1.index < day0]
    if len(prevd):
        lv += [("макс. прошлого дня", prevd["high"].iloc[-1]), ("мин. прошлого дня", prevd["low"].iloc[-1])]
    lv.append(("открытие дня", past[past.index >= day0]["open"].iloc[0] if (past.index >= day0).any() else np.nan))
    wk = T - pd.Timedelta(days=T.dayofweek)
    pw = past[(past.index >= wk.normalize() - pd.Timedelta(days=7)) & (past.index < wk.normalize())]
    if len(pw):
        lv += [("макс. прошлой недели", pw["high"].max()), ("мин. прошлой недели", pw["low"].min())]
    for off, tag in ((0, "сегодня"), (1, "вчера")):
        dd = day0 - pd.Timedelta(days=off)
        for name, a0, a1 in (("Азия", 0, 7), ("Лондон", 7, 12), ("Нью-Йорк", 12, 21)):
            s = past[(past.index >= dd + pd.Timedelta(hours=a0)) & (past.index < dd + pd.Timedelta(hours=a1))]
            if len(s):
                lv += [(f"макс. {name} {tag}", s["high"].max()), (f"мин. {name} {tag}", s["low"].min())]
    since = T - pd.Timedelta(days=3)
    for tfname, df in (("M15", M15), ("H1", H1)):
        dfr = df[df.index >= since]
        for kind, t, p in pivots(dfr):
            lv.append((f"точка разворота {tfname} ({kind}, {t:%d.%m %H:%M})", p))
        for kind, t, lo, hi in fvgs(dfr, T):
            lv += [(f"FVG {tfname} {kind} {t:%d.%m %H:%M}: низ", lo), (f"FVG {tfname} {kind} {t:%d.%m %H:%M}: верх", hi)]
    for step in (5, 10):
        r = round(e / step) * step
        lv.append((f"круглое ×{step}", r))
    z = zigzag_last(H1.iloc[-500:], (2 * atr(H1.iloc[-500:])).to_numpy())
    if z:
        p0, p1 = z
        for f in (0.618, 0.786, 0.886):
            lv.append((f"Фибо {f * 100:.1f}% размаха H1 {p0:.2f}→{p1:.2f}", p1 - (p1 - p0) * f))
        for f in (1.272, 1.618):
            lv.append((f"Фибо {f * 100:.1f}% размаха H1 {p0:.2f}→{p1:.2f}", p0 + (p1 - p0) * f))
    lv = [(n, float(p)) for n, p in lv if np.isfinite(p)]
    lv.sort(key=lambda x: abs(x[1] - e))
    imp = []
    for mins in (30, 60, 120):
        w = past[past.index >= T - pd.Timedelta(minutes=mins)]
        if len(w):
            mv = w["close"].iloc[-1] - w["open"].iloc[0]
            imp.append(f"{mins} мин: {mv:+.1f} USD ({mv / a:+.1f} ATR)")
    print(f"\n## {tr['id']}: {tr['dir']} {e:.2f}, стоп {float(tr['sl']):.2f} ({abs(e - float(tr['sl'])):.2f} USD = "
          f"{abs(e - float(tr['sl'])) / a:.2f} ATR H1), {T:%d.%m %H:%M}, ATR H1 {a:.1f}")
    print("импульс до входа: " + "; ".join(imp))
    print("ближайшие уровни:")
    for n, p in lv[:12]:
        print(f"  {p:9.2f}  ({p - e:+6.2f})  {n}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--trades", required=True)
    args = ap.parse_args()
    m1 = load(args.bars)
    for _, tr in pd.read_csv(args.trades).iterrows():
        probe(m1, tr)


if __name__ == "__main__":
    main()
