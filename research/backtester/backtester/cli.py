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

from .bars import BarBuilder, aggregate_bars
from .compare import compare_trades, load_mt5, load_our_csv, tolerance_profile
from .dukascopy_bars import (
    cut_before_live,
    estimate_bid_offset,
    in_session,
    load_m1_tree,
    shift_bars,
)
from .engine import Engine, EngineConfig
from .metrics import compute_metrics, format_metrics_ru
from .session import ExnessGoldSession
from .strategies.alchemist import AlchemistConfig, AlchemistStrategy, h1_x12_st
from .symbol_spec import CapturedSymbol, load_xauusdm
from .ticks import iter_ticks
from .types import Bar, Trade

HOLDOUT_START = datetime(2026, 10, 16, tzinfo=timezone.utc)
HOLDOUT_MSC = int(HOLDOUT_START.timestamp() * 1000)


def _day_start(text: str) -> int:
    dt = datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def _day_end_exclusive(text: str) -> int:
    dt = datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
    return int(dt.timestamp() * 1000)


def _period_of(bar: Bar) -> int:
    from .bars import TF_MS

    return TF_MS[bar.tf]


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
                Bar("M1", time_msc, bid_o, bid_h, bid_l, bid_c, bid_o, bid_h, bid_l, bid_c, 1, 0.0, "csv")
            )
    closed = [bar for bar in bars if bar.time_msc + TF_MS["M1"] <= before_msc]
    return closed


def _median(values: list[float]) -> float:
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def _d1_history_note(engine, warmup_m1: list[Bar], trade_from: int | None, end_msc: int) -> dict:
    """Сколько фильтров D1 меняет прогрев и насколько OHLC Dukascopy расходится с Exness.

    Пересечение — только сутки до конца прогона. Холдаут сюда не входит:
    вызывающий уже отрезал тики.
    """
    from .structure import d1_trend

    d1 = list(engine.bars.closed.get("D1", []))
    h1 = list(engine.bars.closed.get("H1", []))
    period = _period_of(h1[0]) if h1 else 3_600_000
    live = [bar for bar in d1 if bar.source != "dukascopy"]
    flips: list[str] = []
    checked = 0
    for bar in h1:
        as_of = bar.time_msc + period
        if trade_from is not None and as_of < trade_from:
            continue
        if as_of >= end_msc:
            continue
        checked += 1
        if d1_trend(d1, as_of, "structure", 5) != d1_trend(live, as_of, "structure", 5):
            flips.append(_iso(as_of))
    duka_d1 = {bar.time_msc: bar for bar in aggregate_bars(warmup_m1, "D1")}
    overlap_close: list[float] = []
    overlap_high: list[float] = []
    overlap_low: list[float] = []
    replaced: list[Bar] = []
    for bar in d1:
        other = duka_d1.get(bar.time_msc)
        if other is None or bar.source == "dukascopy":
            replaced.append(bar)
            continue
        if bar.time_msc >= end_msc:
            replaced.append(bar)
            continue
        overlap_close.append(abs(bar.close - other.close))
        overlap_high.append(abs(bar.high - other.high))
        overlap_low.append(abs(bar.low - other.low))
        replaced.append(other)
    ohlc_flips: list[str] = []
    if overlap_close:
        for bar in h1:
            as_of = bar.time_msc + period
            if trade_from is not None and as_of < trade_from:
                continue
            if as_of >= end_msc:
                continue
            if d1_trend(d1, as_of, "structure", 5) != d1_trend(replaced, as_of, "structure", 5):
                ohlc_flips.append(_iso(as_of))
    return {
        "d1_bars": len(d1),
        "d1_dukascopy": sum(1 for bar in d1 if bar.source == "dukascopy"),
        "d1_live": len(live),
        "h1_checked": checked,
        "trend_flips_vs_live_only": len(flips),
        "flip_asof": flips,
        "overlap_days": len(overlap_close),
        "overlap_median_abs_close": None if not overlap_close else _median(overlap_close),
        "overlap_median_abs_high": None if not overlap_high else _median(overlap_high),
        "overlap_median_abs_low": None if not overlap_low else _median(overlap_low),
        "trend_flips_if_overlap_uses_dukascopy": len(ohlc_flips),
        "ohlc_flip_asof": ohlc_flips,
    }


def _session(args: argparse.Namespace, captured: CapturedSymbol) -> ExnessGoldSession:
    ranges = captured.quote_ranges if args.session_gate == "quote" else captured.trade_ranges
    return ExnessGoldSession(shift=args.session_shift, ranges=ranges, gate=args.session_gate)


