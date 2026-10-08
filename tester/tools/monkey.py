"""«Обезьяний» тест Davey: случайный вход + выход по правилам самой стратегии.

Использование:
    python3 tester/tools/monkey.py trend --bars bars_XAUUSDm_H1.csv --from 2025.01.02 --to 2026.10.05 \
        --trades 69 --long 0.59 --actual 1398 --actual-dd 0.077 [--runs 2000] [--trials 250]
    python3 tester/tools/monkey.py asia  --bars bars_XAUUSDm_M5.csv ...

trend: случайный бар H4 (из часовых баров), направление случайно с долей покупок стратегии,
       стоп 3 × ATR(20) H4, выход — закрытие H4 за противоположной границей канала 10 баров
       (как hybrid-trend-channel), лот 0.01.
asia:  случайный день и случайный бар в 07:00–11:00, коробка 00:00–07:00, стоп за серединой
       коробки + 0.2 USD (не меньше 1 USD), тейк 2R, закрытие в 20:00, риск 1% от 10 000 USD
       (как hybrid-asia-breakout v1.1, вариант close15-mid-rr2).
Сравнение: доля случайных прогонов не хуже стратегии по итогу и по просадке; Davey требует,
чтобы стратегия была лучше ~90% случайных по обоим.
"""
import argparse
import bisect
import csv
import datetime as dt
import random
import statistics

CONTRACT = 100.0


def load(path):
    t, o, h, l, c, sp = [], [], [], [], [], []
    with open(path) as f:
        r = csv.reader(f)
        head = next(r)
        point = float(head[-1].split("=")[1])
        for row in r:
            t.append(dt.datetime.strptime(row[0], "%Y.%m.%d %H:%M"))
            o.append(float(row[1])); h.append(float(row[2])); l.append(float(row[3])); c.append(float(row[4]))
            sp.append(int(row[6]) * point)
    return t, o, h, l, c, sp


def max_dd(pnl, start=10000.0):
    eq = peak = start
    dd = 0.0
    for p in pnl:
        eq += p
        peak = max(peak, eq)
        dd = max(dd, (peak - eq) / peak)
    return dd


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))]


# ── Trend: H4 из H1 ───────────────────────────────────────────────────

