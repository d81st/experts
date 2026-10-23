"""Ордер-блок + незаполненный FVG сразу после него: где цена разворачивается при возврате.

Бычий случай (медвежий — зеркально), H1:
  * ордер-блок — медвежья свеча k (закрытие < открытия);
  * сразу после неё импульс оставил бычий FVG: low[j] > high[j−2], первая свеча разрыва j−2 = k
    или k+1. Зона FVG — [high[j−2], low[j]];
  * возврат — первое касание верхнего края FVG не раньше чем через minage баров после j, пока
    FVG не заполнен насквозь до касания;
  * отскок — цена от момента касания поднялась на 1 ATR(14) выше верхнего края FVG; до этого
    записываем самую глубокую точку отката (в ATR относительно минимума ордер-блока L).
Корзины глубины: «в FVG» (не ниже низа FVG), «в ордер-блоке» (между низом FVG и L), «снятие за L»
до 0.3 / 0.3–0.6 ATR, «пробой» — ниже L на 0.6+ ATR или отскока нет за 100 баров.
Контроль: FVG без медвежьей свечи перед импульсом и медвежья свеча без FVG после неё (зона —
та же свеча, «верхний край» — её максимум).
"""
import argparse
import sys

import numpy as np
import pandas as pd


def load(path, rule):
    d = pd.read_csv(path)
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    d = d[d["time"] >= "2023-12-01"].set_index("time")
    r = d.resample(rule, label="left", closed="left")
    return pd.DataFrame({"open": r["open"].first(), "high": r["high"].max(), "low": r["low"].min(),
                         "close": r["close"].last()}).dropna()


def outcome(h, l, start, top, L, a, horizon=100):
    """Глубина отката (в ATR от L, > 0 — ниже L) до отскока на 1 ATR над top; None — отскока нет."""
    tgt = top + a
    lo = np.inf
    for i in range(start, min(start + horizon, len(h))):
        lo = min(lo, l[i])
        if h[i] >= tgt:
            return (L - lo) / a
    return None


def bucket(x, fvg_bot_depth):
    if x is None:
        return "пробой/нет отскока"
    if x <= fvg_bot_depth:
        return "в FVG"
    if x <= 0:
        return "в ордер-блоке"
    if x <= 0.3:
        return "снятие за L до 0.3 ATR"
    if x <= 0.6:
        return "снятие за L 0.3–0.6 ATR"
    return "пробой/нет отскока"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--tf", default="60min")
    ap.add_argument("--minage", type=int, default=3)
    args = ap.parse_args()
    tf = load(args.bars, args.tf)
    tf = tf[tf.index >= "2023-12-01"]
    o, h, l, c = (tf[k].to_numpy() for k in ("open", "high", "low", "close"))
    t = tf.index
    pc = np.roll(c, 1); pc[0] = c[0]
    atr = pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().to_numpy()
    res = {"ордер-блок + FVG": [], "FVG без ордер-блока": [], "ордер-блок без FVG": []}
    n = len(c)
    for side in (1, -1):
        # side 1 — бычий; для медвежьего зеркалим цены
        H, Lw, O, C = (h, l, o, c) if side == 1 else (-l, -h, -o, -c)
        for k in range(15, n - 5):
            if t[k] < pd.Timestamp("2024-01-01"):
                continue
            a = atr[k]
            if not np.isfinite(a) or a <= 0:
                continue
            bear = C[k] < O[k]
            fv = None
            for j in (k + 2, k + 3):
                if j < n and Lw[j] > H[j - 2] and Lw[j] - H[j - 2] >= 0.1 * a:
                    fv = (j, H[j - 2], Lw[j])
                    break
            if fv is not None:
                j, fb, ft = fv
                # FVG без ордер-блока: перед импульсом нет медвежьей свечи (k и k−1 бычьи)
                kind = "ордер-блок + FVG" if bear else ("FVG без ордер-блока" if C[k - 1] >= O[k - 1] else None)
                if kind is None:
                    continue
                L = Lw[k] if bear else Lw[j - 2]
                # возврат: первое касание верха FVG после minage, FVG не пройден насквозь раньше
                seg = Lw[j + args.minage:]
                hit = np.flatnonzero(seg <= ft)
                if not len(hit):
                    continue
                i = j + args.minage + hit[0]
                if Lw[j + 1:i].min(initial=np.inf) < fb:
                    continue
                x = outcome(H, Lw, i, ft, L, a)
                res[kind].append(bucket(x, (L - fb) / a))
            elif bear:
                # ордер-блок без FVG: медвежья свеча, после неё рост на 1 ATR за 3 бара, но разрыва нет
                if H[k + 1:k + 4].max() - H[k] < a:
                    continue
                seg = Lw[k + 4 + args.minage:]
                hit = np.flatnonzero(seg <= H[k])
                if not len(hit):
                    continue
                i = k + 4 + args.minage + hit[0]
                x = outcome(H, Lw, i, H[k], Lw[k], a)
                res["ордер-блок без FVG"].append(bucket(x, (Lw[k] - O[k]) / a))
    order = ["в FVG", "в ордер-блоке", "снятие за L до 0.3 ATR", "снятие за L 0.3–0.6 ATR", "пробой/нет отскока"]
    print(f"# {args.tf}: где разворот при первом возврате в зону (2024 – 2026-10), доли")
    print("зона | n | " + " | ".join(order))
    for k, v in res.items():
        s = pd.Series(v).value_counts(normalize=True)
        print(f"{k} | {len(v)} | " + " | ".join(f"{s.get(b, 0):.2f}" for b in order))


if __name__ == "__main__":
    main()
