"""Быстрый симулятор hybrid-trend-channel по часовым барам (сверен с тестером на 2025–2026).

Использование:
    python3 tester/tools/trend_sim.py --bars bars_XAUUSDm_H1.csv --from 2025.01.02 --to 2026.09.30 \
        [--entry 20 --exit 10 --stop 3] [--grid] [--years]

Правила как в боте: закрытие бара H4 за максимумом/минимумом entry баров — вход по закрытию;
стоп stop × ATR(20) H4 (проверка внутри бара по часовым барам); выход — закрытие H4 за
противоположной границей канала exit баров; одна позиция; лот от риска 1% от 10 000 USD; своп покупок как у брокера
(-53.7 USD за лот за ночь, тройной в среду); вход пропускается, если
риск 0.01 лота > 150 USD (1.5% от 10 000 USD, как MaxRiskOvershoot в тесте).
--grid: сетка entry × exit × stop (шаг ×1.5, Kaufman) — доля прибыльных, среднее, среднее − 1σ.
--years: итог по годам для выбранных настроек.
"""
import argparse
import math
import datetime as dt
import statistics
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import monkey as m  # noqa: E402

CONTRACT = 100.0
RISK_USD = 100.0   # 1% от 10 000 USD, без сложного процента


def prepare(path):
    t, o, h, l, c, sp = m.load(path)
    b4 = m.h4_bars(t, o, h, l, c)
    tr = [0.0] + [max(b4[j][2], b4[j - 1][4]) - min(b4[j][3], b4[j - 1][4]) for j in range(1, len(b4))]
    atr = [0.0] * len(b4)
    for j in range(20, len(b4)):
        atr[j] = sum(tr[j - 19:j + 1]) / 20.0
    return t, h, l, sp, b4, atr


def simulate(data, frm, to, entry_n, exit_n, stop_mult, swap_on=True):
    t, h, l, sp, b4, atr = data
    spread = statistics.median(x for x, tt in zip(sp, t) if frm <= tt <= to and x > 0) if any(
        x > 0 for x, tt in zip(sp, t) if frm <= tt <= to) else 0.3
    trades = []
    busy = None
    start = max(entry_n, 21)
    for k in range(start, len(b4)):
        if not (frm <= b4[k][0] <= to) or (busy and b4[k][0] <= busy):
            continue
        hi = max(x[2] for x in b4[k - entry_n:k])
        lo = min(x[3] for x in b4[k - entry_n:k])
        cl = b4[k][4]
        d = 1 if cl > hi else (-1 if cl < lo else 0)
        risk01 = stop_mult * atr[k] * 0.01 * CONTRACT          # риск 0.01 лота, USD
        if not d or risk01 > 1.5 * RISK_USD:
            continue
        lot = max(0.01, math.floor(RISK_USD / risk01 + 1e-9) * 0.01)  # лот от риска 1%, вниз до шага 0.01
        when, move = m.trend_trade(b4, atr, k, d, spread, h, l, stop_mult, exit_n)
        swap = m.SWAP_LONG_PER_LOT * lot * m.nights(b4[k][0], when) if d == 1 and swap_on else 0.0
        trades.append((b4[k][0], when, d, move * lot * CONTRACT + swap))
        busy = when
    return trades


def pf(ps):
    gp = sum(p for p in ps if p > 0)
    gl = -sum(p for p in ps if p < 0)
    return gp / gl if gl > 0 else float("inf")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--from", dest="frm", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--entry", type=int, default=20)
    ap.add_argument("--exit", type=int, default=10)
    ap.add_argument("--stop", type=float, default=3.0)
    ap.add_argument("--grid", action="store_true")
    ap.add_argument("--years", action="store_true")
    a = ap.parse_args()
    frm = dt.datetime.strptime(a.frm, "%Y.%m.%d")
    to = dt.datetime.strptime(a.to, "%Y.%m.%d")
    data = prepare(a.bars)

    if a.years or not a.grid:
        tr = simulate(data, frm, to, a.entry, a.exit, a.stop)
        ps = [x[3] for x in tr]
        print(f"entry {a.entry} / exit {a.exit} / стоп {a.stop} ATR: сделок {len(ps)}, PF {pf(ps):.2f}, "
              f"итог {sum(ps):.0f} USD (риск 1% от 10 000 USD)")
        print("\n| Год | Сделок | PF | Итог | Покупки | Продажи |\n|---|---|---|---|---|---|")
        for y in sorted({x[1].year for x in tr}):
            yy = [x for x in tr if x[1].year == y]
            p = [x[3] for x in yy]
            print(f"| {y} | {len(p)} | {pf(p):.2f} | {sum(p):.0f} | {sum(x[3] for x in yy if x[2] == 1):.0f} | "
                  f"{sum(x[3] for x in yy if x[2] == -1):.0f} |")

    if a.grid:
        entries = [10, 15, 20, 30, 45]
        exits = [5, 7, 10, 15, 22]
        stops = [2.0, 3.0, 4.5]
        res = {}
        for e in entries:
            for x in exits:
                if x >= e:
                    continue
                for s in stops:
                    ps = [q[3] for q in simulate(data, frm, to, e, x, s)]
                    res[(e, x, s)] = (sum(ps), pf(ps), len(ps))
        nets = [v[0] for v in res.values()]
        prof = sum(1 for v in nets if v > 0)
        mu, sd = statistics.mean(nets), statistics.pstdev(nets)
        print(f"\nСетка {len(res)} настроек: прибыльных {prof} ({prof / len(res):.0%}), среднее {mu:.0f}, "
              f"среднее − 1σ {mu - sd:.0f}, медиана {statistics.median(nets):.0f} USD")
        for s in stops:
            print(f"\nСтоп {s} ATR — итог USD (PF), строки entry, столбцы exit:\n")
            print("| entry \\ exit | " + " | ".join(str(x) for x in exits) + " |")
            print("|---|" + "---|" * len(exits))
            for e in entries:
                cells = []
                for x in exits:
                    v = res.get((e, x, s))
                    cells.append("—" if v is None else f"{v[0]:.0f} ({v[1]:.2f})")
                print(f"| {e} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
