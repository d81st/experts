"""Шаг 1 плана (docs/roadmap-2026-11.md, 7.1–7.2): портфель рабочих ботов на истории.

Данные — минутки XAUUSDm строго до 2026-10-16 (холдаут не читается). Сделки каждого бота
строятся тем же движком, что и в конструкторе (`constructor.py`: исполнение по минуткам,
спред 0.25 USD, своп покупки, одна позиция на бота):

  * alch-h1x12   — Alchemist как в коде: H1, выход 12 баров, стоп 3 ATR, структура D1, обе стороны;
  * alch-long24  — кандидат демо-форварда: то же, только покупки, выход 24 бара;
  * asia-5r      — пробой Азии как в коде: тейк 5R, удержание до 120 ч;
  * chan-atr3    — трендовый канал H4 (Дончиан 20/10, стоп 3 ATR20, выход за каналом 10);
  * бенчмарки: ma-cross (H1, EMA20/EMA50, вход по пересечению, выход по обратному, стоп 3 ATR)
    и «купил и держи» (золото без плеча и с волатильностью, подогнанной под портфель).

Риск каждой сделки — доля баланса (по умолчанию 1 %); результат сделки в R переводится в
проценты: R × риск. Деньги не реинвестируются (сумма процентов), чтобы боты сравнивались
честно. Сделка записывается в день выхода.

Считается:
  * по каждому боту и портфелю: сделки, итог %, макс. просадка % (по закрытым сделкам),
    итог / просадка, худший месяц, по периодам 2024 / 2025 / янв–май 2026 / июнь–15 окт 2026;
  * корреляция дневного результата по датам (день без сделок = 0) и скользящая за 60 дней;
  * пересечение: доля времени, когда два бота одновременно в позиции в одну сторону, и
    максимум одновременного риска в одну сторону по всем ботам;
  * распределение риска: поровну; обратно волатильности дневного результата; 1 % одному
    боту и 0.5 % остальным;
  * снижение риска при просадке (Argus): множитель 1 / 0.5 / 0.25 / 0.1 / 0 при просадке
    от пика за 30 и 126 дней < 1.5 / 3 / 5 / 8 / ≥ 8 %.

Второй источник (--mt5): сделки настоящих ботов из отчётов тестера MT5 в ветке
`tester-results` (2024 и 2025 — OHLC M1, 2026 — реальные тики): Alchemist H1 выход 12 со
структурой D1 (`alch-d1-*`, вариант h1-x12-st; июнь–октябрь 2026 — до 2026-10-05) и пробой Азии
с тейком 5R и удержанием 120 ч (`asia-rexit-*`, вариант tp5-hold120). Результат сделки — доля
баланса перед входом (риск 1 % от текущего баланса), остальные боты — из Python.

    python3 tester/tools/portfolio.py --bars bars_XAUUSDm_M1.csv [--out результаты.csv] [--mt5]
"""
import subprocess
import tempfile
import argparse
import itertools
import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(__file__))
import constructor as C  # noqa: E402
import fvg_sim as FS  # noqa: E402
import screen as S  # noqa: E402

CUTOFF = np.datetime64("2026-10-16")
LABELS = [p[0] for p in FS.PERIODS] + ["26b*"]          # 26b* — июнь–15 окт 2026, уже смотрели


# ── сделки ботов ──────────────────────────────────────────────────────

def ma_cross(F, fast=20, slow=50, mult=3.0):
    ef = pd.Series(F.c).ewm(span=fast, adjust=False).mean().to_numpy()
    es = pd.Series(F.c).ewm(span=slow, adjust=False).mean().to_numpy()
    atr = F.atr(14)
    up = ef > es
    sig = []
    for j in range(slow, F.n - 1):
        if up[j] != up[j - 1] and np.isfinite(atr[j]):
            sig.append((j + 1, 1 if up[j] else -1, max(mult * atr[j], 1.0)))
    return sig, up


def ma_exit(P, F, up):
    """Выход по обратному пересечению: закрытие бара, на котором знак сменился против позиции."""
    nx = {1: C.next_true(~up), -1: C.next_true(up)}
    nxt_open = np.r_[F.t[1:].to_numpy(), F.t[-1].to_datetime64() + np.timedelta64(1, "D")]
    end_min = np.searchsorted(P.t, nxt_open) - 1
    ft = F.t.to_numpy()

    def own(f, d):
        i = int(np.searchsorted(ft, P.t[f], side="right")) - 1
        j = nx[d][max(i, 0)]
        return int(end_min[j]) if j < F.n else P.n - 1
    return own


