"""Структура рынка как у LimonFx (indicators/tradingview/03-…): BOS / CHoCH и тренд структуры —
и фильтр для Alchemist's Trend.

Структура (как structure() в индикаторе):
  * точка разворота — ta.pivothigh/pivotlow(len, len): максимум (минимум) окна из len баров слева и
    справа, подтверждается через len баров;
  * пробой вверх — закрытие пересекло снизу вверх последний подтверждённый максимум (если
    минимумов уже не меньше двух). Тренд → +1; если был −1 — это CHoCH, иначе BOS. Пробитый
    уровень убирается, следующий пробой — только нового максимума. Вниз — зеркально.
  * internal — len 5, swing — len 50. Как в индикаторе: если на баре подтвердились и максимум, и
    минимум, учитывается только максимум.

Фильтр: сигналы Alchemist (screen.py, alch_signals, одна позиция за раз) делятся по тренду
структуры на момент сигнала — на рабочем ТФ и на старших (последний закрытый бар). Сравниваем
сделки «по структуре» и «против».

Использование:
    python3 tester/tools/structure.py --bars bars_XAUUSDm_M1.csv [--holdout]
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import screen as S  # noqa: E402


def pivots(h, l, L):
    """Подтверждённые на баре n точки (центр n − L). Возвращает массивы ph, pl (nan — нет точки)."""
    n = len(h)
    ph = np.full(n, np.nan); pl = np.full(n, np.nan)
    for c in range(L, n - L):
        wh = h[c - L:c + L + 1]
        if h[c] == wh.max() and h[c] > h[c - L:c].max():
            ph[c + L] = h[c]
        wl = l[c - L:c + L + 1]
        if l[c] == wl.min() and l[c] < l[c - L:c].min():
            pl[c + L] = l[c]
    return ph, pl


def structure(df, L):
    """Тренд структуры после закрытия каждого бара: +1 / −1 / 0 (ещё не определён) и события:
    +2 CHoCH вверх, +1 BOS вверх, −1 BOS вниз, −2 CHoCH вниз, 0 нет."""
    h, l, c = df["high"].to_numpy(), df["low"].to_numpy(), df["close"].to_numpy()
    ph, pl = pivots(h, l, L)
    n = len(c)
    trend = np.zeros(n, int); ev = np.zeros(n, int)
    up = None; dn = None          # последний непробитый максимум / минимум
    nlow = nhigh = 0
    tr = 0
    for i in range(n):
        if not np.isnan(ph[i]):
            up = ph[i]; nhigh += 1
        elif not np.isnan(pl[i]):
            dn = pl[i]; nlow += 1
        if i > 0:
            if up is not None and nlow > 1 and c[i] > up and c[i - 1] <= up:
                ev[i] = 2 if tr < 0 else 1
                tr = 1; up = None
            if dn is not None and nhigh > 1 and c[i] < dn and c[i - 1] >= dn:
                ev[i] = -2 if tr > 0 else -1
                tr = -1; dn = None
        trend[i] = tr
    return trend, ev


def htf_on(F, df_htf, rule, L):
    """Тренд старшего ТФ на момент закрытия бара рабочего ТФ (последний закрытый бар старшего)."""
    tr, _ = structure(df_htf, L)
    close_t = df_htf.index + pd.Timedelta(rule)
    s = pd.Series(tr, index=close_t)
    tf_close = F.t + (F.t[1] - F.t[0])
    return s.reindex(tf_close, method="ffill").fillna(0).astype(int).to_numpy()


def d1_ema_on(F, D1, span):
    """+1 / −1: закрытие последнего закрытого дня выше / ниже EMA(span)."""
    e = D1["close"].ewm(span=span, adjust=False).mean()
    v = np.sign(D1["close"] - e).astype(int)
    s = pd.Series(v.to_numpy(), index=D1.index + pd.Timedelta("1D"))
    tf_close = F.t + (F.t[1] - F.t[0])
    return s.reindex(tf_close, method="ffill").fillna(0).astype(int).to_numpy()


def line(name, r):
    if "mean" not in r:
        return f"{name:<34} нет сделок"
    by = " ".join(f"{m:+6.2f}({n})" for n, m in r["by"])
    return (f"{name:<34} n={r['n']:4d} buy={r['long']:.2f} mean={r['mean']:+6.2f} PF={r['pf']:4.2f} "
            f"p={r['p']:.3f} итог={r['mean'] * r['n']:+7.0f} | {by}"
            + (f" | 26b n={r['hold'][0]} mean={r['hold'][1]:+.2f}" if "hold" in r else ""))


def one_position(sig, N):
    out, busy = [], -1
    for i, d in sig:
        if i > busy:
            out.append((i, d)); busy = i + N - 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    args = ap.parse_args()
    rng = np.random.default_rng(1)
    m5_all = S.load_m5(args.bars)
    m5 = m5_all[m5_all.index >= "2024-01-01"]
    frames = {r: S.resample(m5, r) for r in ("1h", "2h", "4h")}
    # D1 — с 2023 года: к январю 2024 тренд и EMA уже «разогреты», как у робота в тестере
    D1 = S.resample(m5_all, "1D")

    for tf, N in (("1h", 12), ("1h", 24), ("2h", 6), ("4h", 3)):
        F = S.Frame(frames[tf], tf)
        h4up, h4dn = S.h4_filter(m5, F)
        cc = S.cci(F, 20)
        raw = S.alch_signals(F, h4up, h4dn, 200, 21, 100, cc=cc)
        feats = {}
        feats[f"{tf} внутр."] = structure(frames[tf], 5)[0]
        feats[f"{tf} свинг"] = structure(frames[tf], 50)[0]
        for rule in ("1h", "4h"):
            if rule != tf and pd.Timedelta(rule) > pd.Timedelta(tf):
                feats[f"{rule} внутр."] = htf_on(F, frames[rule], rule, 5)
        feats["D1 внутр."] = htf_on(F, D1, "1D", 5)
        print(f"# Alchemist {tf}, выход {N} баров (MA200 HMA21 CCI±100 + H4 EMA50), одна позиция")
        def trades(keep):
            # фильтр — до правила «одна позиция»: отброшенный сигнал позицию не занимает
            return [(i, d, S.trade_result(F, i, d, N)) for i, d in one_position([x for x in raw if keep(*x)], N)]

        print(S.fmt("все сигналы", S.evaluate(F, trades(lambda i, d: True), N, rng, args.holdout), args.holdout))
        for name, tr in feats.items():
            # тренд на закрытии сигнального бара (вход — на открытии следующего, i)
            for lab, keep in (("по структуре", lambda i, d: tr[i - 1] == d),
                              ("против", lambda i, d: tr[i - 1] == -d)):
                print(S.fmt(f"  {name}: {lab}", S.evaluate(F, trades(keep), N, rng, args.holdout), args.holdout))
        print()

    print("# Фильтр по D1: структура (длина точек 3 / 5 / 8) против простого тренда D1 (EMA)")
    for tf, N in (("1h", 12), ("1h", 24), ("2h", 6), ("4h", 3)):
        F = S.Frame(frames[tf], tf)
        h4up, h4dn = S.h4_filter(m5, F)
        cc = S.cci(F, 20)
        raw = S.alch_signals(F, h4up, h4dn, 200, 21, 100, cc=cc)
        filt = {"без фильтра": None}
        for L in (3, 5, 8):
            filt[f"D1 структура L{L}"] = htf_on(F, D1, "1D", L)
        for span in (20, 50):
            filt[f"D1 закрытие vs EMA{span}"] = d1_ema_on(F, D1, span)
        print(f"## {tf}, выход {N}")
        for name, tr in filt.items():
            keep = (lambda i, d: True) if tr is None else (lambda i, d, tr=tr: tr[i - 1] == d)
            t = [(i, d, S.trade_result(F, i, d, N)) for i, d in one_position([x for x in raw if keep(*x)], N)]
            r = np.array([x[2] for x in t if x[2] is not None and 0 <= F.period[x[0]] < len(S.PERIODS)])
            eq = np.cumsum(r)
            dd = float(np.max(np.maximum.accumulate(np.r_[0, eq]) - np.r_[0, eq]))
            print(line(name, S.evaluate(F, t, N, rng, args.holdout)) + f" | просадка {dd:.0f}, итог/просадка {eq[-1] / dd:.2f}")
        print()


if __name__ == "__main__":
    main()
