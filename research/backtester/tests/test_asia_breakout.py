"""Порт Asia Breakout: коробка M1, один вход в день, закрытие в 20:00, режим."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from backtester.engine import Engine, EngineConfig
from backtester.strategies.asia_breakout import (
    AsiaBreakoutConfig,
    AsiaBreakoutStrategy,
    code_defaults,
    efficiency_ratio,
    trend_filter,
)
from backtester.types import Tick, xauusd_exness


def msc(y, m, d, hh=0, mm=0, ss=0, ms=0) -> int:
    moment = datetime(y, m, d, hh, mm, ss, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000) + ms


def tick(time_msc: int, bid: float, spread: float = 0.2) -> Tick:
    return Tick(time_msc, bid, bid + spread)


def _run(ticks, config=None, deposit=10_000.0):
    spec = xauusd_exness()
    strategy = AsiaBreakoutStrategy(config, digits=spec.digits, adjusted_point=spec.adjusted_point)
    engine = Engine(
        EngineConfig(symbol=spec, deposit=deposit, latency_ms=0, close_at_end=False),
        strategy,
    )
    return engine.run(ticks), strategy


def test_presets_match_the_audited_inputs():
    plain = code_defaults()
    assert plain.entry_mode == "close"
    assert plain.timeframe == "M15"
    assert plain.stop_mode == "opposite"
    assert plain.risk_reward == 1.5
    assert plain.regime == "off"
    assert plain.risk_percent == 3.0
    assert plain.min_box_points == 3000
    assert plain.max_box_points == 0
    trend = trend_filter()
    assert trend.stop_mode == "mid"
    assert trend.risk_reward == 2.0
    assert trend.regime == "filter"
    assert trend.regime_period == 24
    assert trend.regime_threshold == 0.30
    assert trend.risk_percent == 3.0
    with pytest.raises(Exception):
        AsiaBreakoutConfig(trailing="be")


def test_efficiency_ratio_is_kaufman_on_closed_bars():
    # newest 100, 110, 100. Путь 20, прямая 0.
    assert efficiency_ratio([100, 110, 100], 2) == 0.0
    # 100 → 110 → 120. Путь 20, прямая 20.
    assert efficiency_ratio([100, 110, 120], 2) == pytest.approx(1.0)
    assert efficiency_ratio([100, 110], 2) is None


def test_close_entry_uses_the_bar_that_opened_after_asia_and_freezes_the_box():
    """Коробка фиксируется на 06:59:59. Поздний тик той же секунды и 07:00 в неё не входят.

    Бар, открытый в 06:45, за коробку не торгуется. Вход — на открытии 07:15.
    """
    day = (2026, 6, 2)
    ticks = [
        tick(msc(*day, 0, 0), 100),
        tick(msc(*day, 3, 0), 90),
        tick(msc(*day, 5, 0), 100),
        tick(msc(*day, 6, 59, 59, 0), 100),
        tick(msc(*day, 6, 59, 59, 500), 115),
        tick(msc(*day, 7, 0), 200),
        tick(msc(*day, 7, 14), 80),
        tick(msc(*day, 7, 15), 80),
    ]
    result, strategy = _run(ticks)
    assert strategy.box_hi == 100
    assert strategy.box_lo == 90
    assert strategy.counts.get("trades") == 1
    assert len(result.open_positions) == 1
    pos = result.open_positions[0]
    assert pos["side"] == -1
    assert pos["entry_time_msc"] == msc(*day, 7, 15)
    assert pos["entry_price"] == pytest.approx(80)
    assert pos["sl"] == pytest.approx(100.2)
    assert pos["tp"] == pytest.approx(80 - 1.5 * 20.2)


def test_time_close_does_not_enter_on_the_same_tick():
    """Позиция со вчера. В 08:00 она закрывается, и бар 07:45 за коробкой уже не входит.

    CloseHour внутри окна входа, g_traded нового дня ещё false: без return
    после PositionClose на этом тике открылась бы вторая сделка.
    """
    first = (2026, 6, 2)
    second = (2026, 6, 3)
    cfg = AsiaBreakoutConfig(close_hour=8)
    ticks = [
        tick(msc(*first, 0, 0), 100),
        tick(msc(*first, 5, 0), 110),
        tick(msc(*first, 6, 59, 59), 100),
        tick(msc(*first, 7, 14), 120),
        tick(msc(*first, 7, 15), 120),
        tick(msc(*second, 0, 0), 120),
        tick(msc(*second, 3, 0), 105),
        tick(msc(*second, 5, 0), 115),
        tick(msc(*second, 6, 59, 59), 120),
        tick(msc(*second, 7, 45), 130),
        tick(msc(*second, 7, 59), 130),
        tick(msc(*second, 8, 0), 130),
    ]
    result, strategy = _run(ticks, cfg)
    assert strategy.counts.get("time_close") == 1
    assert strategy.counts.get("trades") == 1
    assert len(result.trades) == 1
    assert result.trades[0].exit_reason == "time"
    assert result.trades[0].exit_time_msc == msc(*second, 8, 0)
    assert result.open_positions == []


def test_spread_skip_retries_next_bar_and_sizing_failure_consumes_the_day():
    day = (2026, 6, 2)
    wide = [
        tick(msc(*day, 0, 0), 100),
        tick(msc(*day, 5, 0), 110),
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 14), 120),
        tick(msc(*day, 7, 15), 120, spread=50),
        tick(msc(*day, 7, 29), 120),
        tick(msc(*day, 7, 30), 120),
    ]
    result, strategy = _run(wide)
    assert strategy.counts.get("spread") == 1
    assert strategy.counts.get("trades") == 1
    assert result.open_positions[0]["entry_time_msc"] == msc(*day, 7, 30)

    huge = [
        tick(msc(*day, 0, 0), 100),
        tick(msc(*day, 5, 0), 250),
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 14), 260),
        tick(msc(*day, 7, 15), 260),
        tick(msc(*day, 7, 29), 260),
        tick(msc(*day, 7, 30), 260),
    ]
    result, strategy = _run(huge, deposit=100.0)
    assert strategy.counts.get("sizing") == 1
    assert strategy.counts.get("trades", 0) == 0
    assert result.open_positions == []
    assert strategy.traded is True


def test_flat_regime_skips_the_day_and_trend_mid_stop_uses_rr2():
    day = (2026, 6, 2)
    flat_cfg = AsiaBreakoutConfig(regime="filter", regime_period=2, regime_threshold=0.30, min_box_points=0)
    ticks = []
    for hour, bid in ((0, 100), (1, 110), (2, 100), (3, 110), (4, 100), (5, 110), (6, 100)):
        ticks.append(tick(msc(*day, hour), bid))
    ticks.append(tick(msc(*day, 6, 59, 59), 100))
    ticks.append(tick(msc(*day, 7, 14), 130))
    ticks.append(tick(msc(*day, 7, 15), 130))
    result, strategy = _run(ticks, flat_cfg)
    assert strategy.last_er == pytest.approx(0.0)
    assert strategy.counts.get("regime_skip") == 1
    assert result.open_positions == []
    assert strategy.traded is True

    trend_cfg = AsiaBreakoutConfig(stop_mode="mid", risk_reward=2.0, regime="off", min_box_points=0)
    ticks = [
        tick(msc(*day, 0, 0), 90),
        tick(msc(*day, 5, 0), 110),
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 14), 120),
        tick(msc(*day, 7, 15), 121),
    ]
    result, _strategy = _run(ticks, trend_cfg)
    pos = result.open_positions[0]
    assert pos["side"] == 1
    assert pos["entry_price"] == pytest.approx(121.2)
    assert pos["sl"] == pytest.approx(99.8)
    assert pos["tp"] == pytest.approx(121.2 + 2 * 21.4)


def test_min_stop_expands_and_touch_does_not_wait_for_the_bar():
    day = (2026, 6, 2)
    cfg = AsiaBreakoutConfig(min_sl_points=50_000, min_box_points=0)
    ticks = [
        tick(msc(*day, 0, 0), 90),
        tick(msc(*day, 5, 0), 110),
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 14), 120),
        tick(msc(*day, 7, 15), 121),
    ]
    result, _strategy = _run(ticks, cfg)
    pos = result.open_positions[0]
    assert pos["entry_price"] == pytest.approx(121.2)
    assert pos["sl"] == pytest.approx(71.2)
    assert pos["tp"] == pytest.approx(121.2 + 1.5 * 50)

    touch = AsiaBreakoutConfig(entry_mode="touch", min_box_points=0)
    ticks = [
        tick(msc(*day, 0, 0), 100),
        tick(msc(*day, 5, 0), 110),
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 0), 100),
        tick(msc(*day, 7, 5), 130),
    ]
    touched, _strategy = _run(ticks, touch)
    assert touched.open_positions[0]["entry_time_msc"] == msc(*day, 7, 5)
    closed, _strategy = _run(ticks, AsiaBreakoutConfig(min_box_points=0))
    assert closed.open_positions == []


def test_closed_session_does_not_build_the_box():
    class _Shut:
        def is_open(self, time_msc: int) -> bool:
            return False

    day = (2026, 6, 2)
    ticks = [
        tick(msc(*day, 5, 0), 100),
        tick(msc(*day, 6, 59, 59), 110),
        tick(msc(*day, 8, 0), 130),
    ]
    spec = xauusd_exness()
    strategy = AsiaBreakoutStrategy(code_defaults(), digits=spec.digits, adjusted_point=spec.adjusted_point)
    engine = Engine(
        EngineConfig(symbol=spec, deposit=10_000, latency_ms=0, close_at_end=False),
        strategy,
        session=_Shut(),
    )
    engine.run(ticks)
    assert strategy.box_day == 0
    assert strategy.counts.get("days", 0) == 0


def test_switch_fade_stops_beyond_the_break_extreme():
    day = (2026, 6, 2)
    cfg = AsiaBreakoutConfig(regime="switch", regime_period=2, regime_threshold=0.30, min_box_points=0)
    ticks = []
    for hour, bid in ((0, 100), (1, 110), (2, 100), (3, 110), (4, 100), (5, 110), (6, 100)):
        ticks.append(tick(msc(*day, hour), bid))
    ticks += [
        tick(msc(*day, 6, 59, 59), 100),
        tick(msc(*day, 7, 10), 125),
        tick(msc(*day, 7, 14), 120),
        tick(msc(*day, 7, 15), 80),
    ]
    result, strategy = _run(ticks, cfg)
    assert strategy.counts.get("fade") == 1
    pos = result.open_positions[0]
    assert pos["side"] == -1
    assert pos["entry_price"] == pytest.approx(80)
    assert pos["sl"] == pytest.approx(125.2)
    assert pos["comment"] == "ASIA_BO up fade"
