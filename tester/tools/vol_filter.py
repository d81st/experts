"""Шаг 3 плана (docs/roadmap-2026-11.md, 7.4): фильтры волатильности на живых ботах.

Данные — минутки XAUUSDm строго до 2026-10-16. Сигнал бота не меняется — фильтр только решает,
пропустить ли его. Боты (движок `constructor.py`, сверенный с MT5):
  * alch-h1x12  — Alchemist H1, выход 12 баров, стоп 3 ATR, структура D1;
  * alch-long24 — то же, только покупки, выход 24 бара;
  * asia-5r     — пробой Азии, тейк 5R, удержание до 120 ч;
  * fvg-h1      — FVG-робот (H1, тейк 10R) — проверить, не спасает ли его фильтр.

Фильтры (значения — на закрытом баре сигнала или последнем закрытом дне, без перебора порогов):
  * vol20-exp / vol20-comp / vol20-notcomp / vol20-notexp — ATR(14) / SMA20(ATR) рабочего ТФ:
    > 1.3 (расширение), < 0.7 (сжатие), ≥ 0.7, ≤ 1.3 (как режимы в Argus);
  * vol100-hi / vol100-lo — ATR(14) D1 / медиана ATR(14) D1 за 100 дней: > 1 и < 1;
  * только для пробоя Азии: box-0.2 / box-0.3 / box-0.4 — ширина коробки ≥ 0.2 / 0.3 / 0.4 ATR(14)
    D1 вместо порога 3 USD (день, где коробка уже, пропускается целиком, как в боте).

Фильтр принимается, только если средний R выше, чем у того же бота без фильтра, во всех трёх
периодах подбора (не меньше 20 сделок в каждом), p ≤ 0.05 против случайных входов и p_max ≤ 0.10
(максимум z по всем испробованным фильтрам). Июнь–15 октября 2026 печатается как уже
смотревшееся сравнение и в решение не входит.

    python3 tester/tools/vol_filter.py --bars bars_XAUUSDm_M1.csv
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

CUTOFF = np.datetime64("2026-10-16")


def atr_ratio20(F):
    a = F.atr(14)
    return a / pd.Series(a).rolling(20).mean().to_numpy()


def signal_bar(P, F, f):
    """Индекс закрытого бара ТФ перед минутой входа f."""
    return int(np.searchsorted(F.t.to_numpy(), P.t[f], side="right")) - 2


def d1_ratio100(P, D1):
    tr = np.maximum(D1.high - D1.low, np.maximum(abs(D1.high - D1.close.shift()), abs(D1.low - D1.close.shift())))
    atr = tr.rolling(14).mean()
    ratio = (atr / atr.rolling(100).median()).to_numpy()
    close_t = (D1.index + pd.Timedelta("1D")).to_numpy()
    k = np.searchsorted(close_t, P.t, side="right") - 1
    return np.where(k >= 0, ratio[np.clip(k, 0, None)], np.nan), np.where(k >= 0, atr.to_numpy()[np.clip(k, 0, None)], np.nan)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    P, df, ctx = C.prepare(args)
    if P.t.max() >= CUTOFF:
        raise SystemExit("в данных есть холдаут (с 2026-10-16) — не читаю")
    mk = C.Monkey(P, np.random.default_rng(args.seed))
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    D1 = S.resample(m1, "1D")
    r100, atr_d1 = d1_ratio100(P, D1)
    frames = {"H1": S.Frame(S.resample(m1, "60min"), "H1"), "M15": S.Frame(S.resample(m1, "15min"), "M15")}
    r20 = {k: atr_ratio20(F) for k, F in frames.items()}

    ents = C.build_entries(P, df, ["alch-H1", "fvg-H1"])
    # пробой Азии без порога 3 USD — порог ставит фильтр
    asia_all = C.market_entries(P, frames["M15"], C.asia_breakout(frames["M15"], min_box=0.0))
    m15 = frames["M15"]
    day = m15.t.normalize()
    mask = m15.t.hour < 7
    box = (m15.df[mask].groupby(day[mask]).agg({"high": "max", "low": "min"}))
    box_w = (box["high"] - box["low"])
    box_w.index = box_w.index.to_numpy().astype("datetime64[D]").astype(np.int64)

    bots = {
        "alch-h1x12": (ents["alch-H1"], "time12h", "alch-H1", "struct", 0, "H1"),
        "alch-long24": (ents["alch-H1"], "time24h", "alch-H1", "struct", 1, "H1"),
        "asia-5r": (asia_all, "tp5", "asia-brk-M15", "off", 0, "M15"),
        "fvg-h1": (ents["fvg-H1"], "tp10", "fvg-H1", "off", 0, "H1"),
    }
    results, zs = [], []
    for bot, (cands, ex, ename, d1f, side, tf) in bots.items():
        tab = C.outcomes_for(P, cands, ex, ename)
        f = tab[:, 0].astype(int)
        sb = np.array([signal_bar(P, frames[tf], x) for x in f])
        v20 = np.where(sb >= 0, r20[tf][np.clip(sb, 0, None)], np.nan)
        v100 = r100[f]
        if bot == "asia-5r":
            bw = box_w.reindex(tab[:, 5].astype(np.int64)).to_numpy()
            ratio_box = bw / atr_d1[f]
            filters = {"base (коробка ≥ 3 USD)": bw >= 3.0,
                       "box-0.2": ratio_box >= 0.2, "box-0.3": ratio_box >= 0.3, "box-0.4": ratio_box >= 0.4}
            base_mask = filters["base (коробка ≥ 3 USD)"]
        else:
            filters = {"base": np.ones(len(f), bool)}
            base_mask = filters["base"]
        filters.update({
            "vol20-exp": base_mask & (v20 > 1.3), "vol20-comp": base_mask & (v20 < 0.7),
            "vol20-notcomp": base_mask & (v20 >= 0.7), "vol20-notexp": base_mask & (v20 <= 1.3),
            "vol100-hi": base_mask & (v100 > 1.0), "vol100-lo": base_mask & (v100 < 1.0),
        })
        print(f"# {bot}: кандидатов {len(f)}", flush=True)
        for fname, fm in filters.items():
            sub = tab[np.nan_to_num(fm, nan=0).astype(bool)]
            if side:
                sub = sub[sub[:, 1] == side]
            name = f"{ename}|{d1f}|all|off|off|{ex}"
            r, z = C.evaluate(P, ctx, mk, sub, name, holdout=True)
            r.update(bot=bot, filt=fname)
            results.append(r)
            if not fname.startswith("base") and z is not None:
                zs.append(z)
    zmax = np.nanmax(np.vstack(zs), axis=0)
    print(f"\nмаксимум z случайных по {len(zs)} фильтрам: медиана {np.median(zmax):.2f}, 90 % {np.quantile(zmax, 0.9):.2f}\n")
    base = {}
    for r in results:
        if r["filt"].startswith("base"):
            base[r["bot"]] = r
    for r in results:
        if "z" in r and np.isfinite(r.get("z", np.nan)):
            r["p_max"] = float((zmax >= r["z"]).mean())
        b = base[r["bot"]]
        better = (not r["filt"].startswith("base")) and all(
            r.get(f"n_{lab}", 0) >= 20 and r.get(f"R_{lab}", -9) > b.get(f"R_{lab}", 9) for lab, _, _ in FS.PERIODS
        ) and r.get("p", 1) <= 0.05 and r.get("p_max", 1) <= 0.10
        by = " ".join(f"{r.get(f'R_{lab}', np.nan):+.2f}({r.get(f'n_{lab}', 0)})" for lab, _, _ in FS.PERIODS)
        hold = f"{r.get('R_26b', np.nan):+.2f}({r.get('n_26b', 0)})"
        print(f"{r['bot']:12s} {r['filt']:24s} n={r.get('n', 0):4d} R={r.get('mean', np.nan):+.3f} "
              f"PF={r.get('pf', np.nan):.2f} p={r.get('p', np.nan):.3f} p_max={r.get('p_max', np.nan):.3f} | "
              f"{by} | 26b* {hold} {'ПРИНЯТ' if better else ''}")


if __name__ == "__main__":
    main()
