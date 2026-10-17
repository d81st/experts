"""Сетки Ганна (индикатор 04) и «нумерологии» (05): работают ли зоны на фиксированных расстояниях
от последнего экстремума (indicators/tradingview/).

Экстремумы — ATR-зигзаг на H1 (как Include/Levels/AtrZigZag.mqh): точка подтверждается, когда
цена отошла от неё на k × ATR(14). От подтверждённой точки E зоны строятся в сторону цены (от
максимума — вниз, от минимума — вверх) и живут до подтверждения следующей точки — как если бы
трейдер перерисовывал индикатор на каждом новом экстремуме. Расстояние d считается от E в сторону
зон, в USD (множитель пунктов 1).

Сетки:
  gann — 04: [9–11, 17–19, 25–28, 37–40, 49–53, 65–69, 81–86, 101–106, 121–127, 145–151] × P,
         P = max(⌊R/100⌋, 1), R — размах волны, закончившейся в E;
  num  — 05: [8–10, 16–18, 25–27, 35–40, 47–52, 66–68, 80–85, 99–104, 120–126, 143–149,
         167–175, 189–195].
Контроль — та же сетка со сдвигом s USD (ширина зон та же) и с растяжением центров зон × c.
Если числа Ганна что-то значат, у настоящей сетки (s = 0, c = 1) показатель заметно лучше, чем у
сдвинутых и растянутых; на графике «показатель от сдвига» — пик в нуле.

Проверки:
  A — где закончился откат: d следующей точки зигзага; доля попаданий в зоны.
  B — мелкие развороты внутри отката: точки зигзага M5 с порогом 0.5 ATR(H1) между
      подтверждением E и следующей точки; доля попаданий в зоны.
  C — «гонка» при первом касании зоны (M5): отскок на r раньше, чем пробой зоны на r
      (дальний край + r); бар, задевший обе цели, и гонки дольше суток отбрасываются.
      Отдельно — подход со стороны E (откат дошёл до зоны) и с дальней стороны (возврат).

Использование:
    python3 tester/tools/gann_grid.py --bars bars_XAUUSDm_M1.csv [--k 2] [--holdout] {A,B,C,all}
"""
import argparse

import numpy as np
import pandas as pd

PERIODS = [("2024", "2024-01-01", "2025-01-01"),
           ("2025", "2025-01-01", "2026-01-01"),
           ("26a", "2026-01-01", "2026-06-01")]
HOLDOUT = ("26b", "2026-06-01", "2027-01-01")

GANN = (np.array([9, 17, 25, 37, 49, 65, 81, 101, 121, 145], float),
        np.array([11, 19, 28, 40, 53, 69, 86, 106, 127, 151], float))
NUM = (np.array([8, 16, 25, 35, 47, 66, 80, 99, 120, 143, 167, 189], float),
       np.array([10, 18, 27, 40, 52, 68, 85, 104, 126, 149, 175, 195], float))
SHIFTS = [x / 2 for x in range(-12, 13)]            # −6 … +6 USD через 0.5
SCALES = [round(0.70 + 0.05 * i, 2) for i in range(13)]   # 0.70 … 1.30


# ── данные ────────────────────────────────────────────────────────────

def load(path):
    d = pd.read_csv(path)
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    d = d[d["time"] >= "2023-11-01"].set_index("time")
    return d[["open", "high", "low", "close"]]


def resample(m1, rule):
    r = m1.resample(rule, label="left", closed="left")
    o = pd.DataFrame({"open": r["open"].first(), "high": r["high"].max(),
                      "low": r["low"].min(), "close": r["close"].last()}).dropna()
    return o


def atr_sma(df, n=14):
    """ATR как в MT5: простое среднее истинного диапазона."""
    h, l, c = df["high"].to_numpy(), df["low"].to_numpy(), df["close"].to_numpy()
    pc = np.r_[np.nan, c[:-1]]
    tr = np.nanmax(np.vstack([h - l, np.abs(h - pc), np.abs(l - pc)]), axis=0)
    return pd.Series(tr).rolling(n).mean().to_numpy()


