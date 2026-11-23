"""Стохастик терминала как фильтр готовых ботов. Данные строго до 2026-10-16.

Отдельный вход по стохастику уже отвергнут (screening.md, 48 вариантов). Здесь
другое: сигнал остаётся сигналом бота, стохастик только пропускает его.

Индикатор — тот, что ставится на график в MetaTrader 5 по умолчанию:
%K 5, %D 3, замедление 3, SMA, low/high. Два фильтра, без перебора уровней:
  * agree — покупка только если %K > %D на закрытом баре сигнала, продажа наоборот;
  * zone — покупка только если %K < 80, продажа только если %K > 20.

Боты:
  * Alchemist H1, выход 12 часов, стоп 3 ATR, фильтр структуры D1;
  * пробой Азии M15, тейк 5R, стоп за коробкой, без фильтра D1.

Фильтр принимается, только если во всех трёх периодах подбора средний R выше,
чем у того же бота без фильтра, сделок не меньше 20 и p ≤ 0.05 против случайных
входов. Июнь–15 октября 2026 в решение не входит.

    python3 tester/tools/stoch_filter.py --bars bars_XAUUSDm_M1.csv
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

CUTOFF = "2026-10-16"
MODES = ("off", "agree", "zone")


def load_checked(path):
    times = pd.read_csv(path, usecols=["time"])
    parsed = pd.to_datetime(times["time"], format="%Y.%m.%d %H:%M")
    if (parsed >= CUTOFF).any():
        raise SystemExit("файл захватывает холдаут с 2026-10-16, цены не читаю")
    return path


def stochastic(frame, k=5, d_period=3, slowing=3):
    low = pd.Series(frame.l).rolling(k).min().to_numpy()
    high = pd.Series(frame.h).rolling(k).max().to_numpy()
    span = np.where(high > low, high - low, np.nan)
    raw = 100.0 * (frame.c - low) / span
    k_line = pd.Series(raw).rolling(slowing).mean().to_numpy()
    d_line = pd.Series(k_line).rolling(d_period).mean().to_numpy()
    return k_line, d_line


def keep_signal(index, direction, k_line, d_line, mode):
    if mode == "off":
        return True
    j = index - 1
    if j < 0 or not np.isfinite(k_line[j]) or not np.isfinite(d_line[j]):
        return False
    if mode == "agree":
        return k_line[j] > d_line[j] if direction == 1 else k_line[j] < d_line[j]
    if mode == "zone":
        return k_line[j] < 80.0 if direction == 1 else k_line[j] > 20.0
    raise ValueError(mode)


def bot_signals(df):
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    h4 = S.resample(m1, "4h")
    hourly = S.Frame(S.resample(m1, "60min"), "H1")
    average = h4["close"].ewm(span=50, adjust=False).mean()
    up = (h4["close"] > average).astype(float).shift(1).reindex(hourly.t, method="ffill").to_numpy()
    down = (h4["close"] < average).astype(float).shift(1).reindex(hourly.t, method="ffill").to_numpy()
    alchemist = S.alch_signals(hourly, up, down, 200, 21, 100, cc=S.cci(hourly, 20))
    quarter = S.Frame(S.resample(m1, "15min"), "M15")
    asia = C.asia_breakout(quarter)
    return {"alch-H1": (hourly, alchemist, 3.0), "asia-brk-M15": (quarter, asia, None)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bars", required=True)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    load_checked(args.bars)
    path, df, ctx = C.prepare(args)
    if path.t.max() >= np.datetime64(CUTOFF):
        raise SystemExit("после загрузки остался бар холдаута")
    monkey = C.Monkey(path, np.random.default_rng(args.seed))
    specs = {
        "alch-H1": "alch-H1|struct|all|off|off|time12h",
        "asia-brk-M15": "asia-brk-M15|off|all|off|off|tp5",
    }
    built = bot_signals(df)
    results = []
    scores = []
    for bot, label in specs.items():
        frame, signals, mult = built[bot]
        k_line, d_line = stochastic(frame)
        print(f"# {bot}: сигналов {len(signals)}", flush=True)
        for mode in MODES:
            kept = [item for item in signals if keep_signal(item[0], item[1], k_line, d_line, mode)]
            entries = C.market_entries(path, frame, kept, mult=3.0 if mult else 3.0)
            if mult is None:
                entries = C.market_entries(path, frame, kept)
            name = label if mode == "off" else label + f"|stoch-{mode}"
            table = C.outcomes_for(path, entries, label.split("|")[-1], bot)
            result, score = C.evaluate(path, ctx, monkey, table, label, holdout=True)
            result["name"] = name
            result["mode"] = mode
            result["bot"] = bot
            results.append(result)
            if mode != "off" and score is not None:
                scores.append(score)
            print(C.line(result, holdout=True), flush=True)
    if scores:
        zmax = np.nanmax(np.vstack(scores), axis=0)
        print(f"максимум z по {len(scores)} фильтрам: медиана {np.median(zmax):.2f}")
    by_bot = {}
    for result in results:
        by_bot.setdefault(result["bot"], {})[result["mode"]] = result
    for bot, modes in by_bot.items():
        base = modes["off"]
        for mode in ("agree", "zone"):
            trial = modes[mode]
            better = all(
                trial.get(f"n_{lab}", 0) >= 20 and trial.get(f"R_{lab}", -1) > base.get(f"R_{lab}", 0)
                for lab, _, _ in FS.PERIODS
            ) and trial.get("p", 1) <= 0.05
            print(f"{bot} {mode}: выше базы во всех периодах подбора — {'да' if better else 'нет'}")


if __name__ == "__main__":
    main()