def bot_trades(P, df, ctx):
    """{бот: DataFrame сделок: entry, exit, dir, R}."""
    m1 = df.set_index("time")[["open", "high", "low", "close"]]
    out = {}

    def take(name, cands, ex, entry_name, d1="off", side=0):
        tab = C.outcomes_for(P, cands, ex, entry_name)
        keep = C.filter_mask(P, ctx, tab, d1, "all", "off", "off")
        if side:
            keep &= tab[:, 1] == side
        f = tab[:, 0].astype(int)
        keep &= (P.period[f] >= 0) & (P.t[f] < CUTOFF)
        sel = C.one_position(f, tab[:, 4].astype(int), keep, tab[:, 5])
        t = tab[sel]
        out[name] = pd.DataFrame({"entry": P.t[t[:, 0].astype(int)], "exit": P.t[t[:, 4].astype(int)],
                                  "dir": t[:, 1].astype(int), "R": t[:, 3],
                                  "period": P.period[t[:, 0].astype(int)]})

    ents = C.build_entries(P, df, ["alch-H1", "asia-brk-M15"])
    take("alch-h1x12", ents["alch-H1"], "time12h", "alch-H1", d1="struct")
    take("alch-long24", ents["alch-H1"], "time24h", "alch-H1", d1="struct", side=1)
    take("asia-5r", ents["asia-brk-M15"], "tp5", "asia-brk-M15")

    h4 = S.Frame(S.resample(m1, "240min"), "H4")
    C.OWN_FN["chan-H4"] = C.channel_exit(P, h4)
    take("chan-atr3", C.market_entries(P, h4, C.channel(h4, mult=3.0)), "own", "chan-H4")

    h1 = S.Frame(S.resample(m1, "60min"), "H1")
    sig, up = ma_cross(h1)
    C.OWN_FN["ma-H1"] = ma_exit(P, h1, up)
    C.CAP_DAYS["ma"] = 30
    take("ma-cross", C.market_entries(P, h1, sig), "own", "ma-H1")
    return out


MT5_RUNS = {
    "alch-h1x12": [("run-39192566270", "alch-d1-24", "h1-x12-st"), ("run-39192569589", "alch-d1-25", "h1-x12-st"),
                   ("run-39192571946", "alch-d1-26a", "h1-x12-st"), ("run-39192574444", "alch-d1-26b", "h1-x12-st")],
    "asia-5r": [("run-40061522810", f"asia-rexit-{p}", "tp5-hold120") for p in ("24", "25", "26a", "26b")],
}


def mt5_trades(P, name):
    """Сделки бота из отчётов MT5 (ветка tester-results): entry, exit, dir, R (= доля баланса / 1 %)."""
    import trades as T
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for run, cfg, var in MT5_RUNS[name]:
            ref = f"origin/tester-results:{run}/{cfg}_XAUUSDm_M1_{var}.htm"
            path = os.path.join(tmp, "r.htm")
            open(path, "wb").write(subprocess.check_output(["git", "show", ref], cwd=C.FS.__file__.rsplit("/tester/", 1)[0]))
            for t in T.load_trades(path):
                if t["open_time"] >= pd.Timestamp("2026-10-16"):
                    continue
                rows.append((np.datetime64(t["open_time"]), np.datetime64(t["close_time"]), t["dir"], t["ret"] * 100))
    df = pd.DataFrame(rows, columns=["entry", "exit", "dir", "R"]).sort_values("entry")
    df["period"] = P.period[np.clip(np.searchsorted(P.t, df["entry"].to_numpy()), 0, P.n - 1)]
    return df.reset_index(drop=True)


# ── метрики ───────────────────────────────────────────────────────────

def daily(trades, risk, days):
    s = pd.Series(trades["R"].to_numpy() * risk, index=pd.DatetimeIndex(trades["exit"]).normalize())
    return s.groupby(level=0).sum().reindex(days, fill_value=0.0)


def curve_stats(d):
    eq = d.cumsum()
    dd = (eq.cummax().clip(lower=0) - eq)
    mon = d.groupby(d.index.to_period("M")).sum()
    tot, mdd = float(eq.iloc[-1]), float(dd.max())
    return {"итог%": tot, "просадка%": mdd, "итог/просадка": tot / mdd if mdd > 0 else np.inf,
            "худший месяц%": float(mon.min()), "прибыльных мес.": f"{(mon > 0).sum()}/{len(mon)}"}