def period_of(ts, holdout):
    names = PERIODS + ([HOLDOUT] if holdout else [])
    for name, a, b in names:
        if pd.Timestamp(a) <= ts < pd.Timestamp(b):
            return name
    return None


def zigzag(t, h, l, th, bar_len):
    """ATR-зигзаг по закрытым барам (логика AtrZigZagStep). th[i] — порог на баре i.
    Возвращает список точек: (тип +1 максимум / −1 минимум, цена, время точки, время подтверждения)."""
    out = []
    d = 0
    cH = cL = None
    cHt = cLt = None
    for i in range(len(h)):
        if not np.isfinite(th[i]):
            continue
        conf = t[i] + bar_len
        if d == 0:
            if cH is None or h[i] > cH:
                cH, cHt = h[i], t[i]
            if cL is None or l[i] < cL:
                cL, cLt = l[i], t[i]
            if cHt < t[i] and cH - l[i] >= th[i]:
                out.append((1, cH, cHt, conf)); d = -1; cL, cLt = l[i], t[i]
            elif cLt < t[i] and h[i] - cL >= th[i]:
                out.append((-1, cL, cLt, conf)); d = 1; cH, cHt = h[i], t[i]
            continue
        if d == 1:
            if h[i] > cH:
                cH, cHt = h[i], t[i]
                continue
            if cH - l[i] >= th[i]:
                out.append((1, cH, cHt, conf)); d = -1; cL, cLt = l[i], t[i]
            continue
        if l[i] < cL:
            cL, cLt = l[i], t[i]
            continue
        if h[i] - cL >= th[i]:
            out.append((-1, cL, cLt, conf)); d = 1; cH, cHt = h[i], t[i]
    return out


# ── сетки ─────────────────────────────────────────────────────────────

def grid(kind, P=1.0, s=0.0, c=1.0):
    a, b = GANN if kind == "gann" else NUM
    a, b = a * P, b * P
    mid, half = (a + b) / 2 * c + s, (b - a) / 2
    return mid - half, mid + half


def in_bands(d, lo, hi):
    """Для массива расстояний d — попало ли в какую-нибудь зону."""
    d = np.asarray(d)[:, None]
    return ((d >= lo[None, :]) & (d <= hi[None, :])).any(axis=1)


def variants(kind):
    """(метка, s, c): сдвиги при c = 1 и растяжения при s = 0."""
    v = [(f"s{s:+.1f}", s, 1.0) for s in SHIFTS]
    v += [(f"c{c:.2f}", 0.0, c) for c in SCALES if c != 1.0]
    return v


# ── окна: от подтверждения точки E до подтверждения следующей ─────────

def windows(H1, k, holdout):
    atr = atr_sma(H1)
    th = k * atr
    atr_at = pd.Series(atr, index=H1.index + pd.Timedelta(hours=1))   # ATR на момент закрытия бара
    piv = zigzag(H1.index.to_numpy(), H1["high"].to_numpy(), H1["low"].to_numpy(), th,
                 np.timedelta64(60, "m"))
    W = []
    for i in range(1, len(piv) - 1):
        typ, E, tE, cE = piv[i]
        per = period_of(pd.Timestamp(cE), holdout)
        if per is None:
            continue
        R = abs(E - piv[i - 1][1])
        nxt = piv[i + 1]
        W.append(dict(sgn=-1 if typ == 1 else 1, E=E, tE=tE, a=cE, b=nxt[3], per=per,
                      P=max(np.floor(R / 100), 1.0), dnext=abs(nxt[1] - E), tnext=nxt[2],
                      atr=float(atr_at.asof(pd.Timestamp(cE)))))
    return W


