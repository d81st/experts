"""Каждое правило стража счёта. Пороги не подбираются."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from backtester.risk_guard import (
    BEAR_SMA_PERIOD,
    DAILY_LOSS_PERCENT,
    MAX_DRAWDOWN_PERCENT,
    RISK_PERCENT,
    SPREAD_MEDIAN_MULT,
    SPREAD_MEDIAN_SAMPLES,
    STALE_QUOTE_SECONDS,
    MarketView,
    RiskGuard,
    bear_blocks_long,
    market_block_reason,
    median_spread,
    stop_block_reason,
)
from backtester.sizing import size_by_risk
from backtester.strategies.alchemist import AlchemistConfig, AlchemistStrategy, long_x24
from backtester.types import Bar, Tick, xauusd_exness


def msc(y, m, d, hh=0, mm=0, ss=0) -> int:
    moment = datetime(y, m, d, hh, mm, ss, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000)


def view(**kwargs) -> MarketView:
    base = dict(
        point=0.01,
        contract_size=100.0,
        tick_size=0.01,
        tick_value=1.0,
        volume_min=0.01,
        volume_max=100.0,
        volume_step=0.01,
        stops_level=0,
        freeze_level=0,
        bid=100.0,
        ask=100.2,
    )
    base.update(kwargs)
    return MarketView(**base)


def warm(guard: RiskGuard, start: int, equity: float = 10_000.0, n: int = SPREAD_MEDIAN_SAMPLES + 1) -> int:
    """n тиков с шагом 1 с и спредом 0.20. Возвращает время последнего."""
    last = start
    for i in range(n):
        last = start + i * 1000
        guard.observe(last, equity, 100.0, 100.2)
    return last


class _Ctx:
    def __init__(self, bars, tick, equity=10_000.0, balance=10_000.0):
        self._bars = bars
        self._tick = tick
        self.equity = equity
        self.balance = balance
        self.symbol = xauusd_exness()
        self.position = None
        self.closed = []
        self.sized = []
        self.bought = []

    def bars(self, tf):
        return self._bars.get(tf, [])

    def tick(self):
        return self._tick

    def now_msc(self):
        return self._tick.time_msc

    def forming_open_msc(self, tf):
        return self._tick.time_msc

    def session_open(self):
        return True

    def size_for_risk(self, stop_distance, risk_percent, basis="equity", max_risk_overshoot=None, refuse_below_min=False):
        self.sized.append((risk_percent, refuse_below_min, basis))
        return 0.05

    def buy_market(self, volume, sl, tp, comment=""):
        self.bought.append((volume, sl, tp, comment))
        return 1

    def sell_market(self, volume, sl, tp, comment=""):
        raise AssertionError("sell")

    def close_position(self, reason="strategy"):
        self.closed.append(reason)
        return True


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
        min_sl_points=100_000,
        risk_percent=1.0,
    )
    base.update(kwargs)
    return AlchemistConfig(**base)


def _h1(n=6):
    bars = []
    start = msc(2026, 6, 1)
    for i in range(n):
        bars.append(Bar("H1", start + i * 3_600_000, 100, 110, 90, 100, 100.2, 110.2, 90.2, 100.2, 10, 0.0))
    return bars


def _flat_days(price: float, n: int = BEAR_SMA_PERIOD):
    start = msc(2024, 1, 1)
    return [
        Bar("D1", start + i * 86_400_000, price, price, price, price, price, price, price, price, 1, 0.0)
        for i in range(n)
    ]


def test_constants_are_the_preregistered_ones():
    assert RISK_PERCENT == 0.5
    assert DAILY_LOSS_PERCENT == 2.0
    assert MAX_DRAWDOWN_PERCENT == 15.0
    assert BEAR_SMA_PERIOD == 200
    assert SPREAD_MEDIAN_MULT == 3.0
    assert SPREAD_MEDIAN_SAMPLES == 128
    assert STALE_QUOTE_SECONDS == 60


def test_lot_below_minimum_is_refused_instead_of_rounded_up():
    # money/lot = 12_000, сырой лот 0.00833, пол даёт 0. Мин. лот рискует 120 < 150.
    common = dict(
        tick_size=0.01, tick_value=1.0, volume_min=0.01, volume_max=100.0, volume_step=0.01, max_risk_overshoot=1.5,
    )
    assert size_by_risk(10_000, 1.0, 120.0, **common) == pytest.approx(0.01)
    assert size_by_risk(10_000, 1.0, 120.0, refuse_below_min=True, **common) == 0.0
    assert size_by_risk(10_000, RISK_PERCENT, 120.0, refuse_below_min=True, **common) == 0.0
    # Пол до шага уже на минимуме — это не подъём.
    assert size_by_risk(10_000, 1.0, 10.0, refuse_below_min=True, **common) == pytest.approx(0.1)


def test_daily_loss_blocks_until_the_next_server_day_and_does_not_close():
    guard = RiskGuard()
    start = msc(2026, 6, 2, 0, 0, 1)
    last = warm(guard, start)
    decision = guard.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD)
    assert decision.allowed and decision.close is False

    guard.observe(last + 1000, 10_000 * 0.98, 100.0, 100.2)
    blocked = guard.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD)
    assert blocked.allowed is False and blocked.reason == "daily" and blocked.close is False

    guard.observe(last + 2000, 10_000, 100.0, 100.2)
    still = guard.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD)
    assert still.reason == "daily"

    next_day = msc(2026, 6, 3, 0, 0, 1)
    guard.observe(next_day, 9_800, 100.0, 100.2)
    # После длинной паузы котировка устарела. Ещё один тик в ту же секунду — свежий.
    guard.observe(next_day + 1000, 9_800, 100.0, 100.2)
    opened = guard.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD)
    assert opened.allowed and opened.close is False


def test_drawdown_kill_persists_until_manual_reset(tmp_path):
    path = tmp_path / "guard.json"
    guard = RiskGuard(store_path=path)
    start = msc(2026, 6, 2, 0, 0, 1)
    last = warm(guard, start, equity=10_000)
    guard.observe(last + 1000, 8_500, 100.0, 100.2)
    killed = guard.decision(view(), side=-1, entry=100.0, sl=110.0, d1_closes=[100.0] * BEAR_SMA_PERIOD)
    assert killed.reason == "kill" and killed.close is False

    reloaded = RiskGuard(store_path=path)
    assert reloaded.killed and reloaded.peak == pytest.approx(10_000)
    # Выше порога, но без ручного сброса вход закрыт. Котировки после
    # перезапуска собираются заново: пока их нет, отказ и так закрыт.
    later = warm(reloaded, last + 10_000, equity=9_000)
    assert reloaded.decision(view(), side=-1, entry=100.0, sl=110.0, d1_closes=[100.0] * BEAR_SMA_PERIOD).reason == "kill"

    reloaded.manual_reset()
    assert reloaded.killed is False
    assert reloaded.peak == pytest.approx(10_000)
    reloaded.observe(later + 1000, 8_500, 100.0, 100.2)
    assert reloaded.killed
    assert reloaded.decision(view(), side=-1, entry=100.0, sl=110.0, d1_closes=[100.0] * BEAR_SMA_PERIOD).reason == "kill"

    broken = tmp_path / "broken.json"
    broken.write_text("{", encoding="utf-8")
    bad = RiskGuard(store_path=broken)
    assert bad.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD).allowed is False


def test_bear_regime_blocks_new_longs_only():
    flat = [100.0] * BEAR_SMA_PERIOD
    assert bear_blocks_long(flat) is False
    below = flat[:-1] + [99.0]
    assert bear_blocks_long(below) is True
    assert bear_blocks_long(flat[:-1]) is True

    guard = RiskGuard()
    last = warm(guard, msc(2026, 6, 2, 0, 0, 1))
    long_block = guard.decision(view(), side=1, entry=100.2, sl=90.0, d1_closes=below)
    short_ok = guard.decision(view(), side=-1, entry=100.0, sl=110.0, d1_closes=below)
    assert long_block.reason == "bear" and long_block.close is False
    assert short_ok.allowed
    assert last > 0


def test_fail_closed_on_symbol_tick_stops_spread_and_stale_quotes():
    ok = view()
    assert market_block_reason(ok, spread_median=0.2, quote_age_sec=1) is None
    assert market_block_reason(view(point=0.0), spread_median=0.2, quote_age_sec=1) == "symbol"
    assert market_block_reason(view(tick_value=0.0), spread_median=0.2, quote_age_sec=1) == "tick_value"
    assert market_block_reason(view(tick_size=-1), spread_median=0.2, quote_age_sec=1) == "tick_value"
    assert market_block_reason(view(bid=100.0, ask=100.0), spread_median=0.2, quote_age_sec=1) == "symbol"
    assert market_block_reason(ok, spread_median=None, quote_age_sec=1) == "spread"
    assert market_block_reason(ok, spread_median=0.2, quote_age_sec=None) == "stale"
    assert market_block_reason(ok, spread_median=0.2, quote_age_sec=60) is None
    assert market_block_reason(ok, spread_median=0.2, quote_age_sec=61) == "stale"
    assert market_block_reason(view(bid=100.0, ask=100.6), spread_median=0.2, quote_age_sec=1) is None
    assert market_block_reason(view(bid=100.0, ask=100.6 + 1e-9), spread_median=0.2, quote_age_sec=1) == "spread"
    assert stop_block_reason(1, 100.2, 90.0, ok) is None
    assert stop_block_reason(1, 100.2, 100.2, ok) == "stops"
    assert stop_block_reason(-1, 100.0, 90.0, ok) == "stops"
    tight = view(stops_level=1000, point=0.01)
    assert stop_block_reason(1, 100.2, 99.0, tight) == "stops"
    assert median_spread([0.2] * (SPREAD_MEDIAN_SAMPLES - 1)) is None
    assert median_spread([0.2] * SPREAD_MEDIAN_SAMPLES) == pytest.approx(0.2)

    guard = RiskGuard()
    assert guard.decision(ok, side=1, entry=100.2, sl=90.0, d1_closes=[100.0] * BEAR_SMA_PERIOD).reason == "stale"


def test_strategy_does_not_close_or_round_up_when_the_guard_is_on():
    guard = RiskGuard()
    last = warm(guard, msc(2026, 6, 2, 0, 0, 1))
    tick = Tick(last, 100.0, 100.2)
    ctx = _Ctx({"H1": _h1(), "D1": _flat_days(100.0)}, tick)
    strategy = AlchemistStrategy(_simple_config(trade_side="long", exit_bars=24), guard=guard)
    strategy._enter(ctx, 1)
    assert ctx.bought
    assert ctx.sized == [(0.5, True, "balance")]
    assert ctx.closed == []

    guard.observe(last + 1000, 9_700, 100.0, 100.2)
    ctx.equity = 9_700
    ctx.bought.clear()
    strategy._enter(ctx, 1)
    assert ctx.bought == []
    assert ctx.closed == []
    assert strategy.counts["guard_daily"] == 1


def test_time_exit_still_runs_while_the_day_is_blocked():
    guard = RiskGuard()
    guard.day_blocked = True
    strategy = AlchemistStrategy(_simple_config(exit_bars=1), guard=guard)
    opened = msc(2026, 6, 2, 5)
    ctx = _Ctx({"H1": _h1()}, Tick(opened + 2 * 3_600_000, 100.0, 100.2))
    ctx.position = type("P", (), {"entry_time_msc": opened, "side": 1})()
    strategy._exit_by_bars(ctx)
    assert ctx.closed == ["time"]


def test_long_x24_preset_keeps_the_other_defaults():
    cfg = long_x24()
    assert cfg.trade_side == "long"
    assert cfg.exit_bars == 24
    assert cfg.risk_percent == 1.0
    assert cfg.day_trend == "structure"
