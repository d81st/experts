"""Откат по тренду против вечернего лонга. Данные строго до 2026-10-16.

Правило заморожено до просмотра цифр:
  * ТФ H1 и H4, радиус точки разворота k = 5 (известна только через 5 баров);
  * тренд: EMA50 по нужную сторону EMA200, и EMA200 сдвинулась в ту же сторону;
  * два последних подтверждённых экстремума идут по тренду;
  * откат: экстремум позапрошлого бара коснулся EMA50;
  * вход: закрытие прошлого бара за экстремумом позапрошлого, рынок на открытии следующего;
  * стоп 2 × ATR(14); выходы только tp5, time12h, time24h. Фильтр D1 не включается.
  * контроль: покупка на 9 часов вечером пн–чт (18:00–03:00 Нью-Йорк). Летом вход
    сдвигается на 22:15 UTC, чтобы не брать перерыв 20:58–22:01.

Подбор — 2024, 2025, январь–май 2026. Июнь–15 октября 2026 печатается как уже
смотревшееся сравнение и в отбор не входит. Бар с меткой 2026-10-16 и позже
скрипт не читает.

    python3 tester/tools/pullback_screen.py --bars bars_XAUUSDm_M1.csv
"""
import argparse
import os
import sys
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402
import fvg_sim as FS  # noqa: E402
import screen as S  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")
NY = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")
K_PIVOT = 5
EXITS = ("tp5", "time12h", "time24h")


def load_bars(path):
    times = pd.read_csv(path, usecols=["time"])
    parsed = pd.to_datetime(times["time"], format="%Y.%m.%d %H:%M")
    if (parsed >= "2026-10-16").any():
        raise SystemExit("файл захватывает холдаут с 2026-10-16, цены не читаю")
    frame = FS.Path(path, start="2023-01-01")
    if frame.t.max() >= CUTOFF:
        raise SystemExit("после загрузки остался бар холдаута")
    return frame


def pivots(values, k, kind):
    """Цена точки, известная на баре подтверждения. kind: low или high."""
    n = len(values)
    known = np.full(n, np.nan)
    for center in range(k, n - k):
        window = values[center - k:center + k + 1]
        left = values[center - k:center]
        if kind == "low" and values[center] == window.min() and values[center] < left.min():
            known[center + k] = values[center]
        if kind == "high" and values[center] == window.max() and values[center] > left.max():
            known[center + k] = values[center]
    return known


def pullback_signals(frame, k=K_PIVOT):
    close, high, low = frame.c, frame.h, frame.l
    ema50 = pd.Series(close).ewm(span=50, adjust=False).mean().to_numpy()
    ema200 = pd.Series(close).ewm(span=200, adjust=False).mean().to_numpy()
    lows, highs = pivots(low, k, "low"), pivots(high, k, "high")
    seen_low, seen_high, signals = [], [], []
    for j in range(200, frame.n - 1):
        if np.isfinite(lows[j]):
            seen_low.append(lows[j])
        if np.isfinite(highs[j]):
            seen_high.append(highs[j])
        rising = len(seen_low) >= 2 and seen_low[-1] > seen_low[-2]
        falling = len(seen_high) >= 2 and seen_high[-1] < seen_high[-2]
        if (ema50[j] > ema200[j] and ema200[j] > ema200[j - 1] and rising
                and low[j - 1] <= ema50[j - 1] and close[j] > high[j - 1]):
            signals.append((j + 1, 1))
        elif (ema50[j] < ema200[j] and ema200[j] < ema200[j - 1] and falling
              and high[j - 1] >= ema50[j - 1] and close[j] < low[j - 1]):
            signals.append((j + 1, -1))
    return signals


def evening_minutes(path):
    """Минуты входа: 18:00 Нью-Йорка, пн–чт. Летом — 22:15 UTC, зимой — 23:00 UTC."""
    index = pd.DatetimeIndex(path.t)
    out = []
    for day in pd.date_range("2024-01-01", "2026-10-15", freq="D"):
        if day.day_of_week > 3:
            continue
        slot = pd.Timestamp(day).tz_localize(UTC).tz_convert(NY).replace(hour=18, minute=0)
        utc = slot.tz_convert(UTC).tz_localize(None)
        if utc.hour == 22:
            utc = utc.normalize() + pd.Timedelta(hours=22, minutes=15)
        stamp = np.datetime64(utc.to_datetime64())
        if stamp >= CUTOFF:
            continue
        pos = int(np.searchsorted(path.t, stamp))
        if pos >= path.n or path.t[pos] >= stamp + np.timedelta64(2, "m"):
            continue
        out.append(pos)
    return out