def table(rows, title, boot=2000):
    """rows: {метка: [(период, попаданий, всего) по окнам]} — окна в одном порядке у всех меток.
    Печать доли по периодам; контроль — сдвиги 2…6 USD в обе стороны (симметричный набор снимает
    общий наклон: ближе к E разворотов больше; растяжения меняют покрытые расстояния и в контроль
    не идут). Значимость — бутстрэп по окнам: разница «настоящая − среднее контроля», 95 %
    интервал и доля прогонов, где разница ≤ 0."""
    pers = sorted({x[0] for r in rows.values() for x in r})
    print(f"## {title}")
    print("вариант | " + " | ".join(pers) + " | все")
    labs = list(rows)
    per = np.array([x[0] for x in rows[labs[0]]])
    Hh = np.array([[x[1] for x in rows[l]] for l in labs], float)
    Nn = np.array([[x[2] for x in rows[l]] for l in labs], float)
    for i, lab in enumerate(labs):
        cells = []
        for p in pers:
            m = per == p
            n = Nn[i, m].sum()
            cells.append(f"{Hh[i, m].sum() / n:.3f} ({int(n)})" if n else "—")
        mark = "  ← настоящая" if lab == "s+0.0" else ""
        print(f"{lab} | {' | '.join(cells)} | {Hh[i].sum() / max(Nn[i].sum(), 1):.3f}{mark}")
    it = labs.index("s+0.0")
    ic = [i for i, l in enumerate(labs) if l.startswith("s") and 2.0 <= abs(float(l[1:])) <= 6.0]

    def diff(idx):
        h, n = Hh[:, idx].sum(axis=1), Nn[:, idx].sum(axis=1)
        r = h / np.maximum(n, 1)
        return r[it] - r[ic].mean(), r[ic].mean()

    d0, c0 = diff(np.arange(Hh.shape[1]))
    rng = np.random.default_rng(1)
    bs = np.array([diff(rng.integers(0, Hh.shape[1], Hh.shape[1]))[0] for _ in range(boot)])
    lo, hi = np.percentile(bs, [2.5, 97.5])
    print(f"настоящая {c0 + d0:.3f}, контроль (сдвиги ±2…6) {c0:.3f}: разница {d0 * 100:+.1f} п.п., "
          f"95 % [{lo * 100:+.1f}; {hi * 100:+.1f}], p = {np.mean(bs <= 0):.3f}\n")
    return d0, lo, hi


# ── поправка на форму распределения ───────────────────────────────────
# Расстояния до разворотов распределены «горбом». Если зоны стоят на вершине горба, симметричные
# сдвиги дают меньше попаданий и без всякого эффекта сетки. Ноль: каждое расстояние размываем
# на U(−J, J) — тонкая структура (зоны шириной 2–6 USD) исчезает, общая форма остаётся. Эффект
# сетки = разница «настоящая − контроль» на данных минус та же разница на размытых.

def excess(pts, kind, title, J=6.0, draws=2000):
    """pts: [(окно, массив расстояний)]. Печать по периодам и в целом."""
    labs = [(0.0, "true")] + [(sv, "ctrl") for sv in SHIFTS if 2.0 <= abs(sv) <= 6.0]
    d = np.concatenate([x[1] for x in pts])
    win = np.concatenate([np.full(len(x[1]), i) for i, x in enumerate(pts)])
    P = np.concatenate([np.full(len(x[1]), x[0]["P"]) for x in pts])
    per = np.array([x[0]["per"] for x in pts])
    nw = len(pts)

    def hitmat(dd):
        H = np.zeros((len(labs), len(dd)), bool)
        for pv in np.unique(P):
            m = P == pv
            for v, (sv, _) in enumerate(labs):
                lo, hi = grid(kind, pv, sv, 1.0)
                H[v, m] = in_bands(dd[m], lo, hi)
        return H

    def diff(H, w):
        r = (H * w).sum(axis=1) / w.sum()
        return r[0] - r[1:].mean()

    rng = np.random.default_rng(7)
    H0 = hitmat(d).astype(float)
    # ожидаемое попадание каждой точки без эффекта — среднее по 100 размытиям
    Hn = np.mean([hitmat(np.abs(d + rng.uniform(-J, J, len(d)))) for _ in range(100)], axis=0)
    print(f"## {title}: поправка на форму распределения (размытие ±{J:g} USD)")
    print("период | разница на данных | ожидаемая без эффекта | эффект сетки")
    for name in sorted(set(per)) + ["все"]:
        w = (np.ones(nw, bool) if name == "все" else per == name)[win].astype(float)
        obs, nul = diff(H0, w), diff(Hn, w)
        print(f"{name} | {obs * 100:+.1f} п.п. | {nul * 100:+.1f} п.п. | {(obs - nul) * 100:+.1f} п.п.")
    ex = []
    for _ in range(draws):
        w = np.bincount(rng.integers(0, nw, nw), minlength=nw)[win].astype(float)
        ex.append(diff(H0, w) - diff(Hn, w))
    ex = np.array(ex)
    lo, hi = np.percentile(ex, [2.5, 97.5])
    print(f"эффект сетки {ex.mean() * 100:+.1f} п.п., 95 % [{lo * 100:+.1f}; {hi * 100:+.1f}], "
          f"p = {np.mean(ex <= 0):.3f}\n")
    return ex.mean(), lo, hi


