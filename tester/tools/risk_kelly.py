"""Идея из науки 5 (`docs/ideas-science.md`): размер риска по Келли и «толстые хвосты».

Не новый вход — расчёт на готовых сделках живых ботов (как в `portfolio.py`: Alchemist H1 x12 и
пробой Азии 5R — сделки ботов из отчётов MT5, Alchemist long x24 — Python), 2024 — 2026-10-15.

Для каждого бота (результат сделки в R):
  * **Келли:** доля капитала под риском на сделку f*, максимизирующая средний log(1 + f·R) по
    фактическим сделкам; половина и четверть Келли;
  * **хвосты:** худшая сделка, доля сделок хуже −1.1R (проскальзывание, гэпы), 1 % худших дней
    портфеля;
  * **серии:** самая длинная серия убытков; вероятность серии ≥ 8 / 10 / 12 подряд за год
    (бутстрэп сделок);
  * **Монте-Карло на год вперёд:** сделки перемешиваются с возвращением (число сделок — как за
    год), риск 0.5 % / 1 % / 2 % / половина Келли от текущего баланса; медианная доходность,
    медианная и 95-я процентиль максимальной просадки, вероятность просадки > 20 %.
Для портфеля Alchemist x12 + пробой Азии — бутстрэп целыми днями (сохраняет связь ботов).

    python3 tester/tools/risk_kelly.py --bars bars_XAUUSDm_M1.csv
"""
import argparse
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402
import portfolio as PF  # noqa: E402

RUNS = 5000


def kelly(r):
    fs = np.linspace(0.001, 0.5, 500)
    g = [np.mean(np.log1p(f * r)) if (1 + f * r.min()) > 0 else -np.inf for f in fs]
    return float(fs[int(np.argmax(g))])


def max_streak(r):
    s = m = 0
    for x in r:
        s = s + 1 if x < 0 else 0
        m = max(m, s)
    return m


def mc_year(r, per_year, risk, rng):
    """Перемешивание сделок на год, риск — доля текущего баланса. Возврат: доходность, просадка."""
    idx = rng.integers(0, len(r), (RUNS, per_year))
    path = np.cumprod(1 + risk * r[idx], axis=1)
    path = np.concatenate([np.ones((RUNS, 1)), path], axis=1)
    dd = 1 - path / np.maximum.accumulate(path, axis=1)
    return path[:, -1] - 1, dd.max(1), np.array([max_streak(r[i]) for i in idx[:1000]])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P, df, ctx = C.prepare(args)
    trades = PF.bot_trades(P, df, ctx)
    for name in PF.MT5_RUNS:
        trades[name] = PF.mt5_trades(P, name)
    years = (np.datetime64("2026-10-16") - np.datetime64("2024-01-01")).astype(int) / 365.25
    print("# Келли, хвосты и Монте-Карло на год (2024 — 2026-10-15; MT5 — Alchemist x12 и Азия 5R)\n")
    for name in ("alch-h1x12", "alch-long24", "asia-5r"):
        t = trades[name]
        r = t["R"].to_numpy()
        per_year = int(round(len(r) / years))
        k = kelly(r)
        wins, losses = r[r > 0], r[r < 0]
        print(f"## {name}: сделок {len(r)} (~{per_year} в год), R {r.mean():+.3f}, выигрышей {len(wins) / len(r):.0%}, "
              f"средний выигрыш {wins.mean():+.2f}R, средний убыток {losses.mean():+.2f}R")
        print(f"   Келли f* = {k:.1%} риска на сделку; половина {k / 2:.1%}, четверть {k / 4:.1%}")
        print(f"   хвосты: худшая сделка {r.min():+.2f}R, хуже −1.1R: {np.mean(r < -1.1):.1%} сделок; "
              f"самая длинная серия убытков {max_streak(r)}")
        for risk, lab in ((0.005, "0.5 %"), (0.01, "1 %"), (0.02, "2 %"), (k / 2, f"½ Келли {k / 2:.1%}")):
            ret, dd, streaks = mc_year(r, per_year, risk, rng)
            print(f"   риск {lab:>13}: доходность за год медиана {np.median(ret):+6.1%} (5 % худших {np.quantile(ret, 0.05):+6.1%}) | "
                  f"просадка медиана {np.median(dd):5.1%}, 95 % {np.quantile(dd, 0.95):5.1%}, P(>20 %) {np.mean(dd > 0.2):5.1%}")
        _, _, streaks = mc_year(r, per_year, 0.01, rng)
        print(f"   серия убытков за год: P(≥8) {np.mean(streaks >= 8):.0%}, P(≥10) {np.mean(streaks >= 10):.0%}, "
              f"P(≥12) {np.mean(streaks >= 12):.0%}\n")

    # портфель: бутстрэп днями
    days = pd.date_range("2024-01-01", "2026-10-15", freq="D")
    d = sum(PF.daily(trades[n], 1.0, days) for n in ("alch-h1x12", "asia-5r")) / 100.0   # доля баланса при 1 %
    dv = d.to_numpy()
    print("## портфель Alchemist x12 + пробой Азии, по 1 % (бутстрэп днями, 365 дней)")
    print(f"   1 % худших дней: {np.quantile(dv[dv != 0], 0.01):+.2%} баланса; худший день {dv.min():+.2%}")
    for mult, lab in ((0.5, "по 0.5 %"), (1.0, "по 1 %"), (2.0, "по 2 %")):
        idx = rng.integers(0, len(dv), (RUNS, 365))
        path = np.cumprod(1 + mult * dv[idx], axis=1)
        dd = (1 - path / np.maximum.accumulate(path, axis=1)).max(1)
        print(f"   {lab}: доходность за год медиана {np.median(path[:, -1] - 1):+.1%} (5 % худших "
              f"{np.quantile(path[:, -1] - 1, 0.05):+.1%}) | просадка медиана {np.median(dd):.1%}, "
              f"95 % {np.quantile(dd, 0.95):.1%}, P(>20 %) {np.mean(dd > 0.2):.1%}")


if __name__ == "__main__":
    main()
