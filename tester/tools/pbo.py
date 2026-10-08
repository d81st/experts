"""Вероятность переобучения (PBO) методом CSCV — Bailey, Borwein, López de Prado, Zhu.

Использование:
    python3 tester/tools/pbo.py <папка с run-*> --window 2026.01.05:2026.10.05 [--S 10] [--family trend]

Берёт все отчёты, чьи настройки (json рядом в папке прогона) целиком лежат в окне и тестировались
на реальных тиках (или с --any-model — любых). Отчёты одного варианта за соседние периоды
(-is / -oos, -sel25 / -is) склеиваются. Для каждого варианта — дневной ряд доходности
(сумма profit / баланс по дате закрытия), 0 в дни без сделок. Остаются варианты, покрывающие
всё окно. Метрика — Sharpe дневного ряда (не зависит от риска на сделку).

CSCV: ряд делится на S блоков, перебираются все половины; на «обучающей» половине выбирается
лучший вариант, на другой смотрится его относительный ранг ω; λ = ln(ω / (1 − ω)).
PBO — доля λ ≤ 0. Порог из статьи: отвергать при PBO > 0.05.
"""
import argparse
import datetime as dt
import glob
import itertools
import json
import math
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trades import load_trades  # noqa: E402

D = lambda s: dt.datetime.strptime(s, "%Y.%m.%d").date()  # noqa: E731


def sharpe(xs):
    m = statistics.mean(xs)
    s = statistics.pstdev(xs)
    return m / s if s > 0 else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--window", required=True)
    ap.add_argument("--S", type=int, default=10)
    ap.add_argument("--any-model", action="store_true")
    ap.add_argument("--family", default="", help="подстрока в имени настроек (только эта семья)")
    ap.add_argument("--min-trades", type=int, default=10)
    a = ap.parse_args()
    w0, w1 = (D(x) for x in a.window.split(":"))

    # Отчёты: (база настроек, вариант) -> {период: путь}; более поздний прогон перезаписывает
    found = {}
    for run in sorted(glob.glob(os.path.join(a.root, "run-*")), key=lambda p: int(p.split("-")[-1])):
        for rep in glob.glob(os.path.join(run, "*.htm")):
            name = os.path.basename(rep)[:-4]
            m = re.match(r"(.+?)_(XAUUSDm?|XAUUSD)_(M1|M5|M15|H1|H4)(?:_(.+))?$", name)
            if not m:
                continue
            cfg_name, variant = m.group(1), m.group(4) or ""
            if a.family and a.family not in cfg_name:
                continue
            cfg_path = os.path.join(run, cfg_name + ".json")
            if not os.path.exists(cfg_path):
                continue
            try:
                cfg = json.load(open(cfg_path))
            except Exception:
                continue
            if cfg.get("expert", "").startswith("tools/"):
                continue
            f0, f1 = D(cfg["from"]), D(cfg["to"])
            if f1 < w0 or f0 > w1 or (not a.any_model and cfg.get("model") != 4):
                continue
            base = re.sub(r"-(is|oos|sel25|hist)$", "", cfg_name)
            found.setdefault((base, variant), {})[(f0, f1)] = rep

    days = []
    d = w0
    while d <= w1:
        if d.weekday() < 5:
            days.append(d)
        d += dt.timedelta(days=1)
    pos = {d: i for i, d in enumerate(days)}

    names, cols = [], []
    for key, per in sorted(found.items()):
        spans = sorted(per)
        if spans[0][0] > w0 + dt.timedelta(days=7) or spans[-1][1] < w1 - dt.timedelta(days=7):
            continue  # не покрывает окно
        col = [0.0] * len(days)
        n = 0
        for span in spans:
            for t in load_trades(per[span]):
                cd = t["close_time"].date()
                while cd not in pos and cd <= w1:
                    cd += dt.timedelta(days=1)
                if cd in pos:
                    col[pos[cd]] += t["ret"]
                    n += 1
        if n < a.min_trades:
            continue
        names.append(f"{key[0]} {key[1]}".strip())
        cols.append(col)

    N, T = len(cols), len(days)
    print(f"Окно {w0} – {w1}: {T} торговых дней, вариантов {N}, блоков S = {a.S}")
    if N < 4:
        print("Слишком мало вариантов.")
        return
    bl = [list(range(i * T // a.S, (i + 1) * T // a.S)) for i in range(a.S)]
    lams, deg_is, deg_oos, loss = [], [], [], 0
    for train in itertools.combinations(range(a.S), a.S // 2):
        tr_idx = [i for b in train for i in bl[b]]
        te_idx = [i for b in range(a.S) if b not in train for i in bl[b]]
        is_s = [sharpe([c[i] for i in tr_idx]) for c in cols]
        oos_s = [sharpe([c[i] for i in te_idx]) for c in cols]
        best = max(range(N), key=lambda j: is_s[j])
        rank = sum(1 for v in oos_s if v < oos_s[best]) + 0.5 * (sum(1 for v in oos_s if v == oos_s[best]) - 1) + 1
        om = rank / (N + 1)
        lams.append(math.log(om / (1 - om)))
        deg_is.append(is_s[best]); deg_oos.append(oos_s[best])
        loss += oos_s[best] < 0
    k = len(lams)
    pbo = sum(1 for x in lams if x <= 0) / k
    se = math.sqrt(pbo * (1 - pbo) / k)
    full = [sharpe(c) for c in cols]
    order = sorted(range(N), key=lambda j: -full[j])
    print(f"Комбинаций {k}. **PBO = {pbo:.2f}** (± {se:.2f}); вероятность убытка у выбранного на другой половине: "
          f"{loss / k:.2f}.")
    slope = 0.0
    if statistics.pstdev(deg_is) > 0:
        mi, mo = statistics.mean(deg_is), statistics.mean(deg_oos)
        slope = sum((x - mi) * (y - mo) for x, y in zip(deg_is, deg_oos)) / sum((x - mi) ** 2 for x in deg_is)
    print(f"Наклон «результат на второй половине ~ на первой» для выбранных: {slope:.2f} (отрицательный — признак "
          f"переобучения).")
    print("\nЛучшие по дневному Sharpe за всё окно:")
    for j in order[:8]:
        print(f"  {full[j] * math.sqrt(252):5.2f}  {names[j]}")


if __name__ == "__main__":
    main()