# ── A и B: попадание разворотов в зоны ───────────────────────────────

def test_A(W, kind, dmax):
    rows = {}
    for lab, s, c in variants(kind):
        r = []
        for w in W:
            if w["dnext"] > dmax:
                continue
            lo, hi = grid(kind, w["P"], s, c)
            r.append((w["per"], int(in_bands([w["dnext"]], lo, hi)[0]), 1))
        rows[lab] = r
    title = f"A · {kind}: конец отката (следующая точка зигзага, d ≤ {dmax:g}) в зоне"
    res = table(rows, title)
    excess([(w, np.array([w["dnext"]])) for w in W if w["dnext"] <= dmax], kind, title)
    return res


def minor_points(M5, atrH1_on_m5):
    th = 0.5 * atrH1_on_m5
    return zigzag(M5.index.to_numpy(), M5["high"].to_numpy(), M5["low"].to_numpy(), th,
                  np.timedelta64(5, "m"))


def test_B(W, kind, mp, dmax):
    mt = np.array([p[2] for p in mp]); mpr = np.array([p[1] for p in mp])
    # расстояния мелких точек от E для каждого окна (точка образовалась внутри окна)
    pts = []
    for w in W:
        i0, i1 = np.searchsorted(mt, w["a"]), np.searchsorted(mt, w["b"])
        d = (mpr[i0:i1] - w["E"]) * w["sgn"]
        d = d[(d > 0) & (d <= dmax)]
        if len(d):
            pts.append((w, d))
    rows = {}
    for lab, s, c in variants(kind):
        r = []
        for w, d in pts:
            lo, hi = grid(kind, w["P"], s, c)
            r.append((w["per"], int(in_bands(d, lo, hi).sum()), len(d)))
        rows[lab] = r
    title = f"B · {kind}: мелкие развороты M5 (порог 0.5 ATR H1) внутри отката, d ≤ {dmax:g}"
    res = table(rows, title)
    excess(pts, kind, title)
    return res


# ── C: гонка при первом касании зоны ─────────────────────────────────