def by_period(trades, risk):
    return " ".join(f"{lab} {trades.loc[trades.period == k, 'R'].sum() * risk:+.1f}%"
                    f"({(trades.period == k).sum()})" for k, lab in enumerate(LABELS))


def overlap(a, b):
    """Доля времени (по минутам торговли не считаем — по календарным часам), когда оба в позиции
    в одну сторону, от времени, когда в позиции хотя бы один."""
    hours = pd.date_range("2024-01-01", "2026-10-16", freq="h")
    hv = hours.to_numpy()

    def state(t):
        s = np.zeros(len(hours), int)
        for e, x, d in zip(t["entry"].to_numpy(), t["exit"].to_numpy(), t["dir"].to_numpy()):
            i0, i1 = np.searchsorted(hv, e), np.searchsorted(hv, x)
            s[i0:i1] = d
        return s
    sa, sb = state(a), state(b)
    any_ = (sa != 0) | (sb != 0)
    same = (sa != 0) & (sa == sb)
    return same.sum() / max(any_.sum(), 1), same.sum()


def max_same_side(trades_by_bot, risks):
    ev = []
    for name, t in trades_by_bot.items():
        for e, x, d in zip(t["entry"], t["exit"], t["dir"]):
            ev.append((e, 1, d, risks[name]))
            ev.append((x, -1, d, risks[name]))
    ev.sort(key=lambda z: (z[0], z[1]))
    cur = {1: 0.0, -1: 0.0}
    best = {1: 0.0, -1: 0.0}
    for _, k, d, r in ev:
        cur[d] += k * r
        best[d] = max(best[d], cur[d])
    return best


