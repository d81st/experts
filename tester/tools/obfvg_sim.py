"""Ордер-блок + незаполненный FVG (идея пользователя 2026-10-23): сделки тем же симулятором, что
FVG-робот (fvg_sim.run: K ближайших зон, срок лимитки N баров, исполнение по M1, спред, своп,
случайные входы для сравнения).

Зона (бычья; медвежья — зеркально):
  * ордер-блок — медвежья свеча k, вся свеча с фитилями; L — её минимум;
  * сразу после неё импульс оставил бычий FVG: low[j] > high[j−2], j−2 = k или k+1, размер
    не меньше 0.2 ATR(14). Зона известна с закрытия бара j.
Варианты входа:
  fvg      — все FVG без условия на ордер-блок (как FVG-робот) — база для сравнения;
  top      — только FVG с ордер-блоком; лимитка на верхнем крае FVG, стоп за нижним краем FVG
             + 0.3 USD (стоп 0.3–1.0 ATR, как у робота);
  top-ob   — то же, но стоп под минимумом ордер-блока − 0.3 USD (до 1.5 ATR);
  sweep    — «снятие ликвидности»: лимитка на L − off × ATR (в конце фитиля или чуть ниже),
             маленький стоп sd × ATR от входа.
Выход — тейк X R.

Использование:
    python3 tester/tools/obfvg_sim.py --bars bars_XAUUSDm_M1.csv grid [--holdout]
"""
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402


def atr14(tf):
    h, l, c = tf["high"].to_numpy(), tf["low"].to_numpy(), tf["close"].to_numpy()
    pc = np.roll(c, 1); pc[0] = c[0]
    return pd.Series(np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))).rolling(14).mean().to_numpy()


def combos(tf, need_ob=True, mingap=0.2):
    """(j, сторона, низ FVG, верх FVG, L) — для бычьей зоны; для медвежьей цены как есть
    (низ/верх FVG — ближний/дальний по ходу сделки, L — максимум ордер-блока)."""
    o, h, l, c = (tf[k].to_numpy() for k in ("open", "high", "low", "close"))
    a = atr14(tf)
    out = []
    for j in range(3, len(c)):
        if not np.isfinite(a[j]):
            continue
        if l[j] > h[j - 2] and l[j] - h[j - 2] >= mingap * a[j]:          # бычий FVG
            ks = [k for k in (j - 2, j - 3) if c[k] < o[k]]
            if need_ob and not ks:
                continue
            L = l[ks[0]] if ks else np.nan
            out.append((j, 1, l[j], h[j - 2], L, a[j]))                  # ближний — верх, дальний — низ
        elif h[j] < l[j - 2] and l[j - 2] - h[j] >= mingap * a[j]:        # медвежий FVG
            ks = [k for k in (j - 2, j - 3) if c[k] > o[k]]
            if need_ob and not ks:
                continue
            L = h[ks[0]] if ks else np.nan
            out.append((j, -1, h[j], l[j - 2], L, a[j]))
    return out


def zones(kind, off=0.0, sd=0.3):
    """Функция для fvg_sim.find_gaps: (j, направление, ближний край = лимитка, дальний = стоп)."""
    def f(tf):
        z = []
        for j, d, near, far, L, a in combos(tf, need_ob=(kind != "fvg")):
            if kind in ("fvg", "top"):
                z.append((j, d, near, far))
            elif kind == "top-ob":
                z.append((j, d, near, L))
            else:                                   # sweep: лимитка за L, стоп sd × ATR
                e = L - d * off * a
                z.append((j, d, e, e - d * sd * a))
        return z
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("cmd", choices=["grid"])
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    P = FS.Path(args.bars)
    variants = [("fvg", {}, dict(buffer=0.3, minSL=0.3, maxSL=1.0)),
                ("top", {}, dict(buffer=0.3, minSL=0.3, maxSL=1.0)),
                ("top-ob", {}, dict(buffer=0.3, minSL=0.3, maxSL=1.5))]
    for off, sd in itertools.product((0.0, 0.1, 0.25), (0.2, 0.3, 0.5)):
        variants.append((f"sweep o{off:g} s{sd:g}", dict(off=off, sd=sd), dict(buffer=0.0, minSL=0.05, maxSL=5.0)))
    monkeys = {}
    for tfm, age, ex in itertools.product((15, 30, 60), (3, 10), ("tp5", "tp10")):
        mk = monkeys.setdefault(ex, FS.Monkey(P, ex, False, 0.25, rng))
        for name, zk, rk in variants:
            FS.find_gaps = zones(name.split()[0], **zk)
            tr = FS.run(P, tfm, 50, 20, 3, "near", ex, False, spread=0.25, single=True, mingap=0.0,
                        minage=age, atr_mode=True, **rk)
            print(FS.fmt(f"M{tfm} a{age} {ex} {name}", FS.stats(P, tr, mk, args.holdout), args.holdout), flush=True)
        print(flush=True)


if __name__ == "__main__":
    main()
