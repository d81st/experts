"""Проверка стратегии по её сделкам (этап 1 плана из docs/reading-notes.md).

Использование:
    python3 tester/tools/validate.py --name "Trend H4" --spread 0.20 \
        [--bars bars_XAUUSDm_M5.csv] [--hours 7-11] [--trials 400] report1.htm report2.htm ...

Отчёты одного варианта за разные периоды склеиваются в один список сделок.
Проверки:
  1. Сводка: сделки, PF, матожидание, покупки / продажи.
  2. Концентрация (Pardo, Kaufman): итог по кварталам, без 1 / 3 / 5 лучших сделок.
  3. Издержки ×1.5 и ×2 (Davey): дополнительный спред на каждую сделку.
  4. Случайное направление (Aronson): то же время сделок, направление случайно с той же
     долей покупок — насколько выбор направления лучше случая.
  5. Monte Carlo (Davey, Faith): перемешивание сделок на год вперёд и блоками по 20 дней.
  6. С ценами (--bars): вычитание дрейфа цены (Aronson) и «обезьяньи» входы (Davey) —
     случайные входы с тем же числом сделок, долей покупок и временем удержания.
"""
import argparse
import bisect
import csv
import datetime as dt
import math
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trades import load_trades, CONTRACT  # noqa: E402


def pf(ps):
    gp = sum(p for p in ps if p > 0)
    gl = -sum(p for p in ps if p < 0)
    return gp / gl if gl > 0 else float("inf")


def fmt_pf(x):
    return "∞" if x == float("inf") else f"{x:.2f}"


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


# ── Цены ──────────────────────────────────────────────────────────────

