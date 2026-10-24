"""Порт h1-x12-st на синтетике: сигнал только по закрытому бару, возраст, H4, D1."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from backtester.engine import Engine, EngineConfig
from backtester.session import ExnessGoldSession
from backtester.strategies.alchemist import AlchemistConfig, AlchemistStrategy, bar_age
from backtester.structure import _Day, ema_trend, merged_d1, structure_trend
from backtester.types import Bar, Tick, xauusd_exness

H1 = 3_600_000
H4 = 14_400_000


def msc(y, m, d, hh=0, mm=0, ss=0) -> int:
    moment = datetime(y, m, d, hh, mm, ss, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000)


def tick(time_msc: int, bid: float, spread: float = 0.2) -> Tick:
    return Tick(time_msc, bid, bid + spread)


def day_bar(time_msc: int, high: float, low: float, close: float) -> Bar:
    return Bar("D1", time_msc, close, high, low, close, close, high, low, close, 1, 0.0)


def h4_bar(time_msc: int, close: float = 1.0) -> Bar:
    return Bar("H4", time_msc, close, close, close, close, close, close, close, close, 1, 0.0)


class _Bars:
    def __init__(self, closed, forming):
        self._closed = closed
        self._forming = forming

    def bars(self, tf):
        return self._closed

    def forming_open_msc(self, tf):
        return self._forming


def _simple_config(**kwargs) -> AlchemistConfig:
    base = dict(
        ma_period=3,
        use_hma=False,
        use_cci=False,
        use_htf=False,
        day_trend="off",
        exit_bars=2,
        atr_period=3,
        stop_atr_mult=0.0001,
        min_sl_points=10_000,
        risk_percent=1.0,
    )
    base.update(kwargs)
    return AlchemistConfig(**base)


def test_signal_uses_closed_bar_and_exits_after_n_bars():
    """Час 4 закрывается в 110. Тик открытия часа 5 — 130 и в тот бар не входит.

    Вход по ask этого тика. Выход на открытии часа 7: возраст ровно ExitBars.
    Повторного входа нет: состояния двух последних часов совпадают.
    """
    base = msc(2026, 6, 1)
    ticks = []
    for hour, bid in ((0, 100), (1, 100), (2, 100), (3, 100), (4, 110)):
        ticks.append(tick(base + hour * H1, bid))
    ticks.append(tick(base + 5 * H1, 130))
    ticks.append(tick(base + 6 * H1 - 1000, 140))
    ticks.append(tick(base + 6 * H1, 140))
    ticks.append(tick(base + 7 * H1 - 1000, 150))
    ticks.append(tick(base + 7 * H1, 132))

    spec = xauusd_exness()
    strategy = AlchemistStrategy(_simple_config(), digits=spec.digits, adjusted_point=spec.adjusted_point)
    engine = Engine(
        EngineConfig(symbol=spec, deposit=10_000, latency_ms=0, close_at_end=False),
        strategy,
    )
    result = engine.run(ticks)

    closed = engine.bars.closed["H1"]
    hour4 = next(bar for bar in closed if bar.time_msc == base + 4 * H1)
    assert hour4.high == 110 and hour4.close == 110
    hour5 = next(bar for bar in closed if bar.time_msc == base + 5 * H1)
    assert hour5.high == 140 and hour5.open == 130

    assert len(result.trades) == 1
    trade = result.trades[0]
    assert trade.side == 1
    assert trade.entry_time_msc == base + 5 * H1
    assert trade.entry_price == 130.2
    assert trade.volume == 0.1
    assert trade.sl == 120.2
    assert trade.exit_time_msc == base + 7 * H1
    assert trade.exit_price == 132
    assert trade.exit_reason == "time"
    assert trade.gross_pnl == pytest.approx(18)
    assert trade.net_pnl == pytest.approx(18)
    assert trade.r_multiple == pytest.approx(0.18)
    assert trade.comment == "HAL"
    assert result.open_positions == []


def test_pending_signal_waits_for_session_and_is_not_cleared_by_flat_bar():
    """Пауза дампа закрывает 22:00. Сигнал, закрывшийся в этот тик, ждёт 23:00."""
    day = msc(2026, 1, 15)
    ticks = [tick(day + hour * H1, 100.0) for hour in range(0, 21)]
    ticks.append(tick(day + 21 * H1, 110.0))
    ticks.append(tick(day + 22 * H1, 110.0))
    ticks.append(tick(day + 23 * H1, 150.0))

    spec = xauusd_exness()
    strategy = AlchemistStrategy(
        _simple_config(ma_period=2, exit_bars=100),
        digits=spec.digits,
        adjusted_point=spec.adjusted_point,
    )
    engine = Engine(
        EngineConfig(symbol=spec, deposit=10_000, latency_ms=0, close_at_end=False),
        strategy,
        session=ExnessGoldSession(gate="trade", shift="captured"),
    )
    result = engine.run(ticks)
    assert result.trades == []
    assert len(result.open_positions) == 1
    pos = result.open_positions[0]
    assert pos["entry_time_msc"] == day + 23 * H1
    assert pos["entry_price"] == 150.2
    assert pos["side"] == 1
    assert pos["volume"] == 0.1
    assert strategy.counts.get("trades") == 1


def test_bar_age_matches_ibarshift():
    closed = [0, H1, 2 * H1]
    assert bar_age(closed, 3 * H1, H1, H1) == 2
    assert bar_age(closed, 3 * H1, 3 * H1, H1) == 0
    assert bar_age(closed, None, 0, H1) == 0


def test_htf_index_is_last_closed_before_signal_bar():
    base = msc(2026, 6, 1)
    closed = [h4_bar(base + i * H4) for i in range(3)]
    forming = base + 3 * H4
    strategy = AlchemistStrategy(AlchemistConfig())
    ctx = _Bars(closed, forming)
    assert strategy._htf_index(ctx, base + 13 * H1) == 2
    assert closed[2].time_msc == base + 2 * H4
    assert strategy._htf_index(ctx, base + 12 * H1) == 2


def test_sunday_merges_into_monday_and_drops_if_still_open():
    sunday = msc(2026, 6, 14)
    monday = msc(2026, 6, 15)
    tuesday = msc(2026, 6, 16)
    bars = [
        day_bar(sunday, high=10, low=8, close=9),
        day_bar(monday, high=12, low=7, close=11),
    ]
    merged = merged_d1(bars, tuesday)
    assert len(merged) == 1
    assert merged[0].time_msc == sunday
    assert merged[0].high == 12 and merged[0].low == 7 and merged[0].close == 11
    assert merged_d1(bars, monday) == []

    wednesday = msc(2026, 6, 17)
    bars.append(day_bar(tuesday, high=13, low=10, close=12))
    both = merged_d1(bars, wednesday)
    assert len(both) == 2
    assert both[1].close == 12 and both[1].time_msc == tuesday


def test_structure_trend_breaks_up_only_after_two_lows():
    # Длина 1. Ручной разбор: два минимума, затем закрытие 11 пробивает максимум 9.
    raw = [
        (5, 3, 4),
        (10, 7, 9),
        (6, 2, 3),
        (8, 5, 7),
        (4, 1, 2),
        (9, 6, 8),
        (7, 3, 4),
        (12, 8, 11),
    ]
    days = [_Day(i, high, low, close, 0) for i, (high, low, close) in enumerate(raw)]
    assert structure_trend(days[:4], 1) == 0
    assert structure_trend(days, 1) == 1


def test_ema_trend_seeds_with_first_close():
    days = [_Day(i, 0, 0, close, 0) for i, close in enumerate((1.0, 2.0, 3.0))]
    assert ema_trend(days, 2) == 1
    flat = [_Day(i, 0, 0, 5.0, 0) for i in range(3)]
    assert ema_trend(flat, 2) == 0
