"""Исполнение, лот, бары, спред, своп, метрики — на синтетике с известным ответом."""

from __future__ import annotations

import gzip
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from backtester.bars import BarBuilder
from backtester.costs import swap_charges
from backtester.engine import Engine, EngineConfig
from backtester.indicators import cci_at, hma_last_two, wilder_atr_last
from backtester.metrics import compute_metrics, longest_losing_streak
from backtester.protective import limit_hit, resolve_protective
from backtester.session import DAY_MS, ExnessGoldSession, weekday_mon0
from backtester.sizing import size_by_risk
from backtester.strategy import CallbackStrategy
from backtester.ticks import adjust_quote, iter_dukascopy_parquet, iter_exness_csv_gz
from backtester.types import SizingError, SymbolSpec, Tick, Trade, utc_from_msc


def spec(**kwargs) -> SymbolSpec:
    base = dict(
        name="T",
        digits=2,
        point=0.01,
        contract_size=1.0,
        tick_size=0.01,
        tick_value=1.0,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        adjusted_point=0.01,
        leverage=100.0,
    )
    base.update(kwargs)
    return SymbolSpec(**base)


def msc(y, m, d, hh=0, mm=0, ss=0, ms=0) -> int:
    moment = datetime(y, m, d, hh, mm, ss, ms * 1000, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000)


def T(time_msc, bid, ask, **kwargs) -> Tick:
    return Tick(time_msc, bid, ask, **kwargs)


def run(ticks, on_tick=None, on_bar=None, tfs=None, **cfg):
    symbol = cfg.pop("symbol", spec())
    engine = Engine(
        EngineConfig(symbol=symbol, **cfg),
        CallbackStrategy(tfs or ["M1"], on_tick=on_tick, on_bar=on_bar),
    )
    return engine.run(ticks)


