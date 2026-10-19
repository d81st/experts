"""Сверка демо-счёта с тестером за месяц (по журналу сделок ботов).

Журнал: MQL5/Files/TradeJournal_<символ>.csv (Include/Core/TradeJournal.mqh). Строки:
  ENTRY — вход по рынку или постановка лимитки (TradeExecutorSend); FILL — исполнение лимитки;
  EXIT — выход (стоп, тейк, по рынку); SKIP — отказ/пропуск входа.
Сделка = вход (ENTRY по рынку или FILL) + EXIT с тем же тикетом позиции.

Что считает (по каждому magic):
  * сделки, закрытые в месяце: число, доля прибыльных, итог (валюта счёта), результат в цене
    (USD хода на унцию — не зависит от лота);
  * исполнение: проскальзывание на входе и на стопе/тейке (> 0 — хуже), спред;
  * пропуски входов (SKIP) по причинам.
Если указан отчёт тестера за тот же месяц (--report, HTML как в ветке tester-results), сделки
сопоставляются по времени входа (± --window минут) и направлению: совпавшие, только на демо,
только в тестере, разница результата в цене.

Использование:
    python3 tester/tools/demo_report.py --journal TradeJournal_XAUUSDm.csv --month 2026-11 \
        [--magic 71013] [--report tester.htm] [--window 5]
"""
import argparse
import datetime as dt
import os
import sys

import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

COLS = ["server_time", "event", "magic", "ticket", "type", "lot", "requested", "fill", "slippage", "spread",
        "sl", "tp", "latency_ms", "attempts", "profit", "retcode", "info"]


def load_journal(paths):
    frames = []
    for p in paths:
        d = pd.read_csv(p, sep=";", header=0, names=COLS, dtype=str, encoding="latin-1")
        frames.append(d)
    d = pd.concat(frames, ignore_index=True)
    d["time"] = pd.to_datetime(d["server_time"], format="%Y.%m.%d %H:%M:%S", errors="coerce")
    for c in ("lot", "requested", "fill", "slippage", "spread", "sl", "tp", "profit"):
        d[c] = pd.to_numeric(d[c], errors="coerce")
    d["magic"] = pd.to_numeric(d["magic"], errors="coerce")
    return d.dropna(subset=["time"])


def journal_trades(d):
    """Сделки: вход (ENTRY по рынку или FILL) + EXIT по тикету позиции."""
    ins = d[((d["event"] == "ENTRY") & d["type"].isin(["BUY", "SELL"])) | (d["event"] == "FILL")]
    outs = d[d["event"] == "EXIT"]
    rows = []
    for _, e in ins.iterrows():
        x = outs[(outs["ticket"] == e["ticket"]) & (outs["time"] >= e["time"])]
        if x.empty:
            continue
        exits = x  # частичные закрытия — несколько строк EXIT
        dirn = 1 if e["type"] == "BUY" else -1
        last = exits.iloc[-1]
        rows.append(dict(magic=int(e["magic"]), open_time=e["time"], close_time=last["time"], dir=dirn,
                         entry=e["fill"], exit=last["fill"], move=dirn * (last["fill"] - e["fill"]),
                         profit=exits["profit"].sum(), slip_in=e["slippage"],
                         slip_out=exits["slippage"].mean(), spread=e["spread"],
                         why=str(last["info"]), kind=e["event"]))
    return pd.DataFrame(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--journal", nargs="+", required=True)
    ap.add_argument("--month", required=True, help="ГГГГ-ММ")
    ap.add_argument("--magic", type=int)
    ap.add_argument("--report", help="HTML-отчёт тестера за тот же период")
    ap.add_argument("--window", type=int, default=5, help="допуск по времени входа, минут")
    args = ap.parse_args()
    a = pd.Timestamp(args.month + "-01")
    b = a + pd.offsets.MonthBegin(1)
    d = load_journal(args.journal)
    if args.magic:
        d = d[d["magic"] == args.magic]
    tr = journal_trades(d)
    if not tr.empty:
        tr = tr[(tr["close_time"] >= a) & (tr["close_time"] < b)]
    print(f"# Демо за {args.month}: сделки, закрытые в месяце")
    if tr.empty:
        print("сделок нет")
    for m, g in tr.groupby("magic"):
        print(f"\n## magic {m}: сделок {len(g)}, прибыльных {(g['profit'] > 0).mean():.0%}, итог {g['profit'].sum():+.2f}, "
              f"ход цены по сделкам {g['move'].sum():+.2f} USD/унция")
        print(f"исполнение: проскальзывание на входе среднее {g['slip_in'].mean():+.3f} (макс {g['slip_in'].max():+.3f}), "
              f"на выходе {g['slip_out'].mean():+.3f}; спред при входе {g['spread'].mean():.3f}")
        print(f"выходы: {g['why'].value_counts().to_dict()}")
    sk = d[(d["event"] == "SKIP") & (d["time"] >= a) & (d["time"] < b)]
    if not sk.empty:
        print(f"\nпропуски входов: {sk['info'].value_counts().to_dict()}")

    if args.report:
        from trades import load_trades
        tt = [t for t in load_trades(args.report) if a <= pd.Timestamp(t["close_time"]) < b]
        print(f"\n# Сверка с тестером ({os.path.basename(args.report)}): в тестере {len(tt)}, на демо {len(tr)}")
        used, rows = set(), []
        w = dt.timedelta(minutes=args.window)
        for _, j in tr.iterrows():
            best = None
            for k, t in enumerate(tt):
                if k in used or t["dir"] != j["dir"]:
                    continue
                dtm = abs(pd.Timestamp(t["open_time"]) - j["open_time"])
                if dtm <= w and (best is None or dtm < best[1]):
                    best = (k, dtm)
            if best is None:
                rows.append(("только демо", j["open_time"], j["dir"], j["move"], None))
            else:
                used.add(best[0]); t = tt[best[0]]
                mt = t["dir"] * (t["close_price"] - t["open_price"])
                rows.append(("совпала", j["open_time"], j["dir"], j["move"], mt))
        for k, t in enumerate(tt):
            if k not in used:
                rows.append(("только тестер", pd.Timestamp(t["open_time"]), t["dir"], None,
                             t["dir"] * (t["close_price"] - t["open_price"])))
        r = pd.DataFrame(rows, columns=["вид", "вход", "dir", "демо", "тестер"])
        print(r["вид"].value_counts().to_string())
        m = r[r["вид"] == "совпала"]
        if not m.empty:
            diff = (m["демо"] - m["тестер"])
            print(f"совпавшие: ход цены демо {m['демо'].sum():+.2f}, тестер {m['тестер'].sum():+.2f}, "
                  f"разница на сделку средняя {diff.mean():+.3f} USD/унция (хуже — минус)")
        print(r.sort_values("вход").to_string(index=False))


if __name__ == "__main__":
    main()