def _swap_from_args(args: argparse.Namespace, captured: CapturedSymbol) -> dict:
    """Пропущенная ставка берётся из пунктов спецификации. Явная — как передали.

    --triple-swap-weekday возвращает старую схему 1/3 и отключает таблицу файла.
    """
    long_rate = captured.swap_long_per_lot if args.swap_long is None else args.swap_long
    short_rate = captured.swap_short_per_lot if args.swap_short is None else args.swap_short
    if args.triple_swap_weekday is None:
        return {
            "swap_long_per_lot": long_rate,
            "swap_short_per_lot": short_rate,
            "triple_swap_weekday": captured.triple_swap_weekday,
            "swap_multipliers": captured.swap_multipliers,
            "swap_schedule": "symbol-spec",
            "swap_clock": args.swap_clock,
        }
    return {
        "swap_long_per_lot": long_rate,
        "swap_short_per_lot": short_rate,
        "triple_swap_weekday": args.triple_swap_weekday,
        "swap_multipliers": None,
        "swap_schedule": "triple-weekday",
        "swap_clock": args.swap_clock,
    }


def _cmd_alchemist(args: argparse.Namespace) -> int:
    end_msc = _day_end_exclusive(args.to)
    _refuse_holdout(end_msc, args.allow_holdout)
    trade_from = _day_start(args.trade_from) if args.trade_from else _day_start(args.data_from) if args.data_from else None
    data_from = _day_start(args.data_from) if args.data_from else None
    if trade_from is not None and trade_from >= HOLDOUT_MSC and not args.allow_holdout:
        raise SystemExit("Отказ: trade-from попадает в холдаут с 2026-10-16.")
    captured = load_xauusdm(leverage=args.leverage)
    spec = captured.spec
    costs = _swap_from_args(args, captured)
    session = _session(args, captured)
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
            swap_long_per_lot=costs["swap_long_per_lot"],
            swap_short_per_lot=costs["swap_short_per_lot"],
            triple_swap_weekday=costs["triple_swap_weekday"],
            swap_multipliers=costs["swap_multipliers"],
            swap_clock=costs["swap_clock"],
            trading_from_msc=trade_from,
            close_at_end=not args.no_close_at_end,
            sample_tf=cfg.timeframe,
            bar_source=args.source,
        ),
        strategy,
        session=session,
        max_risk_overshoot=cfg.max_risk_overshoot,
    )
    if args.warmup_m1 and args.warmup_dukascopy:
        raise SystemExit("Нужен один прогрев: --warmup-m1 или --warmup-dukascopy.")
    warmup_m1: list[Bar] = []
    warmup_note: dict | None = None
    if args.warmup_m1:
        before = data_from if data_from is not None else (trade_from or end_msc)
        seed = _load_warmup_m1(Path(args.warmup_m1), before)
        from .bars import TF_MS

        for tf in strategy.required_timeframes():
            period = TF_MS[tf]
            ready = [bar for bar in aggregate_bars(seed, tf) if bar.time_msc + period <= before]
            if ready:
                engine.bars.seed_closed(ready)
    elif args.warmup_dukascopy:
        if args.warmup_offset is None:
            raise SystemExit("Для прогрева Dukascopy нужен --warmup-offset (медиана с пересечения).")
        loaded = shift_bars(in_session(load_m1_tree(args.warmup_dukascopy), session), args.warmup_offset)
        warmup_m1 = loaded
        warmup_note = {
            "source": "dukascopy",
            "offset": args.warmup_offset,
            "m1": len(loaded),
            "method": (
                "Медиана (M1 bid close Exness − M1 bid close Dukascopy) на общих минутах "
                "пересечения. OHLC прогрева сдвинуты на эту величину. Торговля по прогреву не идёт."
            ),
        }
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
        seeded = False
        for tick in ticks:
            if not seeded and warmup_m1:
                counts = {}
                for tf in strategy.required_timeframes():
                    ready = cut_before_live(aggregate_bars(warmup_m1, tf), tick.time_msc, engine.session)
                    engine.bars.seed_closed(ready)
                    counts[tf] = {
                        "bars": len(ready),
                        "first": _iso(ready[0].time_msc),
                        "last_close": _iso(ready[-1].time_msc + _period_of(ready[-1])),
                        "source": ready[0].source,
                    }
                if warmup_note is not None:
                    warmup_note["bars"] = counts
                    warmup_note["first_tick"] = _iso(tick.time_msc)
                seeded = True
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
        "path": captured.path,
        "captured_at": captured.captured_at,
        "captured_date": captured.captured_date,
        "digits": spec.digits,
        "point": spec.point,
        "contract_size": spec.contract_size,
        "tick_size": spec.tick_size,
        "tick_value": spec.tick_value,
        "volume_min": spec.volume_min,
        "volume_max": spec.volume_max,
        "volume_step": spec.volume_step,
        "stops_level": spec.stops_level,
        "freeze_level": spec.freeze_level,
        "money_per_price": spec.money_per_price,
        "swap_mode": captured.swap_mode,
        "swap_long_points": captured.swap_long_points,
        "swap_short_points": captured.swap_short_points,
        "swap_rollover3days": captured.swap_rollover3days,
        "session_gate": args.session_gate,
        "session_shift": args.session_shift,
        "note": (
            "выгрузка терминала 2026-10-24, летнее время США; "
            "зимние окна сессии могут сдвинуться на час, см. session_shift"
        ),
    }
    metrics["costs"] = {
        "latency_ms": args.latency_ms,
        "spread_addon": args.spread_addon,
        "spread_multiplier": args.spread_multiplier,
        "price_offset": args.price_offset,
        "swap_long_per_lot": costs["swap_long_per_lot"],
        "swap_short_per_lot": costs["swap_short_per_lot"],
        "swap_long_points": captured.swap_long_points,
        "swap_short_points": captured.swap_short_points,
        "swap_schedule": costs["swap_schedule"],
        "swap_clock": costs["swap_clock"],
        "triple_swap_weekday": costs["triple_swap_weekday"],
        "commission_per_lot_side": -abs(args.commission_per_lot_side),
    }
    if warmup_note is not None:
        warmup_note["d1"] = _d1_history_note(engine, warmup_m1, trade_from, end_msc)
        metrics["warmup"] = warmup_note
    metrics["strategy_counts"] = result.strategy_counts
    if hasattr(strategy, "decisions"):
        metrics["decisions"] = [
            {"time": _iso(row["time_msc"]), "event": row["event"], "sig": row["sig"], "day": row["day"]}
            for row in strategy.decisions
        ]
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


