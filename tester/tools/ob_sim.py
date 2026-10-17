"""Ордер-блоки (LimonFx, indicators/tradingview/03-…) как зоны для лимиток — тем же симулятором,
что и FVG (fvg_sim.run): выбор K ближайших, срок лимитки N баров, стоп и фильтры в ATR, тейк в R,
случайные входы для сравнения.

Ордер-блок (как drawVOB в индикаторе, позиция «Accurate»):
  * внутренняя структура, точки разворота len 5 (structure.py);
  * пробой вверх (BOS или CHoCH) на баре i: среди баров после пробитого максимума и до i
    включительно — бар с самым низким минимумом. Зона: от его минимума (дальний край, стоп за
    ним) до середины бара hl2 (ближний край, лимитка на покупку);
  * пробой вниз — зеркально: бар с самым высоким максимумом, продажа от hl2, стоп за максимумом;
  * блок известен с закрытия бара пробоя; снимается, когда цена прошла дальний край.
Отличия от индикатора: берём сам бар экстремума (в индикаторе верх зоны — hl2 соседнего, более
раннего бара); перекрывающиеся блоки не убираем.

Использование:
    python3 tester/tools/ob_sim.py --bars bars_XAUUSDm_M1.csv one [--zones ob|fvg|both] [параметры]
    python3 tester/tools/ob_sim.py --bars bars_XAUUSDm_M1.csv grid [--zones ob]
"""
import argparse
import itertools
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import fvg_sim as FS  # noqa: E402
from structure import pivots  # noqa: E402

_find_fvg = FS.find_gaps


def find_obs(tf, L=5):
    """Список блоков: (бар пробоя j, направление сделки, ближний край, дальний край)."""
    h, l, c = tf["high"].to_numpy(), tf["low"].to_numpy(), tf["close"].to_numpy()
    ph, pl = pivots(h, l, L)
    out = []
    up = dn = None             # (цена, бар точки)
    nlow = nhigh = 0
    for i in range(1, len(c)):
        if not np.isnan(ph[i]):
            up = (ph[i], i - L); nhigh += 1
        elif not np.isnan(pl[i]):
            dn = (pl[i], i - L); nlow += 1
        if up is not None and nlow > 1 and c[i] > up[0] and c[i - 1] <= up[0]:
            seg = slice(up[1] + 1, i + 1)
            k = up[1] + 1 + int(np.argmin(l[seg]))
            out.append((i, 1, (h[k] + l[k]) / 2, l[k]))
            up = None
        if dn is not None and nhigh > 1 and c[i] < dn[0] and c[i - 1] >= dn[0]:
            seg = slice(dn[1] + 1, i + 1)
            k = dn[1] + 1 + int(np.argmax(h[seg]))
            out.append((i, -1, (h[k] + l[k]) / 2, h[k]))
            dn = None
    return out


def zones_fn(kind):
    if kind == "ob":
        return find_obs
    if kind == "fvg":
        return _find_fvg
    return lambda tf: sorted(find_obs(tf) + _find_fvg(tf), key=lambda g: g[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--holdout", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--spread", type=float, default=0.25)
    ap.add_argument("--zones", default="ob", choices=["ob", "fvg", "both"])
    sub = ap.add_subparsers(dest="cmd", required=True)
    one = sub.add_parser("one")
    one.add_argument("--tf", type=int, default=60)
    one.add_argument("--L", type=int, default=50)
    one.add_argument("--N", type=int, default=20)
    one.add_argument("--K", type=int, default=3)
    one.add_argument("--exit", default="tp10")
    one.add_argument("--minsl", type=float, default=0.3)
    one.add_argument("--maxsl", type=float, default=1.0)
    one.add_argument("--mingap", type=float, default=0.2)
    one.add_argument("--minage", type=int, default=10)
    one.add_argument("--single", action="store_true")
    grid = sub.add_parser("grid")
    grid.add_argument("--tfs", default="60")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    FS.find_gaps = zones_fn(args.zones)
    P = FS.Path(args.bars)
    if args.cmd == "one":
        tr = FS.run(P, args.tf, args.L, args.N, args.K, "near", args.exit, False, minSL=args.minsl,
                    maxSL=args.maxsl, spread=args.spread, single=args.single, mingap=args.mingap,
                    minage=args.minage, atr_mode=True)
        mk = FS.Monkey(P, args.exit, False, args.spread, rng)
        print(FS.fmt(f"{args.zones} M{args.tf} N{args.N} K{args.K} g{args.mingap:g} sl{args.minsl:g}-{args.maxsl:g} "
                     f"a{args.minage} {args.exit}{' 1поз' if args.single else ''}",
                     FS.stats(P, tr, mk, args.holdout), args.holdout))
        return
    monkeys = {}
    for tfm in [int(x) for x in args.tfs.split(",")]:
        for age, N, mg, mn, mx, ex in itertools.product((0, 3, 10), (10, 20, 40), (0.1, 0.2, 0.3),
                                                        (0.3,), (0.6, 1.0), ("tp3", "tp5", "tp10")):
            tr = FS.run(P, tfm, 50, N, 3, "near", ex, False, minSL=mn, maxSL=mx, spread=args.spread,
                        mingap=mg, minage=age, atr_mode=True)
            mk = monkeys.setdefault(ex, FS.Monkey(P, ex, False, args.spread, rng))
            print(FS.fmt(f"{args.zones} M{tfm} N{N} g{mg:g} sl{mn:g}-{mx:g} a{age} {ex}",
                         FS.stats(P, tr, mk, args.holdout), args.holdout), flush=True)


if __name__ == "__main__":
    main()