def usd_ounce(path, minute, direction, exit_minute):
    entry = path.o[minute] + (C.SPREAD if direction == 1 else 0.0)
    price = path.c[exit_minute] + (C.SPREAD if direction == -1 else 0.0)
    move = direction * (price - entry)
    if direction == 1:
        move -= (path.nights[exit_minute] - path.nights[minute]) * FS.SWAP_LONG
    return float(move), float(move / entry * 10000.0)


def evening_table(path):
    rows = []
    for minute in evening_minutes(path):
        end = int(np.searchsorted(path.t, path.t[minute] + np.timedelta64(9, "h"))) - 1
        end = max(minute, min(end, path.n - 1))
        if path.t[end] >= CUTOFF:
            continue
        usd, bps = usd_ounce(path, minute, 1, end)
        rows.append((minute, end, usd, bps, int(path.period[minute])))
    return rows


def period_means(rows, key):
    text = []
    for k, (lab, _, _) in enumerate(FS.PERIODS + [FS.HOLDOUT]):
        got = [row[key] for row in rows if row[4] == k]
        if not got:
            text.append(f"{lab} n=0")
        else:
            text.append(f"{lab} {np.mean(got):+.2f}({len(got)})")
    return " ".join(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bars", required=True)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    path = load_bars(args.bars)
    df = path.df
    ctx = {"st": np.zeros(path.n), "ema": np.zeros(path.n), "er": np.full(path.n, np.nan),
           "news": np.zeros(path.n, bool)}
    monkey = C.Monkey(path, np.random.default_rng(args.seed))
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    results, scores = [], []
    for tf, rule in (("H1", "60min"), ("H4", "240min")):
        frame = S.Frame(S.resample(m1, rule), tf)
        signals = pullback_signals(frame)
        name = f"pb-{tf}"
        entries = C.market_entries(path, frame, signals, mult=2.0)
        print(f"# {name}: сигналов {len(signals)}, входов {len(entries)}", flush=True)
        for exit_name in EXITS:
            label = f"{name}|off|all|off|off|{exit_name}"
            table = C.outcomes_for(path, entries, exit_name, name)
            result, score = C.evaluate(path, ctx, monkey, table, label, holdout=True)
            results.append(result)
            if score is not None:
                scores.append(score)
            minutes = table[:, 0].astype(int)
            exits_at = table[:, 4].astype(int)
            periods = path.period[minutes]
            chosen = C.one_position(minutes, exits_at, periods >= 0)
            longs = []
            for row in table[chosen]:
                if row[1] != 1:
                    continue
                minute, exit_minute = int(row[0]), int(row[4])
                usd, bps = usd_ounce(path, minute, 1, exit_minute)
                longs.append((minute, exit_minute, usd, bps, int(path.period[minute])))
            result["long_bps"] = period_means(longs, 3)
    if not scores:
        raise SystemExit("нет сделок отката")
    zmax = np.nanmax(np.vstack(scores), axis=0)
    print(f"максимум z по {len(scores)} выходам: медиана {np.median(zmax):.2f}, "
          f"90% {np.quantile(zmax, 0.9):.2f}")
    for result in results:
        if "z" in result and np.isfinite(result["z"]):
            result["p_max"] = float((zmax >= result["z"]).mean())
        mark = "ПРОШЛО" if C.passed(result) else "нет"
        print(C.line(result, holdout=True) + f"  {mark}")
        print(f"    покупки, б.п. после спреда и свопа: {result['long_bps']}")
    evenings = evening_table(path)
    print("# вечерний лонг 9 ч, без стопа, б.п.: " + period_means(evenings, 3))
    print("# вечерний лонг 9 ч, USD/унция: " + period_means(evenings, 2))


if __name__ == "__main__":
    main()