def throttled(trades_by_bot, risks):
    """Снижение риска при просадке: множитель по закрытому результату на момент входа."""
    rows = []
    for name, t in trades_by_bot.items():
        for e, x, R in zip(t["entry"], t["exit"], t["R"]):
            rows.append((pd.Timestamp(e), pd.Timestamp(x), R, risks[name]))
    rows.sort()
    closed = []                     # (время выхода, результат %)
    out = []
    for e, x, R, r in rows:
        past = sorted(c for c in closed if c[0] <= e)
        if past:
            s = pd.Series([p[1] for p in past], index=pd.DatetimeIndex([p[0] for p in past])).cumsum()
            dd = 0.0
            for days in (30, 126):
                w = s[s.index >= e - pd.Timedelta(days=days)]
                if len(w):
                    peak = max(w.max(), s[s.index < e - pd.Timedelta(days=days)].iloc[-1]
                               if (s.index < e - pd.Timedelta(days=days)).any() else 0.0)
                    dd = max(dd, peak - s.iloc[-1])
        else:
            dd = 0.0
        m = 1.0 if dd < 1.5 else 0.5 if dd < 3 else 0.25 if dd < 5 else 0.1 if dd < 8 else 0.0
        out.append((x, R * r * m))
        closed.append((x, R * r * m))
    s = pd.Series([o[1] for o in out], index=pd.DatetimeIndex([o[0] for o in out]).normalize())
    return s.groupby(level=0).sum()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--risk", type=float, default=1.0, help="риск на сделку, % баланса")
    ap.add_argument("--out", help="CSV со всеми сделками")
    ap.add_argument("--mt5", action="store_true", help="Alchemist H1x12 и пробой Азии — сделки из отчётов MT5")
    args = ap.parse_args()
    P, df, ctx = C.prepare(args)
    if P.t.max() >= CUTOFF:
        raise SystemExit("в данных есть холдаут (с 2026-10-16) — не читаю")
    trades = bot_trades(P, df, ctx)
    if args.mt5:
        for name in MT5_RUNS:
            trades[name] = mt5_trades(P, name)
        print("# Alchemist H1x12 и пробой Азии 5R — сделки настоящих ботов из отчётов MT5")
    if args.out:
        pd.concat([t.assign(bot=n) for n, t in trades.items()]).to_csv(args.out, index=False)
    days = pd.date_range("2024-01-01", "2026-10-15", freq="D")
    risk = args.risk
    live = ["alch-h1x12", "alch-long24", "asia-5r", "chan-atr3"]
    dly = {n: daily(t, risk, days) for n, t in trades.items()}

    print(f"# Боты по отдельности, риск {risk:g}% на сделку (сумма процентов, без реинвестирования)")
    for n, t in trades.items():
        st = curve_stats(dly[n])
        print(f"{n:12s} сделок {len(t):4d} R/сделку {t.R.mean():+.3f} | итог {st['итог%']:+6.1f}% "
              f"просадка {st['просадка%']:5.1f}% итог/просадка {st['итог/просадка']:5.2f} "
              f"худший мес. {st['худший месяц%']:+5.1f}% приб. мес. {st['прибыльных мес.']} | {by_period(t, risk)}")

    # купил и держи
    close = df.set_index("time")["close"]
    close = close[(close.index >= "2024-01-01") & (close.index < "2026-10-16")].resample("D").last().dropna()
    ret = close.pct_change().fillna(0) * 100
    bh = curve_stats(ret.reindex(days, fill_value=0.0))
    print(f"{'buy&hold':12s} без плеча: итог {bh['итог%']:+6.1f}% просадка {bh['просадка%']:5.1f}% "
          f"итог/просадка {bh['итог/просадка']:5.2f} худший мес. {bh['худший месяц%']:+5.1f}%")

    print("\n# Корреляция дневного результата (по датам, день без сделок = 0)")
    mat = pd.DataFrame({n: dly[n] for n in live + ["ma-cross"]}).assign(**{"buy&hold": ret.reindex(days, fill_value=0.0)})
    print(mat.corr().round(2).to_string())
    print("\n# Скользящая корреляция за 60 дней (мин / медиана / макс)")
    for a, b in itertools.combinations(live, 2):
        rc = mat[a].rolling(60).corr(mat[b]).dropna()
        print(f"{a:12s} — {b:12s} {rc.min():+.2f} / {rc.median():+.2f} / {rc.max():+.2f}")

    print("\n# Одновременно в позиции в одну сторону (доля от времени, когда в позиции хоть один)")
    for a, b in itertools.combinations(live, 2):
        frac, hrs = overlap(trades[a], trades[b])
        print(f"{a:12s} — {b:12s} {frac:5.1%} ({hrs} ч)")

    print("\n# Портфели (alch-long24 и alch-h1x12 — один советник, вместе не ставятся)")
    variants = {
        "alch-h1x12 + asia-5r": ["alch-h1x12", "asia-5r"],
        "alch-h1x12 + asia-5r + chan-atr3": ["alch-h1x12", "asia-5r", "chan-atr3"],
        "alch-long24 + asia-5r": ["alch-long24", "asia-5r"],
        "alch-long24 + asia-5r + chan-atr3": ["alch-long24", "asia-5r", "chan-atr3"],
    }
    for vname, bots in variants.items():
        vol = {n: dly[n].std() for n in bots}
        schemes = {
            "поровну": {n: risk for n in bots},
            "обратно волатильности": {n: risk * (1 / vol[n]) / np.mean([1 / vol[m] for m in bots]) for n in bots},
            f"{bots[0]} {risk:g}%, остальные {risk / 2:g}%": {n: (risk if n == bots[0] else risk / 2) for n in bots},
        }
        print(f"## {vname}")
        for sname, rk in schemes.items():
            d = sum(daily(trades[n], rk[n], days) for n in bots)
            st = curve_stats(d)
            ms = max_same_side({n: trades[n] for n in bots}, rk)
            print(f"  {sname:34s} итог {st['итог%']:+6.1f}% просадка {st['просадка%']:5.1f}% "
                  f"итог/просадка {st['итог/просадка']:5.2f} худший мес. {st['худший месяц%']:+5.1f}% "
                  f"приб. мес. {st['прибыльных мес.']} | макс. риск в одну сторону: покупки "
                  f"{ms[1]:.1f}% продажи {ms[-1]:.1f}%")
        thr = throttled({n: trades[n] for n in bots}, {n: risk for n in bots}).reindex(days, fill_value=0.0)
        st = curve_stats(thr)
        print(f"  {'поровну + снижение при просадке':34s} итог {st['итог%']:+6.1f}% просадка "
              f"{st['просадка%']:5.1f}% итог/просадка {st['итог/просадка']:5.2f} худший мес. "
              f"{st['худший месяц%']:+5.1f}% приб. мес. {st['прибыльных мес.']}")
        for k, lab in enumerate(LABELS):
            tot = sum(trades[n].loc[trades[n].period == k, "R"].sum() * risk for n in bots)
            print(f"    {lab}: {tot:+.1f}%", end="")
        print()


if __name__ == "__main__":
    main()
