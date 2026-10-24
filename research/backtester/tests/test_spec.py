"""Выгрузка XAUUSDm: контракт, своп в пунктах, стоп-уровень."""

from __future__ import annotations

import pytest

from backtester.costs import swap_charges
from backtester.engine import Engine, EngineConfig
from backtester.strategy import CallbackStrategy
from backtester.symbol_spec import load_xauusdm, points_to_usd_per_lot
from backtester.types import ConfigError, SymbolSpec, Tick


def msc(y, m, d, hh=0, mm=0, ss=0) -> int:
    from datetime import datetime, timezone

    moment = datetime(y, m, d, hh, mm, ss, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000)


def test_loaded_spec_matches_terminal_dump():
    captured = load_xauusdm()
    spec = captured.spec
    assert spec.name == "XAUUSDm"
    assert spec.contract_size == 100
    assert spec.digits == 3
    assert spec.point == pytest.approx(0.001)
    assert spec.tick_size == pytest.approx(0.001)
    assert spec.tick_value == pytest.approx(0.1)
    assert spec.money_per_price == pytest.approx(100)
    assert spec.volume_min == pytest.approx(0.01)
    assert spec.volume_max == pytest.approx(200)
    assert spec.volume_step == pytest.approx(0.01)
    assert spec.stops_level == 0
    assert spec.freeze_level == 0
    assert captured.swap_mode == "SYMBOL_SWAP_MODE_POINTS"
    assert captured.swap_long_points == pytest.approx(-490.8)
    assert captured.swap_short_points == pytest.approx(0)
    assert captured.swap_long_per_lot == pytest.approx(-49.08)
    assert captured.swap_short_per_lot == pytest.approx(0)
    assert captured.swap_long_per_lot == pytest.approx(
        points_to_usd_per_lot(-490.8, spec.point, spec.tick_size, spec.tick_value)
    )
    assert captured.triple_swap_weekday == 2
    assert captured.swap_rollover3days == "WEDNESDAY"
    assert captured.swap_multipliers == (1.0, 1.0, 3.0, 1.0, 1.0, 0.0, 0.0)
    assert captured.captured_date == "2026-10-24"
    assert captured.path == "data/symbol-spec/XAUUSDm.json"
    assert captured.server_utc_offset_seconds == 0


def test_spec_multipliers_charge_wednesday_triple_and_one_friday_night():
    mult = load_xauusdm().swap_multipliers
    charges = swap_charges(
        msc(2026, 8, 19, 12),
        msc(2026, 8, 20, 2),
        msc(2026, 8, 19, 12),
        0,
        multipliers=mult,
    )
    assert charges == [(msc(2026, 8, 20, 0), 3.0)]
    weekend = swap_charges(
        msc(2026, 8, 14, 12),
        msc(2026, 8, 17, 12),
        msc(2026, 8, 14, 12),
        0,
        multipliers=mult,
    )
    assert weekend == [(msc(2026, 8, 15, 0), 1.0)]


def test_engine_charges_spec_swap_for_one_wednesday_night():
    captured = load_xauusdm()

    def on_tick(ctx, tick):
        if tick.time_msc == msc(2026, 8, 19, 12):
            ctx.buy_market(0.01, sl=1, tp=None)

    ticks = [
        Tick(msc(2026, 8, 19, 12), 100, 100.1),
        Tick(msc(2026, 8, 20, 2), 100, 100.1),
    ]
    engine = Engine(
        EngineConfig(
            symbol=captured.spec,
            deposit=10_000,
            swap_long_per_lot=captured.swap_long_per_lot,
            swap_short_per_lot=captured.swap_short_per_lot,
            swap_multipliers=captured.swap_multipliers,
            check_margin=False,
        ),
        CallbackStrategy(["M1"], on_tick=on_tick),
    )
    result = engine.run(ticks)
    assert result.open_positions[0]["swap"] == pytest.approx(-49.08 * 0.01 * 3)


def test_stops_level_rejects_a_stop_closer_than_the_level():
    symbol = SymbolSpec(
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
        stops_level=100,
    )

    def on_tick(ctx, tick):
        if tick.time_msc == 1_000:
            ctx.buy_market(1, sl=99.5, tp=None)
        if tick.time_msc == 2_000:
            ctx.buy_market(1, sl=99.0, tp=None)

    ticks = [Tick(1_000, 100.0, 100.2), Tick(2_000, 100.0, 100.2), Tick(3_000, 100.0, 100.2)]
    engine = Engine(
        EngineConfig(symbol=symbol, deposit=10_000, check_margin=False),
        CallbackStrategy(["M1"], on_tick=on_tick),
    )
    result = engine.run(ticks)
    assert engine.reject_counts.get("stops_level") == 1
    assert result.open_positions[0]["entry_time_msc"] == 2_000
    assert result.open_positions[0]["sl"] == 99.0


def test_bad_swap_mode_is_refused(tmp_path):
    import json

    from backtester import symbol_spec
    from backtester.symbol_spec import find_spec_path

    payload = json.loads(find_spec_path().read_text(encoding="utf-8"))
    payload["swap_mode"] = {"value": 0, "name": "SYMBOL_SWAP_MODE_DISABLED"}
    raw_path = tmp_path / "XAUUSDm.json"
    raw_path.write_text(json.dumps(payload), encoding="utf-8")
    symbol_spec._CACHED_RAW = None
    try:
        with pytest.raises(ConfigError, match="своп не в пунктах"):
            load_xauusdm(path=raw_path)
    finally:
        symbol_spec._CACHED_RAW = None
        symbol_spec._CACHED_PATH = None
