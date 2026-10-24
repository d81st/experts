"""Команды: прогон алхимика и сверка с отчётом MT5.

Холдаут с 2026-10-16 не читается без явного --allow-holdout.
`--to` включительный: тик полуночи следующего дня уже не берётся.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .compare import compare_trades, load_our_csv, load_mt5
from .engine import Engine, EngineConfig
from .metrics import compute_metrics, format_metrics_ru
from .session import ExnessGoldSession
from .strategies.alchemist import AlchemistConfig, AlchemistStrategy, h1_x12_st
from .ticks import iter_ticks
from .types import Bar, Trade, xauusd_exness

HOLDOUT_START = datetime(2026, 10, 16, tzinfo=timezone.utc)
HOLDOUT_MSC = int(HOLDOUT_START.timestamp() * 1000)


def _day_start(text: str) -> int:
    dt = datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def _day_end_exclusive(text: str) -> int:
    dt = datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
    return int(dt.timestamp() * 1000)


def _iso(time_msc: int) -> str:
    moment = datetime.fromtimestamp(time_msc / 1000.0, timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _refuse_holdout(end_exclusive_msc: int, allow: bool) -> None:
    if end_exclusive_msc > HOLDOUT_MSC and not allow:
        raise SystemExit(
            "Отказ: интервал захватывает холдаут с 2026-10-16. "
            "См. docs/oos-protocol.md. Нужен явный --allow-holdout."
        )


def _write_trades(path: Path, trades: list[Trade]) -> None:
    fields = [
        "id", "side", "volume", "entry_time", "exit_time", "entry_price", "exit_price",
        "sl", "tp", "exit_reason", "gross_pnl", "commission", "swap", "net_pnl",
        "initial_risk", "r", "entry_spread", "exit_spread", "ambiguous_sl_tp", "comment",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for trade in trades:
            writer.writerow(
                {
                    "id": trade.id,
                    "side": "long" if trade.side == 1 else "short",
                    "volume": f"{trade.volume:.4f}",
                    "entry_time": _iso(trade.entry_time_msc),
                    "exit_time": _iso(trade.exit_time_msc),
                    "entry_price": f"{trade.entry_price:.5f}",
                    "exit_price": f"{trade.exit_price:.5f}",
                    "sl": "" if trade.sl is None else f"{trade.sl:.5f}",
                    "tp": "" if trade.tp is None else f"{trade.tp:.5f}",
                    "exit_reason": trade.exit_reason,
                    "gross_pnl": f"{trade.gross_pnl:.4f}",
                    "commission": f"{trade.commission:.4f}",
                    "swap": f"{trade.swap:.4f}",
                    "net_pnl": f"{trade.net_pnl:.4f}",
                    "initial_risk": "" if trade.initial_risk is None else f"{trade.initial_risk:.4f}",
                    "r": "" if trade.r_multiple is None else f"{trade.r_multiple:.6f}",
                    "entry_spread": f"{trade.entry_spread:.5f}",
                    "exit_spread": f"{trade.exit_spread:.5f}",
                    "ambiguous_sl_tp": int(trade.ambiguous_sl_tp),
                    "comment": trade.comment,
                }
            )


def _write_equity(path: Path, points) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=["time", "balance", "equity", "event"])
        writer.writeheader()
        for point in points:
            writer.writerow(
                {
                    "time": _iso(point.time_msc) if point.time_msc else "",
                    "balance": f"{point.balance:.4f}",
                    "equity": f"{point.equity:.4f}",
                    "event": point.event,
                }
            )


def _load_warmup_m1(path: Path, before_msc: int) -> list[Bar]:
    """CSV time,open,high,low,close. Ask = bid: прогрев индикаторов, не исполнение."""
    from .bars import TF_MS, aggregate_bars

    bars: list[Bar] = []
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            moment = datetime.fromisoformat(row["time"].replace("Z", "+00:00"))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=timezone.utc)
            time_msc = int(moment.timestamp() * 1000)
            bid_o = float(row["open"])
            bid_h = float(row["high"])
            bid_l = float(row["low"])
            bid_c = float(row["close"])
            bars.append(
                Bar("M1", time_msc, bid_o, bid_h, bid_l, bid_c, bid_o, bid_h, bid_l, bid_c, 1, 0.0)
            )
    closed = [bar for bar in bars if bar.time_msc + TF_MS["M1"] <= before_msc]
    return closed


def _cmd_alchemist(args: argparse.Namespace) -> int:
    end_msc = _day_end_exclusive(args.to)
    _refuse_holdout(end_msc, args.allow_holdout)
    trade_from = _day_start(args.trade_from) if args.trade_from else _day_start(args.data_from) if args.data_from else None
    data_from = _day_start(args.data_from) if args.data_from else None
    if trade_from is not None and trade_from >= HOLDOUT_MSC and not args.allow_holdout:
        raise SystemExit("Отказ: trade-from попадает в холдаут с 2026-10-16.")
    spec = xauusd_exness(leverage=args.leverage)
    cfg = h1_x12_st()
    if args.risk_basis:
        cfg = AlchemistConfig(**{**cfg.__dict__, "risk_basis": args.risk_basis})
    strategy = AlchemistStrategy(cfg, digits=spec.digits, adjusted_point=spec.adjusted_point)
    engine = Engine(
        EngineConfig(
            symbol=spec,
            deposit=args.deposit,
            latency_ms=args.latency_ms,
            limit_penetration=args.limit_penetration,
            commission_per_lot_side=-abs(args.commission_per_lot_side),
            swap_long_per_lot=args.swap_long,
            swap_short_per_lot=args.swap_short,
            triple_swap_weekday=args.triple_swap_weekday,
            trading_from_msc=trade_from,
            close_at_end=not args.no_close_at_end,
            sample_tf=cfg.timeframe,
        ),
        strategy,
        session=ExnessGoldSession(),
        max_risk_overshoot=cfg.max_risk_overshoot,
    )
    if args.warmup_m1:
        before = data_from if data_from is not None else (trade_from or end_msc)
        seed = _load_warmup_m1(Path(args.warmup_m1), before)
        from .bars import TF_MS, aggregate_bars

        for tf in strategy.required_timeframes():
            period = TF_MS[tf]
            ready = [bar for bar in aggregate_bars(seed, tf) if bar.time_msc + period <= before]
            if ready:
                engine.bars.seed_closed(ready)
    ticks = iter_ticks(
        args.ticks,
        args.source,
        start_msc=data_from,
        end_msc=end_msc,
        price_offset=args.price_offset,
        spread_multiplier=args.spread_multiplier,
        spread_addon=args.spread_addon,
    )
    seen = 0

    def ticking():
        nonlocal seen
        for tick in ticks:
            seen += 1
            if seen % 500_000 == 0:
                print(f"… {seen} тиков, {_iso(tick.time_msc)}", file=sys.stderr)
            if tick.time_msc >= HOLDOUT_MSC and not args.allow_holdout:
                raise SystemExit("Отказ: в поток попал тик холдаута. Чтение остановлено.")
            yield tick

    result = engine.run(ticking())
    if result.last_time_msc is not None and result.last_time_msc >= HOLDOUT_MSC and not args.allow_holdout:
        raise SystemExit("Отказ: последний тик не раньше холдаута.")
    metrics = compute_metrics(
        result.trades,
        result.drawdown,
        deposit=args.deposit,
        bootstrap=args.bootstrap,
        seed=args.seed,
    )
    metrics["symbol"] = spec.name
    metrics["spec"] = {
        "digits": spec.digits,
        "point": spec.point,
        "contract_size": spec.contract_size,
        "tick_size": spec.tick_size,
        "tick_value": spec.tick_value,
        "volume_min": spec.volume_min,
        "volume_step": spec.volume_step,
        "money_per_price": spec.money_per_price,
        "note": "допущение Exness Standard, не выгрузка SymbolInfo",
    }
    metrics["costs"] = {
        "latency_ms": args.latency_ms,
        "spread_addon": args.spread_addon,
        "spread_multiplier": args.spread_multiplier,
        "price_offset": args.price_offset,
        "swap_long_per_lot": args.swap_long,
        "swap_short_per_lot": args.swap_short,
        "commission_per_lot_side": -abs(args.commission_per_lot_side),
    }
    metrics["strategy_counts"] = result.strategy_counts
    metrics["rejected"] = result.rejected
    metrics["open_positions"] = len(result.open_positions)
    metrics["tick_count"] = result.tick_count
    metrics["last_time"] = None if result.last_time_msc is None else _iso(result.last_time_msc)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    _write_trades(out / "trades.csv", result.trades)
    _write_equity(out / "equity.csv", result.equity_curve)
    (out / "metrics.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    text = format_metrics_ru(metrics)
    (out / "summary.txt").write_text(text, encoding="utf-8")
    print(text, end="")
    print(f"Последний тик: {metrics['last_time']}. Открытых на конце: {metrics['open_positions']}.")
    print(f"Файлы: {out}")
    return 0


def _cmd_compare(args: argparse.Namespace) -> int:
    start = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc) if args.start else None
    end = None
    if args.end:
        end = datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
        if end > HOLDOUT_START and not args.allow_holdout:
            raise SystemExit("Отказ: окно сверки захватывает холдаут с 2026-10-16.")
    report = compare_trades(
        load_our_csv(args.ours),
        load_mt5(args.mt5),
        start=start,
        end=end,
        entry_pair_sec=args.entry_pair_sec,
        entry_time_sec=args.entry_time_sec,
        exit_time_sec=args.exit_time_sec,
        price_tol=args.price_tol,
        pair_price_tol=args.pair_price_tol,
    )
    printable = {k: v for k, v in report.items() if k not in ("pairs", "ours_only_trades", "mt5_only_trades")}
    text = json.dumps(printable, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"Пар: {report['paired']}, из них без расхождений: {report['exact']}, "
        f"с причинами: {report['paired_with_mismatch']}. "
        f"Только у нас: {report['ours_only']}. Только в MT5: {report['mt5_only']}."
    )
    shown = 0
    for row in report["pairs"]:
        if row["match"]:
            continue
        print(
            f"  {row['mt5']['entry_time']} {row['mt5']['side']} "
            f"причины={','.join(row['reasons'])} "
            f"dPвх={row['entry_price_delta']:.3f} dPвых={row['exit_price_delta']:.3f} "
            f"dTвх={row['entry_time_delta_sec']:.1f}s"
        )
        shown += 1
        if shown >= 15:
            break
    return 0 if report["mt5"] == 0 or report["paired"] else 0


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Тиковый бэктестер XAUUSD, независимый от MT5")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("alchemist", help="прогон порта h1-x12-st")
    run.add_argument("--ticks", nargs="+", required=True)
    run.add_argument("--source", choices=("exness", "dukascopy"), default="exness")
    run.add_argument("--to", required=True, help="последний день включительно, YYYY-MM-DD")
    run.add_argument("--trade-from", default=None, help="с этого дня можно открывать сделки")
    run.add_argument("--data-from", default=None, help="тики раньше этой даты не читать")
    run.add_argument("--deposit", type=float, default=10_000.0)
    run.add_argument("--leverage", type=float, default=2000.0)
    run.add_argument("--latency-ms", type=int, default=200)
    run.add_argument("--limit-penetration", type=float, default=0.01)
    run.add_argument("--spread-addon", type=float, default=0.0)
    run.add_argument("--spread-multiplier", type=float, default=1.0)
    run.add_argument("--price-offset", type=float, default=0.0)
    run.add_argument("--swap-long", type=float, default=0.0, help="USD на 1 лот за ночь, знак MT5")
    run.add_argument("--swap-short", type=float, default=0.0)
    run.add_argument("--triple-swap-weekday", type=int, default=2, help="0=пн … 2=ср")
    run.add_argument("--commission-per-lot-side", type=float, default=0.0, help="положительное число вычитается")
    run.add_argument("--risk-basis", choices=("balance", "equity"), default=None)
    run.add_argument("--warmup-m1", default=None, help="CSV M1 bid для прогрева баров до тиков")
    run.add_argument("--bootstrap", type=int, default=2000)
    run.add_argument("--seed", type=int, default=1)
    run.add_argument("--no-close-at-end", action="store_true")
    run.add_argument("--allow-holdout", action="store_true")
    run.add_argument("--out", required=True)
    run.set_defaults(func=_cmd_alchemist)

    cmp = sub.add_parser("compare", help="сверка trades.csv с HTML/JSON MT5")
    cmp.add_argument("--ours", required=True)
    cmp.add_argument("--mt5", required=True)
    cmp.add_argument("--start", default=None)
    cmp.add_argument("--end", default=None, help="последний день включительно")
    cmp.add_argument("--entry-pair-sec", type=float, default=180.0)
    cmp.add_argument("--entry-time-sec", type=float, default=2.0)
    cmp.add_argument("--exit-time-sec", type=float, default=5.0)
    cmp.add_argument("--price-tol", type=float, default=0.05)
    cmp.add_argument("--pair-price-tol", type=float, default=3.0)
    cmp.add_argument("--allow-holdout", action="store_true")
    cmp.add_argument("--out", default=None)
    cmp.set_defaults(func=_cmd_compare)

    args = parser.parse_args(argv)
    raise SystemExit(args.func(args))
