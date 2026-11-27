"""Живые боты на других символах (пункт 2 порядка владельца от 2026-11-26).

Минутки символа (выгрузка `tools/bar-dump` через тестер, `tester/data-*-m1.json`), строго до
2026-10-16. Движок `constructor.py` (сверен с MT5 на золоте). Правила ботов не меняются, только
масштаб:

  * Alchemist H1 — стоп 3 ATR и выход по времени не зависят от цены, переносятся как есть:
    x12 со структурой D1 (код), x12 без фильтра, long x24 со структурой D1;
  * пробой Азии — пороги в долларах золота (коробка ≥ 3, отступ 0.2, стоп за границей + 0.2,
    минимальный стоп 1) умножаются на k = медиана цены символа / медиана цены золота за 2024
    (2350 USD); тейк 5R, удержание до 120 ч и родной выход (закрытие в 20:00);
  * спред — медиана спреда символа по барам 2024 — 2026-10-15; своп не учитывается (спецификаций
    других символов нет) — у позиций, переносимых через ночь, результат завышен.

Сравнение — случайные входы того же периода, часа, направления и стопа (как в конструкторе).
Июнь–15 октября 2026 («26b*») для золота уже смотрели; для других символов эти данные новые, но
правило репозитория одно — решаем по 2024, 2025 и январю–маю 2026.

    python3 tester/tools/other_symbols.py --bars bars_EURUSDm_M1.csv --symbol EURUSDm
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

GOLD_2024 = 2350.0
CUTOFF = np.datetime64("2026-10-16")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--symbol", required=True)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    head = open(args.bars).readline()
    point = float(head.strip().split("point=")[1]) if "point=" in head else 0.0
    raw = pd.read_csv(args.bars, usecols=["time", "close", "spread"])
    raw["time"] = pd.to_datetime(raw["time"], format="%Y.%m.%d %H:%M")
    if (raw["time"] >= "2026-10-16").any():
        raw = raw[raw["time"] < "2026-10-16"]
        print("# бары с 2026-10-16 в файле есть — отрезаны, не читаются")
    price24 = raw.loc[raw.time.dt.year == 2024, "close"].median()
    k = price24 / GOLD_2024
    spread = float(raw.loc[raw.time >= "2024-01-01", "spread"].median() * point)
    C.SPREAD = spread
    C.MIN_STOP = 1.0 * k
    FS.SWAP_LONG = 0.0
    P, df, ctx = C.prepare(args)
    P_t_ok = P.t.max() < CUTOFF
    if not P_t_ok:
        raise SystemExit("в данных остался холдаут")
    mk = C.Monkey(P, np.random.default_rng(args.seed))
    print(f"# {args.symbol}: медиана цены 2024 {price24:.5g}, масштаб к золоту k = {k:.5g}, "
          f"медиана спреда {spread:.5g} ({spread / price24 * 1e4:.2f} б.п.), своп не учитывается\n")
    ents = C.build_entries(P, df, ["alch-H1"])
    m15 = S.Frame(S.resample(df.set_index("time")[["open", "high", "low", "close"]], "15min"), "M15")
    asia = C.market_entries(P, m15, C.asia_breakout(m15, min_box=3.0 * k, buf=0.2 * k, sl_buf=0.2 * k))
    C.OWN_FN["asia-brk-M15"] = C.close_at_hour(P, 20)
    rows = [("Alchemist H1 x12, структура D1", ents["alch-H1"], "alch-H1", "struct", "time12h", 0),
            ("Alchemist H1 x12 без фильтра", ents["alch-H1"], "alch-H1", "off", "time12h", 0),
            ("Alchemist H1 long x24, структура D1", ents["alch-H1"], "alch-H1", "struct", "time24h", 1),
            ("Пробой Азии, тейк 5R", asia, "asia-brk-M15", "off", "tp5", 0),
            ("Пробой Азии, закрытие в 20:00", asia, "asia-brk-M15", "off", "own", 0)]
    for title, cands, ename, d1f, ex, side in rows:
        tab = C.outcomes_for(P, cands, ex, ename)
        if side:
            tab = tab[tab[:, 1] == side]
        r, _ = C.evaluate(P, ctx, mk, tab, f"{ename}|{d1f}|all|off|off|{ex}", holdout=True)
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        ok = all(r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -1) > 0 for lab, _, _ in FS.PERIODS) \
            and r.get("p", 1) <= 0.05
        print(f"{title:38s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} PF={r.get('pf', np.nan):.2f} "
              f"DD={r.get('dd', np.nan):.0f}R rnd={r.get('rnd', np.nan):+.3f} p={r.get('p', np.nan):.3f} | {by} | "
              f"26b* {r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)}) {'ПЛЮС ВО ВСЕХ, p≤0.05' if ok else ''}")


if __name__ == "__main__":
    main()