def _compare_kwargs(args: argparse.Namespace, profile: str | None) -> dict:
    if profile:
        chosen = tolerance_profile(profile)
        return chosen
    return {
        "entry_pair_sec": args.entry_pair_sec,
        "entry_time_sec": args.entry_time_sec,
        "exit_time_sec": args.exit_time_sec,
        "price_tol": args.price_tol,
        "pair_price_tol": args.pair_price_tol,
    }


def _cmd_compare(args: argparse.Namespace) -> int:
    start = datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=timezone.utc) if args.start else None
    end = None
    if args.end:
        end = datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=timezone.utc) + timedelta(days=1)
        if end > HOLDOUT_START and not args.allow_holdout:
            raise SystemExit("Отказ: окно сверки захватывает холдаут с 2026-10-16.")
    ours = load_our_csv(args.ours)
    mt5 = load_mt5(args.mt5)
    names = ["strict", "aligned"] if args.profile == "both" else [args.profile]
    reports = {}
    for name in names:
        report = compare_trades(ours, mt5, start=start, end=end, **_compare_kwargs(args, name))
        if name:
            report["profile"] = name
        reports[name or "custom"] = report
    report = reports[names[-1] or "custom"] if len(reports) == 1 else None
    payload = reports if len(reports) > 1 else next(iter(reports.values()))
    printable_one = payload if len(reports) == 1 else {
        name: {k: v for k, v in row.items() if k not in ("pairs", "ours_only_trades", "mt5_only_trades")}
        for name, row in reports.items()
    }
    if len(reports) == 1:
        printable_one = {k: v for k, v in payload.items() if k not in ("pairs", "ours_only_trades", "mt5_only_trades")}
    text = json.dumps(printable_one, ensure_ascii=False, indent=2)
    print(text)
    if args.out:
        Path(args.out).write_text(json.dumps(payload if len(reports) == 1 else reports, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for name, row in reports.items():
        label = name or "custom"
        print(
            f"[{label}] Пар: {row['paired']}, без расхождений: {row['exact']}, "
            f"с причинами: {row['paired_with_mismatch']}. "
            f"Только у нас: {row['ours_only']}. Только в MT5: {row['mt5_only']}."
        )
        shown = 0
        for item in row["pairs"]:
            if item["match"]:
                continue
            print(
                f"  {item['mt5']['entry_time']} {item['mt5']['side']} "
                f"причины={','.join(item['reasons'])} "
                f"dPвх={item['entry_price_delta']:.3f} dPвых={item['exit_price_delta']:.3f} "
                f"dTвх={item['entry_time_delta_sec']:.1f}s"
            )
            shown += 1
            if shown >= 15:
                break
    return 0


def _cmd_offset(args: argparse.Namespace) -> int:
    """Медиана bid M1: Exness минус Dukascopy на пересечении, без холдаута."""
    start = _day_start(args.start)
    end = _day_end_exclusive(args.to)
    _refuse_holdout(end, args.allow_holdout)
    captured = load_xauusdm()
    session = _session(args, captured)
    duk = [bar for bar in in_session(load_m1_tree(args.dukascopy), session) if start <= bar.time_msc < end]
    builder = BarBuilder(["M1"], source="exness")
    for tick in iter_ticks(args.ticks, "exness", start_msc=start, end_msc=end):
        if tick.time_msc >= HOLDOUT_MSC and not args.allow_holdout:
            raise SystemExit("Отказ: в поток попал тик холдаута. Чтение остановлено.")
        builder.add(tick)
    exness = in_session(builder.closed["M1"], session)
    stats = estimate_bid_offset(exness, duk)
    stats["start"] = args.start
    stats["to"] = args.to
    stats["method"] = "median Exness M1 bid close minus Dukascopy M1 bid close, session minutes only"
    print(json.dumps(stats, ensure_ascii=False, indent=2))
    return 0


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
    run.add_argument(
        "--swap-long",
        type=float,
        default=None,
        help="USD на 1 лот за ночь, знак MT5; по умолчанию пункты из спецификации",
    )
    run.add_argument("--swap-short", type=float, default=None)
    run.add_argument(
        "--triple-swap-weekday",
        type=int,
        default=None,
        help="0=пн … 2=ср. Если задан, таблица множителей файла не используется",
    )
    run.add_argument(
        "--swap-clock",
        choices=("exness", "tester"),
        default="exness",
        help="exness — своп в 17:00 ET; tester — полночь UTC, как отчёт MT5",
    )
    run.add_argument(
        "--session-gate",
        choices=("quote", "trade"),
        default="quote",
        help="quote — открыто с 18:00 ET, первый тик после паузы уже торгуется; trade — номинальные 22:01 из дампа",
    )
    run.add_argument(
        "--session-shift",
        choices=("captured", "winter", "auto"),
        default="auto",
        help="auto — зима/лето по DST США; captured — окна дампа как есть; winter — всегда +1ч",
    )
    run.add_argument("--commission-per-lot-side", type=float, default=0.0, help="положительное число вычитается")
    run.add_argument("--risk-basis", choices=("balance", "equity"), default=None)
    run.add_argument("--warmup-m1", default=None, help="CSV M1 bid для прогрева баров до тиков")
    run.add_argument("--warmup-dukascopy", default=None, help="каталог YYYY/MM/DD.bi5, свечи BID M1")
    run.add_argument("--warmup-offset", type=float, default=None, help="сдвиг Dukascopy к уровню Exness, USD")
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
    cmp.add_argument(
        "--profile",
        choices=("strict", "aligned", "both"),
        default=None,
        help="strict: 2 с и 0.05; aligned: вход 5 с и 0.50 цены; both печатает оба",
    )
    cmp.add_argument("--allow-holdout", action="store_true")
    cmp.add_argument("--out", default=None)
    cmp.set_defaults(func=_cmd_compare)

    off = sub.add_parser("offset", help="медиана сдвига Exness − Dukascopy по M1 bid")
    off.add_argument("--dukascopy", required=True)
    off.add_argument("--ticks", nargs="+", required=True)
    off.add_argument("--start", required=True)
    off.add_argument("--to", required=True, help="последний день включительно")
    off.add_argument(
        "--session-gate",
        choices=("quote", "trade"),
        default="quote",
    )
    off.add_argument(
        "--session-shift",
        choices=("captured", "winter", "auto"),
        default="auto",
    )
    off.add_argument("--allow-holdout", action="store_true")
    off.set_defaults(func=_cmd_offset)

    args = parser.parse_args(argv)
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()
