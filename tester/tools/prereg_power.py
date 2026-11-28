"""Мощность проверки на холдауте (предрегистрация 2026-11-28): какой шанс у бота пройти критерии.

Сделки кандидатов 2024 — 2026-10-15 (движок `constructor.py`, сверен с MT5): Alchemist long x24
и пробой Азии 5R; у каждой сделки известны R и стоп в USD. Моделируется много «холдаутов» по
N сделок (бутстрэп с возвращением) в трёх сценариях преимущества:
  * как на истории — R без изменений;
  * вдвое меньше — из каждой сделки вычитается половина среднего R;
  * нулевое — вычитается всё среднее R (проверка ложных срабатываний).

Критерии (черновик `docs/oos-protocol.md` и варианты):
  * сделок ≥ 100;
  * PF в R: нижняя граница бутстрэп-интервала 97.5 % (поправка на две гипотезы) > 1; вариант —
    односторонняя 95 % граница > 1; вариант — точечный PF > 1;
  * просадка по средствам при риске 1 % от баланса (сложный процент, по закрытым сделкам) ≤ 15 %
    или ≤ 20 %;
  * стресс спреда +0.20 / +0.50 USD: из R вычитается добавка / стоп в USD (задержка 500 мс не
    моделируется).

    python3 tester/tools/prereg_power.py --bars bars_XAUUSDm_M1.csv [--n 100]
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402

OUTER, INNER = 2000, 1000


def pf(r):
    g = np.where(r > 0, r, 0).sum(-1)
    l = -np.where(r < 0, r, 0).sum(-1)
    return np.where(l > 0, g / np.maximum(l, 1e-12), np.inf)


def lower_bound(samples, q, rng):
    """Нижняя перцентильная граница PF для каждого из samples (OUTER × N)."""
    out = np.empty(len(samples))
    n = samples.shape[1]
    for i in range(0, len(samples), 50):
        blk = samples[i:i + 50]
        idx = rng.integers(0, n, (len(blk), INNER, n))
        boot = pf(np.take_along_axis(blk[:, None, :].repeat(INNER, 1), idx, 2))
        out[i:i + 50] = np.quantile(boot, q, axis=1)
    return out


def max_dd(samples, risk=0.01):
    path = np.cumprod(1 + risk * samples, axis=1)
    path = np.concatenate([np.ones((len(samples), 1)), path], axis=1)
    return (1 - path / np.maximum.accumulate(path, axis=1)).max(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20261128)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P, df, ctx = C.prepare(args)
    ents = C.build_entries(P, df, ["alch-H1", "asia-brk-M15"])
    bots = {}
    tab = C.outcomes_for(P, ents["alch-H1"], "time24h", "alch-H1")
    keep = C.filter_mask(P, ctx, tab, "struct", "all", "off", "off") & (tab[:, 1] == 1) & (P.period[tab[:, 0].astype(int)] >= 0)
    bots["Alchemist long x24"] = tab[C.one_position(tab[:, 0].astype(int), tab[:, 4].astype(int), keep, tab[:, 5])]
    tab = C.outcomes_for(P, ents["asia-brk-M15"], "tp5", "asia-brk-M15")
    keep = P.period[tab[:, 0].astype(int)] >= 0
    bots["Пробой Азии 5R"] = tab[C.one_position(tab[:, 0].astype(int), tab[:, 4].astype(int), keep, tab[:, 5])]
    N = args.n
    print(f"# Шанс пройти критерии на холдауте из {N} сделок ({OUTER} моделей холдаута, внутренний бутстрэп {INNER})\n")
    for name, t in bots.items():
        R, sd = t[:, 3], t[:, 2]
        mu = R.mean()
        print(f"## {name}: сделок в истории {len(R)}, R {mu:+.3f}, PF {pf(R):.2f}, медианный стоп {np.median(sd):.1f} USD")
        for lab, shift in (("как на истории", 0.0), ("вдвое меньше", mu / 2), ("нулевое", mu)):
            idx = rng.integers(0, len(R), (OUTER, N))
            base = R[idx] - shift
            s20 = base - 0.20 / sd[idx]
            s50 = base - 0.50 / sd[idx]
            lb975 = lower_bound(base, 0.0125, rng)
            lb95 = lower_bound(base, 0.05, rng)
            lb975_20 = lower_bound(s20, 0.0125, rng)
            lb975_50 = lower_bound(s50, 0.0125, rng)
            dd = max_dd(base)
            point = pf(base)
            c_lb = lb975 > 1
            c_dd15, c_dd20 = dd <= 0.15, dd <= 0.20
            c_st = (lb975_20 > 1) & (lb975_50 > 1)
            c_st_pt = (pf(s20) > 1) & (pf(s50) > 1)
            print(f"   преимущество {lab:15s} (R {mu - shift:+.3f}):")
            print(f"      PF: нижняя 97.5 % > 1 — {c_lb.mean():5.1%}; односторонняя 95 % > 1 — {(lb95 > 1).mean():5.1%}; "
                  f"точечный > 1 — {(point > 1).mean():5.1%}")
            print(f"      просадка ≤ 15 % — {c_dd15.mean():5.1%}; ≤ 20 % — {c_dd20.mean():5.1%}; "
                  f"стресс спреда (граница 97.5 %) — {c_st.mean():5.1%}, (точечный PF) — {c_st_pt.mean():5.1%}")
            print(f"      ЧЕРНОВИК целиком (граница 97.5 %, просадка 15 %, стресс по границе) — {(c_lb & c_dd15 & c_st).mean():5.1%}")
            print(f"      ВАРИАНТ (односторонняя 95 %, просадка 20 %, стресс по точечному PF) — "
                  f"{((lb95 > 1) & c_dd20 & c_st_pt).mean():5.1%}")
        print()


if __name__ == "__main__":
    main()