def test_C(W, kind, M5, r, K=288):
    t5 = M5.index.to_numpy()
    H, L, C = M5["high"].to_numpy(), M5["low"].to_numpy(), M5["close"].to_numpy()
    n = len(t5)
    prep = []
    for w in W:
        a, b = np.searchsorted(t5, w["a"]), np.searchsorted(t5, w["b"])
        if b <= a or a == 0:
            continue
        e = min(b + K, n)
        if w["sgn"] == 1:
            dmx, dmn = H[a:e] - w["E"], L[a:e] - w["E"]
        else:
            dmx, dmn = w["E"] - L[a:e], w["E"] - H[a:e]
        d0 = (C[a - 1] - w["E"]) * w["sgn"]
        prep.append((w, b - a, dmx, dmn, d0))
    near = {}; far = {}
    for lab, s, c in variants(kind):
        rn, rf = [], []
        for w, m, dmx, dmn, d0 in prep:
            acc = {"n": [0, 0], "f": [0, 0]}
            lo, hi = grid(kind, w["P"], s, c)
            for zl, zh in zip(lo, hi):
                if d0 < zl:              # подход со стороны E: откат дошёл до зоны
                    tt = np.flatnonzero(dmx[:m] >= zl)
                    if not len(tt):
                        continue
                    t = tt[0]
                    cont = np.flatnonzero(dmx[t:t + K] >= zh + r)
                    back = np.flatnonzero(dmn[t + 1:t + K] <= zl - r)
                    tgt = acc["n"]
                elif d0 > zh:            # подход с дальней стороны: возврат к E
                    tt = np.flatnonzero(dmn[:m] <= zh)
                    if not len(tt):
                        continue
                    t = tt[0]
                    cont = np.flatnonzero(dmn[t:t + K] <= zl - r)
                    back = np.flatnonzero(dmx[t + 1:t + K] >= zh + r)
                    tgt = acc["f"]
                else:
                    continue
                tc = cont[0] if len(cont) else K + 1
                tb = back[0] + 1 if len(back) else K + 1
                if tc == tb or min(tc, tb) > K:
                    continue
                tgt[0] += int(tb < tc); tgt[1] += 1
            rn.append((w["per"], *acc["n"])); rf.append((w["per"], *acc["f"]))
        near[lab], far[lab] = rn, rf
    return (table(near, f"C · {kind}: откат дошёл до зоны — доля отскоков на {r:g} раньше пробоя на {r:g}"),
            table(far, f"C · {kind}: возврат к зоне с дальней стороны — доля отскоков на {r:g}"))


# ── D: сделки лимитками от зон ────────────────────────────────────────

