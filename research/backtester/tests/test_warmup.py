"""Склейка прогрева Dukascopy: сдвиг, источник, граница без дыры и без нахлёста."""

from __future__ import annotations

import lzma
import struct
from datetime import date, datetime, timezone

import pytest

from backtester.dukascopy_bars import (
    cut_before_live,
    day_start_msc,
    decode_bid_m1,
    estimate_bid_offset,
    load_m1_tree,
    shift_bars,
    stitch_bars,
)
from backtester.session import ExnessGoldSession
from backtester.types import Bar, DataError

H1 = 3_600_000


def msc(y, m, d, hh=0) -> int:
    return int(datetime(y, m, d, hh, tzinfo=timezone.utc).timestamp() * 1000)


def bar(tf, time_msc, close, source) -> Bar:
    return Bar(tf, time_msc, close, close, close, close, close, close, close, close, 1, 0.0, source)


def test_decode_bid_m1_scales_price_and_tags_source():
    day = date(2024, 1, 2)
    raw = struct.pack(">IIIIIf", 0, 2_063_625, 2_064_295, 2_063_625, 2_064_425, 1.5)
    raw += struct.pack(">IIIIIf", 60, 2_064_265, 2_063_705, 2_063_705, 2_064_265, 1.0)
    bars = decode_bid_m1(lzma.compress(raw), day)
    assert len(bars) == 2
    assert bars[0].time_msc == day_start_msc(day)
    assert bars[0].open == pytest.approx(2063.625)
    assert bars[0].close == pytest.approx(2064.295)
    assert bars[0].low == pytest.approx(2063.625)
    assert bars[0].high == pytest.approx(2064.425)
    assert bars[1].time_msc == bars[0].time_msc + 60_000
    assert bars[0].source == "dukascopy"
    assert bars[1].source == "dukascopy"


def test_holdout_day_is_not_decoded(tmp_path):
    with pytest.raises(DataError, match="холдаут"):
        day_start_msc(date(2026, 10, 16))
    folder = tmp_path / "2026" / "10"
    folder.mkdir(parents=True)
    (folder / "16.bi5").write_bytes(b"nope")
    with pytest.raises(DataError, match="холдаут"):
        load_m1_tree(tmp_path)


def test_offset_is_median_exness_minus_dukascopy():
    ref = [bar("M1", 0, 100.4, "exness"), bar("M1", 60_000, 101.0, "exness"), bar("M1", 120_000, 102.2, "exness")]
    other = [bar("M1", 0, 100.0, "dukascopy"), bar("M1", 60_000, 100.8, "dukascopy"), bar("M1", 180_000, 9, "dukascopy")]
    stats = estimate_bid_offset(ref, other)
    assert stats["bars"] == 2
    assert stats["median"] == pytest.approx(0.3)


def test_stitch_has_no_gap_no_overlap_and_keeps_source():
    warmup = shift_bars(
        [bar("H1", 0, 10.0, "dukascopy"), bar("H1", H1, 11.0, "dukascopy")],
        0.2,
    )
    live = [bar("H1", 2 * H1, 12.0, "exness")]
    stitched = stitch_bars(warmup, live)
    assert [item.time_msc for item in stitched] == [0, H1, 2 * H1]
    assert stitched[0].close == pytest.approx(10.2)
    assert stitched[1].close == pytest.approx(11.2)
    assert [item.source for item in stitched] == ["dukascopy", "dukascopy", "exness"]
    assert stitched[0].time_msc + H1 == stitched[1].time_msc
    assert stitched[1].time_msc + H1 == stitched[2].time_msc

    with pytest.raises(DataError, match="дыра"):
        stitch_bars(warmup, [bar("H1", 3 * H1, 12.0, "exness")])
    overlap = warmup + [bar("H1", 2 * H1, 12.0, "dukascopy")]
    with pytest.raises(DataError, match="налезает"):
        stitch_bars(overlap, live)


def test_session_halt_is_not_a_boundary_gap_but_a_missing_open_hour_is():
    # Понедельник 15 июня, пауза дампа 20:58–22:01. Тик 22:05 открывает час 22:00.
    day = msc(2026, 6, 15)
    session = ExnessGoldSession()
    bars = [bar("H1", day + 19 * H1, 100.0, "dukascopy"), bar("H1", day + 20 * H1, 101.0, "dukascopy")]
    kept = cut_before_live(bars, day + 22 * H1 + 5 * 60_000, session)
    assert [item.time_msc for item in kept] == [day + 19 * H1, day + 20 * H1]
    assert kept[-1].source == "dukascopy"
    # Час 19:00 кончается в 20:00, а 20:00 ещё открыт — это дыра, не пауза.
    with pytest.raises(DataError, match="дыра"):
        cut_before_live([bars[0]], day + 22 * H1, session)
