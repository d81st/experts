"""Разворот после новостного рывка (курс «Bozorni zabt etish», урок 6): «сначала рывок, чтобы
заманить толпу, потом настоящий ход в обратную сторону».

Даты — из Include/Context/NewsTimes.mqh (NFP, CPI, FOMC, ISM; серверное время UTC+0).
Для каждой новости в момент T (минутные бары):
  * рывок — движение за первые K минут: от открытия минуты T до закрытия минуты T+K−1;
    направление d0 — его знак, размер — в USD;
  * «против рывка» — результат сделки против d0 с закрытия T+K−1 до закрытия T+K−1+H минут, USD
    (минус спред 0.25);
  * «полный разворот» — цена через H минут по другую сторону от открытия T.
Контроль — те же минуты в обычные дни (будни без этих новостей, то же время суток): если
«против рывка» в дни новостей не лучше, чем в обычные, особой «манипуляции» нет.

Использование:
    python3 tester/tools/news_fade.py --bars bars_XAUUSDm_M1.csv
"""
import argparse
import os
import re

import numpy as np
import pandas as pd

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")


def news_times():
    src = open(os.path.join(ROOT, "Include/Context/NewsTimes.mqh"), encoding="utf-8", errors="ignore").read()
    out = {}
    for name in ("NFP", "CPI", "FOMC", "ISM"):
        m = re.search(r"#define NEWS_%s_DEFAULT((?:\s*\"[^\"]*\"\s*\\?)+)" % name, src)
        txt = "".join(re.findall(r"\"([^\"]*)\"", m.group(1)))
        out[name] = [pd.Timestamp(x.strip().replace(".", "-")) for x in txt.split(";") if x.strip()]
    return out


def measure(df, T, K, H):
    """(рывок USD со знаком, результат «против рывка» USD, полный разворот 0/1) или None."""
    try:
        i = df.index.get_loc(T)
    except KeyError:
        return None
    if i + K + H >= len(df):
        return None
    t = df.index
    if t[i + K + H] - T > pd.Timedelta(minutes=K + H + 10):     # дыра в данных
        return None
    o0 = df["open"].iat[i]
    cK = df["close"].iat[i + K - 1]
    move = cK - o0
    if move == 0:
        return None
    d0 = np.sign(move)
    cH = df["close"].iat[i + K - 1 + H]
    fade = -d0 * (cH - cK) - 0.25
    rev = int(np.sign(cH - o0) == -d0)
    return move, fade, rev


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    args = ap.parse_args()
    d = pd.read_csv(args.bars)
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    df = d.set_index("time")[["open", "high", "low", "close"]]
    df = df[df.index >= "2024-01-01"]
    nt = news_times()
    allnews = {T.normalize() for v in nt.values() for T in v}
    for K in (5, 15):
        for H in (30, 60, 120, 240):
            print(f"## рывок {K} мин, затем держим {H} мин против рывка")
            print("событие | n | средний рывок, USD | «против рывка», USD | доля > 0 | полный разворот | "
                  "обычные дни: «против», USD / полный разворот")
            for name, times in nt.items():
                res = [measure(df, T, K, H) for T in times]
                res = [r for r in res if r is not None]
                if not res:
                    continue
                mv = np.array([abs(r[0]) for r in res]); fd = np.array([r[1] for r in res])
                rv = np.array([r[2] for r in res])
                # контроль: то же время суток в будни без новостей
                hm = {(T.hour, T.minute) for T in times}
                ctrl = []
                for day in pd.bdate_range("2024-01-02", "2026-10-14"):
                    if day.normalize() in allnews:
                        continue
                    for hh, mm in hm:
                        r = measure(df, day + pd.Timedelta(hours=hh, minutes=mm), K, H)
                        if r is not None:
                            ctrl.append(r)
                cf = np.array([r[1] for r in ctrl]); cr = np.array([r[2] for r in ctrl])
                se = fd.std(ddof=1) / np.sqrt(len(fd))
                print(f"{name} | {len(res)} | {mv.mean():.2f} | {fd.mean():+.2f} (±{se:.2f}) | "
                      f"{(fd > 0).mean():.2f} | {rv.mean():.2f} | {cf.mean():+.2f} / {cr.mean():.2f} ({len(ctrl)})")
            print()


if __name__ == "__main__":
    main()