class Bars:
    def __init__(self, path):
        self.t, self.c, self.sp = [], [], []
        with open(path) as f:
            r = csv.reader(f)
            head = next(r)
            self.point = float(head[-1].split("=")[1]) if "=" in head[-1] else 0.001
            for row in r:
                self.t.append(dt.datetime.strptime(row[0], "%Y.%m.%d %H:%M"))
                self.c.append(float(row[4]))
                self.sp.append(int(row[6]) * self.point)

    def price(self, when):
        i = bisect.bisect_right(self.t, when) - 1
        return self.c[max(i, 0)]

    def spread(self, a, b):
        i, j = bisect.bisect_left(self.t, a), bisect.bisect_right(self.t, b)
        xs = self.sp[i:j] or self.sp
        return statistics.median(xs)

    def drift_per_hour(self, a, b):
        hours = (b - a).total_seconds() / 3600.0
        return (self.price(b) - self.price(a)) / hours if hours > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reports", nargs="+")
    ap.add_argument("--name", default="")
    ap.add_argument("--spread", type=float, default=0.20, help="типичный спред, USD (если нет --bars)")
    ap.add_argument("--bars", help="CSV баров из tools/bar-dump.mq5")
    ap.add_argument("--hours", default="", help="окно входа случайных сделок, например 7-11 (час сервера)")
    ap.add_argument("--trials", type=int, default=0, help="сколько вариантов перебрано (поправка «лучший из K»)")
    ap.add_argument("--runs", type=int, default=5000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rnd = random.Random(a.seed)

    tr = []
    periods = []
    for p in a.reports:
        t = load_trades(p)
        if t:
            periods.append((os.path.basename(p), t[0]["open_time"], t[-1]["close_time"], t))
        tr += t
    tr.sort(key=lambda x: x["open_time"])
    n = len(tr)
    prof = [t["profit"] for t in tr]
    first, last = tr[0]["open_time"], tr[-1]["close_time"]
    years = max((last - first).days / 365.25, 0.1)
    bars = Bars(a.bars) if a.bars else None
    spread = bars.spread(first, last) if bars else a.spread

    print(f"# {a.name}\n")
    print(f"Сделок {n} за {years:.2f} года ({first:%Y.%m.%d} – {last:%Y.%m.%d}), спред {spread:.3f} USD\n")

    # 1. Сводка
    longs = [t["profit"] for t in tr if t["dir"] == 1]
    shorts = [t["profit"] for t in tr if t["dir"] == -1]
    wins = [p for p in prof if p > 0]
    losses = [p for p in prof if p < 0]
    avg_loss = -statistics.mean(losses) if losses else 0.0
    exp = statistics.mean(prof)
    print("## 1. Сводка\n")
    print("| | Значение |\n|---|---|")
    print(f"| PF | {fmt_pf(pf(prof))} |")
    print(f"| Итог, USD | {sum(prof):.0f} |")
    print(f"| Выигрышных | {len(wins) / n * 100:.0f}% |")
    print(f"| Матожидание сделки, USD | {exp:.2f} |")
    print(f"| Матожидание Тарпа (на 1 USD среднего убытка) | {exp / avg_loss if avg_loss else 0:.2f} |")
    print(f"| Покупки: сделок / PF / итог | {len(longs)} / {fmt_pf(pf(longs))} / {sum(longs):.0f} |")
    print(f"| Продажи: сделок / PF / итог | {len(shorts)} / {fmt_pf(pf(shorts))} / {sum(shorts):.0f} |")
    for name, t0, t1, t in periods:
        ps = [x["profit"] for x in t]
        print(f"| {name.split('_M1_')[0]} | {len(ps)} сделок, PF {fmt_pf(pf(ps))}, итог {sum(ps):.0f} |")
    print()

    # 2. Концентрация
    print("## 2. Концентрация прибыли\n")
    q = {}
    for t in tr:
        k = f"{t['close_time'].year} Q{(t['close_time'].month - 1) // 3 + 1}"
        q.setdefault(k, []).append(t["profit"])
    print("| Квартал | Сделок | Итог | PF |\n|---|---|---|---|")
    for k in sorted(q):
        print(f"| {k} | {len(q[k])} | {sum(q[k]):.0f} | {fmt_pf(pf(q[k]))} |")
    pos_q = sum(1 for k in q if sum(q[k]) > 0)
    print(f"\nПрибыльных кварталов: {pos_q} из {len(q)}.\n")
    srt = sorted(prof, reverse=True)
    print("| Без лучших сделок | Итог | PF |\n|---|---|---|")
    for k in (0, 1, 3, 5):
        rest = srt[k:]
        print(f"| {k} | {sum(rest):.0f} | {fmt_pf(pf(rest))} |")
    top = srt[0] / sum(prof) * 100 if sum(prof) > 0 else float("nan")
    print(f"\nЛучшая сделка — {top:.0f}% итога.\n")

    # 3. Издержки
    print("## 3. Издержки\n")
    print("| Спред | Итог | PF |\n|---|---|---|")
    for mult in (1.0, 1.5, 2.0):
        extra = [t["profit"] - (mult - 1.0) * spread * t["volume"] * CONTRACT for t in tr]
        print(f"| ×{mult:g} | {sum(extra):.0f} | {fmt_pf(pf(extra))} |")
    print()

    # 4. Случайное направление
    flip = [-t["profit"] - 2.0 * spread * t["volume"] * CONTRACT for t in tr]
    n_long = len(longs)
    actual = sum(prof)
    better = 0
    sims = []
    for _ in range(a.runs):
        idx = set(rnd.sample(range(n), n_long))
        s = sum(prof[i] if (tr[i]["dir"] == 1) == (i in idx) else flip[i] for i in range(n))
        sims.append(s)
        better += s >= actual
    p_dir = better / a.runs
    print("## 4. Случайное направление (те же моменты входа и выхода)\n")
    print(f"Итог стратегии {actual:.0f} USD; случайное направление: медиана {statistics.median(sims):.0f}, "
          f"95-й процентиль {pct(sims, 0.95):.0f}. Доля случайных не хуже стратегии: **{p_dir:.3f}**.\n")

    # 5. Monte Carlo
    print("## 5. Monte Carlo\n")
    per_year = max(1, round(n / years))
    rets = [t["ret"] for t in tr]
    dds, finals, rr = [], [], []
    for _ in range(a.runs):
        eq, peak, dd = 1.0, 1.0, 0.0
        for _ in range(per_year):
            eq *= 1.0 + rnd.choice(rets)
            peak = max(peak, eq)
            dd = max(dd, (peak - eq) / peak)
        dds.append(dd)
        finals.append(eq - 1.0)
        rr.append((eq - 1.0) / dd if dd > 0 else float("inf"))
    print(f"Сделки с возвращением, {per_year} сделок = год, {a.runs} прогонов (риск как в тесте):\n")
    print("| Показатель | Значение |\n|---|---|")
    print(f"| Медианная доходность за год | {statistics.median(finals) * 100:.1f}% |")
    print(f"| Вероятность убыточного года | {sum(f < 0 for f in finals) / a.runs * 100:.0f}% |")
    print(f"| Медианная макс. просадка | {statistics.median(dds) * 100:.1f}% |")
    print(f"| 95-й процентиль просадки | {pct(dds, 0.95) * 100:.1f}% |")
    print(f"| Медиана доходность / просадка | {statistics.median(rr):.2f} |")
    # Блоки по 20 торговых дней (Faith): дневной результат в % баланса
    days = {}
    for t in tr:
        d = t["close_time"].date()
        days[d] = days.get(d, 0.0) + t["ret"]
    d0, d1 = first.date(), last.date()
    series = []
    d = d0
    while d <= d1:
        if d.weekday() < 5:
            series.append(days.get(d, 0.0))
        d += dt.timedelta(days=1)
    blocks = [series[i:i + 20] for i in range(0, len(series), 20)]
    bdd = []
    for _ in range(a.runs):
        eq, peak, dd = 1.0, 1.0, 0.0
        for _ in range(13):  # ~260 торговых дней
            for r in rnd.choice(blocks):
                eq *= 1.0 + r
                peak = max(peak, eq)
                dd = max(dd, (peak - eq) / peak)
        bdd.append(dd)
    print(f"| Блоки по 20 дней: медианная / 95% просадка за год | {statistics.median(bdd) * 100:.1f}% / "
          f"{pct(bdd, 0.95) * 100:.1f}% |")
    print(f"| Историческая макс. просадка (по закрытиям) | {max_dd(prof) * 100:.1f}% |\n")

    if not bars:
        return

    # 6a. Дрейф цены
    print("## 6. Проверки по ценам\n")
    print("### Вычитание дрейфа цены (Aronson)\n")
    print("| Период | Дрейф, USD/сутки | Итог | После вычитания | PF после | Покупки / продажи после |")
    print("|---|---|---|---|---|---|")
    all_adj = []
    for name, t0, t1, t in periods:
        dph = bars.drift_per_hour(t0, t1)
        adj = [x["profit"] - x["dir"] * dph * (x["close_time"] - x["open_time"]).total_seconds() / 3600.0
               * x["volume"] * CONTRACT for x in t]
        all_adj += adj
        la = sum(v for v, x in zip(adj, t) if x["dir"] == 1)
        sa = sum(v for v, x in zip(adj, t) if x["dir"] == -1)
        print(f"| {name.split('_M1_')[0]} | {dph * 24:.2f} | {sum(x['profit'] for x in t):.0f} | {sum(adj):.0f} | "
              f"{fmt_pf(pf(adj))} | {la:.0f} / {sa:.0f} |")
    print(f"\nВсего после вычитания дрейфа: итог {sum(all_adj):.0f}, PF {fmt_pf(pf(all_adj))}.\n")

    # 6b. Обезьяньи входы
    lo_h, hi_h = (int(x) for x in a.hours.split("-")) if a.hours else (0, 24)
    cand = [i for i, t in enumerate(bars.t) if first <= t <= last and lo_h <= t.hour < hi_h and t.weekday() < 5]
    holds = [x["close_time"] - x["open_time"] for x in tr]
    vols = [x["volume"] for x in tr]
    p_long = n_long / n
    act_dd = max_dd(prof)
    m_prof, m_dd = [], []
    for _ in range(a.runs):
        pnl = []
        for _ in range(n):
            i = rnd.choice(cand)
            t0 = bars.t[i]
            dd_ = 1 if rnd.random() < p_long else -1
            t1 = t0 + rnd.choice(holds)
            v = rnd.choice(vols)
            pnl.append((t0, dd_ * (bars.price(t1) - bars.c[i]) * v * CONTRACT - spread * v * CONTRACT))
        pnl.sort()
        ps = [x[1] for x in pnl]
        m_prof.append(sum(ps))
        m_dd.append(max_dd(ps))
    p_prof = sum(x >= actual for x in m_prof) / a.runs
    p_dd = sum(x <= act_dd for x in m_dd) / a.runs
    print("### «Обезьяньи» входы (Davey)\n")
    print(f"{a.runs} прогонов: по {n} случайных входов"
          f"{f' в {lo_h}:00–{hi_h}:00' if a.hours else ''}, доля покупок {p_long:.0%}, "
          f"время удержания и объём — из сделок стратегии.\n")
    print("| | Стратегия | Случайные: медиана | 90-й процентиль | Доля случайных не хуже |")
    print("|---|---|---|---|---|")
    print(f"| Итог, USD | {actual:.0f} | {statistics.median(m_prof):.0f} | {pct(m_prof, 0.9):.0f} | {p_prof:.3f} |")
    print(f"| Макс. просадка | {act_dd * 100:.1f}% | {statistics.median(m_dd) * 100:.1f}% | "
          f"{pct(m_dd, 0.1) * 100:.1f}% (10-й) | {p_dd:.3f} |")
    passed = p_prof <= 0.10 and p_dd <= 0.10
    print(f"\nКритерий Davey (лучше 90% случайных по итогу и по просадке): **{'пройден' if passed else 'не пройден'}**.\n")
    if a.trials:
        pk = 1.0 - (1.0 - p_prof) ** a.trials
        print(f"С поправкой на перебор: вероятность, что лучший из {a.trials} случайных вариантов не хуже стратегии, "
              f"— **{pk:.3f}** (1 − (1 − {p_prof:.3f})^{a.trials}, варианты считаются независимыми).\n")


if __name__ == "__main__":
    main()