def h4_bars(t, o, h, l, c):
    out = []  # (time, o, h, l, c, first_h1_index, last_h1_index)
    cur = None
    for i in range(len(t)):
        key = (t[i].date(), t[i].hour // 4)
        if cur is None or cur[0] != key:
            if cur:
                out.append(cur[1])
            cur = (key, [t[i].replace(hour=key[1] * 4, minute=0), o[i], h[i], l[i], c[i], i, i])
        else:
            b = cur[1]
            b[2] = max(b[2], h[i]); b[3] = min(b[3], l[i]); b[4] = c[i]; b[6] = i
    if cur:
        out.append(cur[1])
    return out


SWAP_LONG_PER_LOT = -53.7   # USD за лот за ночь у покупок XAUUSDm (по сделкам тестера 2025–2026); у продаж 0


def nights(t0, t1):
    """Ночёвки между t0 и t1; перенос со среды на четверг — тройной (как у брокера)."""
    n, x = 0, t0
    while x.date() < t1.date():
        x += dt.timedelta(days=1)
        n += 3 if x.weekday() == 3 else (0 if x.weekday() >= 5 else 1)
    return n


def trend_trade(b4, atr, k, d, spread, h, l, stop_mult=3.0, exit_n=10):
    entry = b4[k][4] + (spread if d == 1 else 0.0)
    sl = entry - d * stop_mult * atr[k]
    for j in range(k + 1, len(b4)):
        # стоп внутри бара — по часовым барам
        for i in range(b4[j][5], b4[j][6] + 1):
            if (d == 1 and l[i] <= sl) or (d == -1 and h[i] + spread >= sl):
                return (b4[j][0], d * (sl - entry))
        lo = min(x[3] for x in b4[max(0, j - exit_n):j])
        hi = max(x[2] for x in b4[max(0, j - exit_n):j])
        cl = b4[j][4]
        if (d == 1 and cl < lo) or (d == -1 and cl > hi):
            ex = cl if d == 1 else cl + spread
            return (b4[j][0], d * (ex - entry))
    return (b4[-1][0], d * (b4[-1][4] - entry))


def run_trend(a, data, rnd):
    t, o, h, l, c, sp = data
    b4 = h4_bars(t, o, h, l, c)
    tr = [0.0]
    for j in range(1, len(b4)):
        tr.append(max(b4[j][2], b4[j - 1][4]) - min(b4[j][3], b4[j - 1][4]))
    atr = [0.0] * len(b4)
    for j in range(20, len(b4)):
        atr[j] = sum(tr[j - 19:j + 1]) / 20.0
    # Как в тестере: при риске мин. лота > 1.5% от 10 000 USD (стоп 3 ATR × 0.01 лота > 150 USD) вход пропускается.
    cand = [j for j in range(30, len(b4)) if a.frm <= b4[j][0] <= a.to and 0 < 3.0 * atr[j] * 0.01 * CONTRACT <= 150.0]
    spread = statistics.median(x for x, tt in zip(sp, t) if a.frm <= tt <= a.to)
    res = []
    for _ in range(a.runs):
        pnl = []
        for _ in range(a.trades):
            k = rnd.choice(cand)
            d = 1 if rnd.random() < a.long else -1
            when, move = trend_trade(b4, atr, k, d, spread, h, l)
            swap = SWAP_LONG_PER_LOT * 0.01 * nights(b4[k][0], when) if d == 1 else 0.0
            pnl.append((when, move * 0.01 * CONTRACT + swap))
        pnl.sort()
        ps = [x[1] for x in pnl]
        res.append((sum(ps), max_dd(ps)))
    return res


# ── Asia: коробка 00–07, вход 07–11, стоп за серединой, 2R, выход 20:00 ─

def run_asia(a, data, rnd):
    t, o, h, l, c, sp = data
    days = {}
    for i, tt in enumerate(t):
        days.setdefault(tt.date(), []).append(i)
    plans = []
    for d, idx in days.items():
        if not (a.frm.date() <= d <= a.to.date()):
            continue
        box = [i for i in idx if t[i].hour < 7]
        win = [i for i in idx if 7 <= t[i].hour < 11]
        rest = [i for i in idx if t[i].hour < 20]
        if len(box) < 6 or not win:
            continue
        hi = max(h[i] for i in box); lo = min(l[i] for i in box)
        if hi - lo < 3.0:
            continue
        plans.append((hi, lo, win, rest))
    spread = statistics.median(x for x, tt in zip(sp, t) if a.frm <= tt <= a.to)
    res = []
    for _ in range(a.runs):
        pnl = []
        for _ in range(a.trades):
            hi, lo, win, rest = rnd.choice(plans)
            k = rnd.choice(win)
            d = 1 if rnd.random() < a.long else -1
            entry = c[k] + (spread if d == 1 else 0.0)
            mid = (hi + lo) / 2.0
            dist = max((hi - lo) / 2.0 + 0.2, 1.0)   # как у пробоя от границы: стоп за серединой коробки
            sl = entry - d * dist
            tp = entry + d * 2.0 * dist
            lot = max(0.01, round(100.0 / (dist * CONTRACT), 2))
            out = None
            for i in rest:
                if i <= k:
                    continue
                if (d == 1 and l[i] <= sl) or (d == -1 and h[i] + spread >= sl):
                    out = (t[i], -dist); break
                if (d == 1 and h[i] >= tp) or (d == -1 and l[i] + spread <= tp):
                    out = (t[i], 2.0 * dist); break
            if out is None:
                last = rest[-1]
                ex = c[last] if d == 1 else c[last] + spread
                out = (t[last], d * (ex - entry))
            pnl.append((out[0], out[1] * lot * CONTRACT))
        pnl.sort()
        ps = [x[1] for x in pnl]
        res.append((sum(ps), max_dd(ps)))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("strategy", choices=["trend", "asia"])
    ap.add_argument("--bars", required=True)
    ap.add_argument("--from", dest="frm", required=True)
    ap.add_argument("--to", required=True)
    ap.add_argument("--trades", type=int, required=True)
    ap.add_argument("--long", type=float, required=True)
    ap.add_argument("--actual", type=float, required=True)
    ap.add_argument("--actual-dd", type=float, required=True)
    ap.add_argument("--runs", type=int, default=2000)
    ap.add_argument("--trials", type=int, default=0)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    a.frm = dt.datetime.strptime(a.frm, "%Y.%m.%d")
    a.to = dt.datetime.strptime(a.to, "%Y.%m.%d")
    rnd = random.Random(a.seed)
    data = load(a.bars)
    res = run_trend(a, data, rnd) if a.strategy == "trend" else run_asia(a, data, rnd)
    prof = [r[0] for r in res]
    dds = [r[1] for r in res]
    p_prof = sum(x >= a.actual for x in prof) / len(res)
    p_dd = sum(x <= a.actual_dd for x in dds) / len(res)
    print(f"Случайный вход + выход стратегии ({a.strategy}), {a.runs} прогонов по {a.trades} сделок, "
          f"доля покупок {a.long:.0%}\n")
    print("| | Стратегия | Случайные: медиана | 90-й процентиль | Доля случайных не хуже |")
    print("|---|---|---|---|---|")
    print(f"| Итог, USD | {a.actual:.0f} | {statistics.median(prof):.0f} | {pct(prof, 0.9):.0f} | {p_prof:.3f} |")
    print(f"| Макс. просадка | {a.actual_dd * 100:.1f}% | {statistics.median(dds) * 100:.1f}% | "
          f"{pct(dds, 0.1) * 100:.1f}% (10-й) | {p_dd:.3f} |")
    ok = p_prof <= 0.10 and p_dd <= 0.10
    print(f"\nКритерий Davey (лучше 90% случайных по итогу и по просадке): **{'пройден' if ok else 'не пройден'}**.")
    if a.trials:
        print(f"\nС поправкой на перебор {a.trials} вариантов: вероятность, что лучший из {a.trials} случайных "
              f"не хуже стратегии, — **{1.0 - (1.0 - p_prof) ** a.trials:.3f}**.")


if __name__ == "__main__":
    main()