def test_D(W, kind, m1, tps=(1.0, 2.0, 3.0), buffer=0.3, buf_atr=0.0, spread=0.25, hold=2880):
    """Откат дошёл до зоны (подход со стороны E, первое касание в окне) — лимитка на ближнем крае
    в сторону отскока (к E): после максимума — покупка, после минимума — продажа. Стоп — дальний
    край + buffer, тейк — X R. Исполнение по M1 (Bid): покупка входит и закрывается по тейку по
    Ask… упрощённо — спред вычитается из результата каждой сделки. Бар, задевший стоп и тейк, —
    стоп. Сделка живёт не дольше hold минут. Результат в R. Те же сделки — на сдвинутых сетках."""
    t1 = m1.index.to_numpy()
    H, L = m1["high"].to_numpy(), m1["low"].to_numpy()
    n = len(t1)
    prep = []
    for w in W:
        a, b = np.searchsorted(t1, w["a"]), np.searchsorted(t1, w["b"])
        if b <= a or a == 0:
            continue
        e = min(b + hold, n)
        if w["sgn"] == 1:      # от минимума вверх: зоны выше, отскок вниз — продажа
            dmx, dmn = H[a:e] - w["E"], L[a:e] - w["E"]
        else:                  # от максимума вниз: зоны ниже, отскок вверх — покупка
            dmx, dmn = w["E"] - L[a:e], w["E"] - H[a:e]
        d0 = (m1["close"].iat[a - 1] - w["E"]) * w["sgn"]
        prep.append((w, b - a, dmx, dmn, d0))
    labs = [(0.0, "s+0.0")] + [(sv, f"s{sv:+.1f}") for sv in SHIFTS if 2.0 <= abs(sv) <= 6.0]
    res = {tp: {} for tp in tps}
    for sv, lab in labs:
        rec = {tp: [] for tp in tps}
        for w, m, dmx, dmn, d0 in prep:
            lo, hi = grid(kind, w["P"], sv, 1.0)
            out = {tp: [0.0, 0] for tp in tps}
            for zl, zh in zip(lo, hi):
                if d0 >= zl:
                    continue
                tt = np.flatnonzero(dmx[:m] >= zl)
                if not len(tt):
                    continue
                t = tt[0]
                sd = zh - zl + buffer + buf_atr * w["atr"]   # стоп в USD
                # в «расстояниях»: стоп — dmx ≥ zl + sd, тейк X R — dmn ≤ zl − X·sd
                end = min(t + hold, len(dmx))
                stop = np.flatnonzero(dmx[t:end] >= zl + sd)
                ts = stop[0] if len(stop) else end
                for tp in tps:
                    take = np.flatnonzero(dmn[t + 1:end] <= zl - tp * sd)
                    tk = take[0] + 1 if len(take) else end
                    if ts <= tk and ts < end - t:
                        r = -1.0
                    elif tk < end - t:
                        r = tp
                    else:                                  # срок вышел — по закрытию
                        r = (zl - dmn[end - 1]) / sd
                    out[tp][0] += r - spread / sd; out[tp][1] += 1
            for tp in tps:
                rec[tp].append((w["per"], *out[tp]))
        for tp in tps:
            res[tp][lab] = rec[tp]
    for tp in tps:
        rows = res[tp]
        pers = sorted({x[0] for x in rows["s+0.0"]})
        bl = f"{buffer:g}" + (f" + {buf_atr:g} ATR" if buf_atr else "")
        print(f"## D · {kind}: лимитка от зоны, стоп за зоной + {bl}, тейк {tp:g}R — средний R "
              f"(сделок)")
        print("сетка | " + " | ".join(pers) + " | все")
        labs_ = list(rows)
        per = np.array([x[0] for x in rows["s+0.0"]])
        S = np.array([[x[1] for x in rows[l]] for l in labs_]); N = np.array([[x[2] for x in rows[l]] for l in labs_])
        for i, lab in enumerate(labs_):
            cells = " | ".join(f"{S[i, per == p].sum() / max(N[i, per == p].sum(), 1):+.3f} "
                               f"({N[i, per == p].sum()})" for p in pers)
            print(f"{lab} | {cells} | {S[i].sum() / N[i].sum():+.3f}" + ("  ← настоящая" if i == 0 else ""))
        rng = np.random.default_rng(3)
        def dd(idx):
            r = S[:, idx].sum(axis=1) / np.maximum(N[:, idx].sum(axis=1), 1)
            return r[0] - r[1:].mean()
        bs = np.array([dd(rng.integers(0, S.shape[1], S.shape[1])) for _ in range(2000)])
        lo_, hi_ = np.percentile(bs, [2.5, 97.5])
        print(f"настоящая − контроль: {dd(np.arange(S.shape[1])):+.3f} R, 95 % [{lo_:+.3f}; {hi_:+.3f}], "
              f"p = {np.mean(bs <= 0):.3f}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--k", type=float, default=2.0, help="порог зигзага H1, в ATR(14)")
    ap.add_argument("--r", type=float, nargs="+", default=[2.0, 4.0])
    ap.add_argument("--grids", nargs="+", default=["gann", "num"])
    ap.add_argument("--buf-atr", type=float, default=0.0, help="D: доп. отступ стопа, доли ATR(H1)")
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("what", choices=["A", "B", "C", "D", "all"])
    args = ap.parse_args()

    m1 = load(args.bars)
    H1 = resample(m1, "60min")
    W = windows(H1, args.k, args.holdout)
    P2 = sum(w["P"] > 1 for w in W)
    print(f"# Сетки от экстремумов ATR-зигзага H1, k = {args.k:g}: окон {len(W)}, из них P > 1 — {P2}")
    by = {}
    for w in W:
        by.setdefault(w["per"], []).append(w["dnext"])
    print("откат (d следующей точки), медиана по периодам: " +
          ", ".join(f"{p} {np.median(v):.1f} ({len(v)})" for p, v in sorted(by.items())) + "\n")

    if args.what in ("A", "all"):
        for g in args.grids:
            test_A(W, g, 151.0 if g == "gann" else 195.0)
    if args.what in ("B", "C", "all"):
        M5 = resample(m1, "5min")
    if args.what in ("B", "all"):
        a = pd.Series(atr_sma(H1), index=H1.index + pd.Timedelta(hours=1))
        a5 = a.reindex(M5.index, method="ffill").to_numpy()
        mp = minor_points(M5, a5)
        for g in args.grids:
            test_B(W, g, mp, 151.0 if g == "gann" else 195.0)
    if args.what in ("C", "all"):
        for g in args.grids:
            for r in args.r:
                test_C(W, g, M5, r)
    if args.what in ("D", "all"):
        for g in args.grids:
            test_D(W, g, m1, buf_atr=args.buf_atr)


if __name__ == "__main__":
    main()