def test_market_buy_fills_at_ask_sell_at_bid():
    state = {"n": 0}

    def on_tick(ctx, tick):
        state["n"] += 1
        if state["n"] == 1:
            ctx.buy_market(1, sl=50, tp=None)
        elif state["n"] == 2:
            ctx.sell_market(1, sl=200, tp=None)

    # Вторая заявка откроет ещё одну позицию: проверяем цены входа по отдельности,
    # поэтому второй вызов — после закрытия.
    def on_tick_seq(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_market(1, sl=50, tp=150)
        if tick.time_msc == 2_000 and ctx.position:
            ctx.close_position("flat")
        if tick.time_msc == 3_000 and ctx.position is None:
            ctx.sell_market(1, sl=200, tp=50)
        if tick.time_msc == 4_000 and ctx.position:
            ctx.close_position("flat")

    ticks = [
        T(1_000, 100, 100.2),
        T(2_000, 101, 101.2),
        T(3_000, 102, 102.3),
        T(4_000, 103, 103.3),
    ]
    result = run(ticks, on_tick=on_tick_seq, deposit=10_000)
    assert len(result.trades) == 2
    buy, sell = result.trades
    assert buy.side == 1 and buy.entry_price == pytest.approx(100.2)
    assert buy.exit_price == pytest.approx(101)  # закрытие лонга по bid
    assert sell.side == -1 and sell.entry_price == pytest.approx(102)
    assert sell.exit_price == pytest.approx(103.3)  # закрытие шорта по ask


def test_latency_uses_later_tick():
    def on_tick(ctx, tick):
        if tick.time_msc == 0:
            ctx.buy_market(1, sl=1, tp=None)

    ticks = [T(0, 10, 10.1), T(400, 11, 11.1), T(500, 12, 12.1), T(800, 12, 12.1)]
    result = run(ticks, on_tick=on_tick, latency_ms=500)
    # На 800 мс позиция ещё открыта: закрываем проверкой цены входа.
    assert result.trades == []
    assert result.open_positions[0]["entry_price"] == pytest.approx(12.1)
    assert result.open_positions[0]["entry_time_msc"] == 500


def test_limit_not_on_first_touch_and_gap_fills_at_limit():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_limit(1, 99.0, sl=90, tp=110, penetration=0.10)

    ticks = [
        T(1_000, 99.8, 100.0),
        T(2_000, 98.8, 99.0),   # касание лимита, 99 <= 98.9? нет
        T(3_000, 98.6, 98.85),  # прошли на 0.15 > 0.10, но гэпом лучше лимита
    ]
    result = run(ticks, on_tick=on_tick, limit_penetration=0.10)
    assert len(result.open_positions) == 1
    assert result.open_positions[0]["entry_price"] == pytest.approx(99.0)
    assert result.trades == []


def test_limit_expires_before_it_can_fill():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_limit(1, 99.0, sl=90, tp=110, expiry_msc=2_000, penetration=0.10)

    ticks = [
        T(1_000, 99.8, 100.0),
        T(2_000, 98.6, 98.85),  # срок уже наступил — не исполняем
    ]
    result = run(ticks, on_tick=on_tick)
    assert result.open_positions == []
    assert "expired:1" in result.rejected


def test_stop_entry_gaps_to_worse_price():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_stop(1, 105, sl=90, tp=140)

    ticks = [T(1_000, 99, 100), T(2_000, 129, 130)]
    result = run(ticks, on_tick=on_tick)
    assert result.open_positions[0]["entry_price"] == pytest.approx(130)


def test_sl_gap_fills_at_next_price_not_at_level():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_market(1, sl=95, tp=150)

    ticks = [T(1_000, 100, 100.2), T(2_000, 90, 90.2)]
    result = run(ticks, on_tick=on_tick)
    assert len(result.trades) == 1
    trade = result.trades[0]
    assert trade.exit_reason == "sl"
    assert trade.exit_price == pytest.approx(90)
    assert trade.ambiguous_sl_tp is False
    #  (90 - 100.2) * 1 * 100 = -1020, не -520 (если бы закрыли по 95)
    assert trade.gross_pnl == pytest.approx(-1020)


def test_tp_fills_at_tp_not_beyond():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_market(1, sl=50, tp=110)

    ticks = [T(1_000, 100, 100.2), T(2_000, 130, 130.2)]
    result = run(ticks, on_tick=on_tick)
    assert result.trades[0].exit_reason == "tp"
    assert result.trades[0].exit_price == pytest.approx(110)


def test_same_timestamp_sl_and_tp_takes_stop():
    fired = {"done": False}

    def on_tick(ctx, tick):
        if not fired["done"]:
            ctx.buy_market(1, sl=95, tp=105)
            fired["done"] = True

    ticks = [
        T(5_000, 100, 100.1),
        T(5_000, 110, 110.1),
        T(5_000, 90, 90.1),
    ]
    result = run(ticks, on_tick=on_tick)
    assert len(result.trades) == 1
    trade = result.trades[0]
    assert trade.exit_reason == "sl"
    assert trade.ambiguous_sl_tp is True
    assert trade.exit_price == pytest.approx(90)


def test_resolve_segment_both_levels_is_stop():
    hit = resolve_protective(1, 120.0, [80.0], sl=95.0, tp=110.0)
    assert hit is not None
    reason, price, ambiguous = hit
    assert reason == "sl" and ambiguous and price == pytest.approx(80)


def test_limit_hit_requires_penetration():
    assert limit_hit(1, 99.0, 99.0, 0.10) is False
    assert limit_hit(1, 98.89, 99.0, 0.10) is True
    assert limit_hit(-1, 101.0, 101.0, 0.10) is False
    assert limit_hit(-1, 101.11, 101.0, 0.10) is True


def test_bars_are_bid_causal_and_skip_empty_minutes():
    builder = BarBuilder(["M1"])
    base = msc(2026, 6, 2, 10, 0, 0)
    builder.add(T(base, 10, 10.5))
    builder.add(T(base + 30_000, 12, 12.5))
    closed = builder.add(T(base + 120_000, 99, 99.5))
    assert len(closed) == 1
    bar = closed[0]
    assert bar.high == pytest.approx(12)
    assert bar.close == pytest.approx(12)
    assert bar.ask_high == pytest.approx(12.5)
    assert bar.time_msc == base
    # Минута 10:01 без тиков не создана, следующий бар — 10:02.
    assert builder.forming_open("M1") == base + 120_000


def test_d1_uses_utc_midnight():
    builder = BarBuilder(["D1"])
    sunday = msc(2026, 1, 4, 23, 0, 0)  # воскресенье
    monday = msc(2026, 1, 5, 0, 0, 1)
    closed = builder.add(T(sunday, 10, 10.1))
    assert closed == []
    closed = builder.add(T(monday, 11, 11.1))
    assert len(closed) == 1
    assert utc_from_msc(closed[0].time_msc) == datetime(2026, 1, 4, tzinfo=timezone.utc)


def test_spread_adjustment_formula():
    bid, ask = adjust_quote(100, 100.4, price_offset=0.2, spread_multiplier=2, spread_addon=0.2)
    assert bid == pytest.approx(99.9)
    assert ask == pytest.approx(100.9)
    assert ask - bid == pytest.approx(0.4 * 2 + 0.2)


def test_sizing_known_lot_floor_and_fail_closed():
    lot = size_by_risk(
        10_000, 1.0, 10.0,
        tick_size=0.01, tick_value=1.0,
        volume_min=0.01, volume_max=100, volume_step=0.01,
    )
    assert lot == pytest.approx(0.1)
    raw = size_by_risk(
        10_000, 1.0, (100 / 0.019) * 0.01,
        tick_size=0.01, tick_value=1.0,
        volume_min=0.01, volume_max=100, volume_step=0.01,
        max_risk_overshoot=0,
    )
    assert raw == pytest.approx(0.01)
    skipped = size_by_risk(
        10_000, 1.0, 50.0,
        tick_size=0.01, tick_value=1.0,
        volume_min=0.01, volume_max=100, volume_step=0.01,
        max_risk_overshoot=1.5,
    )
    # money/lot = 5000, мин. лот рискует 50 > 100*1.5? 50 < 150, лот = 100/5000 = 0.02
    assert skipped == pytest.approx(0.02)
    blocked = size_by_risk(
        10_000, 1.0, 5_000,
        tick_size=0.01, tick_value=1.0,
        volume_min=0.01, volume_max=100, volume_step=0.01,
    )
    assert blocked == 0.0
    with pytest.raises(SizingError):
        size_by_risk(10_000, -1, 10, tick_size=0.01, tick_value=1, volume_min=0.01, volume_max=1, volume_step=0.01)
    with pytest.raises(SizingError):
        size_by_risk(10_000, 1, 0, tick_size=0.01, tick_value=1, volume_min=0.01, volume_max=1, volume_step=0.01)
    with pytest.raises(SizingError):
        size_by_risk(10_000, 1, 10, tick_size=0, tick_value=1, volume_min=0.01, volume_max=1, volume_step=0.01)
    with pytest.raises(SizingError):
        size_by_risk(float("nan"), 1, 10, tick_size=0.01, tick_value=1, volume_min=0.01, volume_max=1, volume_step=0.01)


def test_equity_dd_deeper_than_balance_dd():
    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_market(1, sl=1, tp=None)
        if tick.time_msc == 3_000:
            ctx.close_position("flat")

    ticks = [T(1_000, 99.8, 100), T(2_000, 90, 90.2), T(3_000, 100, 100.2)]
    result = run(ticks, on_tick=on_tick, deposit=10_000)
    assert result.drawdown.max_balance_dd_money == pytest.approx(0)
    assert result.drawdown.max_equity_dd_money == pytest.approx(1000)
    assert result.trades[0].net_pnl == pytest.approx(0)


def test_exness_swap_is_charged_at_17et_inside_the_break():
    # Среда 19 августа 2026, летнее время: 17:00 ET = 21:00 UTC, множитель 3.
    summer = swap_charges(
        msc(2026, 8, 19, 12),
        msc(2026, 8, 20, 2),
        msc(2026, 8, 19, 12),
        0,
        clock="exness",
    )
    assert summer == [(msc(2026, 8, 19, 21), 3)]
    # Вход после 17:00 ET эту ночь уже не платит.
    late = swap_charges(
        msc(2026, 8, 19, 21, 30),
        msc(2026, 8, 20, 2),
        msc(2026, 8, 19, 21, 30),
        0,
        clock="exness",
    )
    assert late == []
    # Среда 14 января 2026, зима: 17:00 ET = 22:00 UTC.
    winter = swap_charges(
        msc(2026, 1, 14, 12),
        msc(2026, 1, 15, 2),
        msc(2026, 1, 14, 12),
        0,
        clock="exness",
    )
    assert winter == [(msc(2026, 1, 14, 22), 3)]
    # Пятница–понедельник: одна ночь в пятницу 21:00 UTC, понедельник 17:00 ещё впереди.
    weekend = swap_charges(
        msc(2026, 8, 14, 12),
        msc(2026, 8, 17, 12),
        msc(2026, 8, 14, 12),
        0,
        clock="exness",
    )
    assert weekend == [(msc(2026, 8, 14, 21), 1)]


def test_swap_wednesday_triple_and_weekend_once():
    # Среда 19 августа 2026, 12:00 → четверг 02:00: одна тройная ночь.
    charges = swap_charges(
        msc(2026, 8, 19, 12),
        msc(2026, 8, 20, 2),
        msc(2026, 8, 19, 12),
        0,
    )
    assert charges == [(msc(2026, 8, 20, 0), 3)]
    weekend = swap_charges(
        msc(2026, 8, 14, 12),  # пятница
        msc(2026, 8, 17, 12),  # понедельник
        msc(2026, 8, 14, 12),
        0,
    )
    assert weekend == [(msc(2026, 8, 15, 0), 1)]

    def on_tick(ctx, tick):
        if tick.time_msc == msc(2026, 8, 19, 12):
            ctx.buy_market(0.01, sl=1, tp=None)

    ticks = [T(msc(2026, 8, 19, 12), 100, 100.1), T(msc(2026, 8, 20, 2), 100, 100.1)]
    result = run(ticks, on_tick=on_tick, swap_long_per_lot=-52.0, deposit=10_000)
    assert result.open_positions[0]["swap"] == pytest.approx(-1.56)


def test_quote_session_matches_june_ticks_and_mt5_fills():
    """По умолчанию пауза 16:58–18:00 ET и сдвиг auto. Летом 22:00:30 UTC уже открыт."""
    session = ExnessGoldSession()
    assert session.gate == "quote"
    assert session.shift == "auto"
    assert session.is_open(msc(2026, 6, 8, 20, 57))
    assert not session.is_open(msc(2026, 6, 8, 20, 58))
    assert not session.is_open(msc(2026, 6, 8, 21, 59))
    assert session.is_open(msc(2026, 6, 8, 22, 0, 30))
    assert session.is_open(msc(2026, 6, 15, 0, 0))
    # Воскресенье 2 августа: отчёт закрывает сделку в 22:03:34, это после 18:00 ET.
    assert not session.is_open(msc(2026, 8, 2, 21, 59))
    assert session.is_open(msc(2026, 8, 2, 22, 3, 34))
    assert session.is_open(msc(2026, 6, 12, 20, 57))
    assert not session.is_open(msc(2026, 6, 12, 20, 58))
    assert not session.is_open(msc(2026, 6, 13, 12))
    # Зима того же правила: 18:00 ET = 23:00 UTC. Номинальные 22:01 UTC ещё пауза.
    assert not session.is_open(msc(2026, 1, 15, 21, 58))
    assert not session.is_open(msc(2026, 1, 15, 22, 1))
    assert not session.is_open(msc(2026, 1, 15, 22, 59))
    assert session.is_open(msc(2026, 1, 15, 23, 1))
    known = datetime(2026, 1, 15, tzinfo=timezone.utc)
    assert weekday_mon0(int(known.timestamp() * 1000)) == known.weekday()


def test_trade_session_stays_closed_through_the_first_reopen_minute():
    trade = ExnessGoldSession(gate="trade")
    assert trade.gate == "trade"
    assert not trade.is_open(msc(2026, 6, 8, 22, 0, 30))
    assert trade.is_open(msc(2026, 6, 8, 22, 1))
    assert not trade.is_open(msc(2026, 8, 2, 22, 3, 34))
    assert not trade.is_open(msc(2026, 6, 14, 22, 4))
    assert trade.is_open(msc(2026, 6, 14, 22, 5))


def test_session_winter_shift_moves_halt_edges_only():
    winter = ExnessGoldSession(shift="winter")
    assert winter.is_open(msc(2026, 1, 15, 0, 0))
    assert winter.is_open(msc(2026, 1, 15, 21, 57))
    assert not winter.is_open(msc(2026, 1, 15, 21, 58))
    assert not winter.is_open(msc(2026, 1, 15, 22, 59))
    assert winter.is_open(msc(2026, 1, 15, 23, 0))
    assert not winter.is_open(msc(2026, 1, 18, 22, 59))
    assert winter.is_open(msc(2026, 1, 18, 23, 0))
    assert winter.is_open(msc(2026, 1, 16, 21, 57))
    assert not winter.is_open(msc(2026, 1, 16, 21, 58))
    assert not winter.is_open(msc(2026, 1, 17, 12))

    trade_winter = ExnessGoldSession(shift="winter", gate="trade")
    assert not trade_winter.is_open(msc(2026, 1, 15, 23, 0))
    assert trade_winter.is_open(msc(2026, 1, 15, 23, 1))
    assert not trade_winter.is_open(msc(2026, 1, 18, 23, 4))
    assert trade_winter.is_open(msc(2026, 1, 18, 23, 5))

    auto = ExnessGoldSession(shift="auto")
    assert not auto.is_open(msc(2026, 1, 15, 22, 30))
    assert auto.is_open(msc(2026, 1, 15, 23, 30))
    assert not auto.is_open(msc(2026, 6, 15, 21, 30))
    assert auto.is_open(msc(2026, 6, 15, 22, 30))
    assert auto.is_open(msc(2026, 3, 6, 21, 30))
    assert not auto.is_open(msc(2026, 3, 6, 21, 58))
    assert not auto.is_open(msc(2026, 3, 9, 20, 58))
    assert auto.is_open(msc(2026, 3, 9, 22, 1))


def test_indicators_hand_values():
    pair = hma_last_two([1, 2, 3, 4, 5, 6, 7, 8, 9], 4)
    assert pair is not None
    assert pair[0] == pytest.approx(9)
    assert pair[1] == pytest.approx(8)
    cci = cci_at([1, 2, 3], [1, 2, 3], [1, 2, 3], 2, 3)
    assert cci == pytest.approx(100)
    assert cci_at([1, 1], [1, 1], [1, 1], 1, 2) is None
    highs = [10, 12, 11, 14, 13]
    lows = [8, 9, 10, 10, 12]
    closes = [10, 11, 10.5, 13, 12.5]
    atr = wilder_atr_last(highs, lows, closes, 3)
    # TR со второго бара: 3, 1, 4, потом 1. Посев (3+1+4)/3, дальше (8/3*2+1)/3
    assert atr == pytest.approx((8 / 3 * 2 + 1) / 3)


def test_losing_streak_and_bootstrap_contains_point():
    def fake(net, r, i):
        return Trade(
            id=i, side=1, volume=1, entry_time_msc=i, exit_time_msc=i, entry_price=1, exit_price=1,
            sl=0.5, tp=None, initial_sl=0.5, exit_reason="x", gross_pnl=net, commission=0, swap=0,
            net_pnl=net, initial_risk=1, r_multiple=r, entry_spread=0, exit_spread=0, comment="",
        )

    trades = [fake(-1, -1, 1), fake(-1, -1, 2), fake(1, 1, 3), fake(-1, -1, 4), fake(-1, -1, 5), fake(-1, -1, 6)]
    assert longest_losing_streak(trades) == 3
    from backtester.types import Drawdown
    metrics = compute_metrics(trades, Drawdown(), deposit=1000, bootstrap=300, seed=1)
    assert metrics["trades"] == 6
    assert metrics["avg_r"] == pytest.approx(sum(t.r_multiple for t in trades) / 6)
    low = metrics["bootstrap"]["avg_r_ci95"]["low"]
    high = metrics["bootstrap"]["avg_r_ci95"]["high"]
    assert low <= metrics["avg_r"] <= high
    assert "просадка по балансу" in metrics["drawdown_labels"]["max_drawdown_balance_money"]
    assert "просадка по средствам" in metrics["drawdown_labels"]["max_drawdown_equity_money"]


def test_exness_and_parquet_adapters(tmp_path: Path):
    csv_path = tmp_path / "ticks.csv.gz"
    with gzip.open(csv_path, "wt", newline="") as fh:
        fh.write("time_msc,bid,ask,last,volume,volume_real,flags\n")
        fh.write("1000,10,10.2,0,1,0,0\n")
        fh.write("1000,10.1,10.3,0,2,0,0\n")
    ticks = list(iter_exness_csv_gz(csv_path))
    assert len(ticks) == 2
    assert ticks[1].bid == pytest.approx(10.1)

    pyarrow = pytest.importorskip("pyarrow")
    import pyarrow.parquet as pq

    table = pyarrow.table(
        {
            "time_msc": [2000, 3000],
            "bid": [11.0, 12.0],
            "ask": [11.2, 12.2],
            "bid_vol": [1.0, 1.0],
            "ask_vol": [2.0, 2.0],
        }
    )
    parquet_path = tmp_path / "xau.parquet"
    pq.write_table(table, parquet_path, compression="zstd")
    got = list(iter_dukascopy_parquet(parquet_path))
    assert [t.time_msc for t in got] == [2000, 3000]
    assert got[0].ask_vol == pytest.approx(2)


def test_unsorted_ticks_fail(tmp_path: Path):
    csv_path = tmp_path / "bad.csv.gz"
    with gzip.open(csv_path, "wt", newline="") as fh:
        fh.write("time_msc,bid,ask\n2,10,10.1\n1,10,10.1\n")
    with pytest.raises(Exception):
        list(iter_exness_csv_gz(csv_path))


def test_crossed_quote_fails():
    with pytest.raises(Exception):
        Tick(1, 10.2, 10.0)
