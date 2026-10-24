"""Разбор отчёта MT5 и попарная сверка. Фикстура — несколько строк, не полный отчёт."""

from __future__ import annotations

import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

from backtester.cli import main
from backtester.compare import OurTrade, compare_trades, load_our_csv, tolerance_profile
from backtester.mt5report import Mt5Trade, load_mt5, parse_mt5_html

FIXTURE = Path(__file__).parent / "fixtures" / "mt5_min.htm"


def test_html_skips_balance_and_reads_sl_from_comment():
    trades = parse_mt5_html(FIXTURE)
    assert len(trades) == 2
    first, second = trades
    assert first.side == -1
    assert first.volume == 0.02
    assert first.entry_price == 4501.946
    assert first.exit_price == 4487.029
    assert first.profit == 29.83
    assert first.sl is None
    assert first.entry_time == datetime(2026, 6, 1, 7, tzinfo=timezone.utc)
    assert second.sl == 4470.0
    assert second.swap == -1.04
    assert second.profit == 10.0


def test_utf16_html_parses(tmp_path: Path):
    target = tmp_path / "report.htm"
    target.write_bytes(FIXTURE.read_text(encoding="utf-8").encode("utf-16"))
    trades = load_mt5(target)
    assert len(trades) == 2
    assert trades[0].comment_in == "HAL"


def test_compare_pairs_and_names_the_price_mismatch(tmp_path: Path):
    ours = tmp_path / "trades.csv"
    ours.write_text(
        "entry_time,exit_time,side,volume,entry_price,exit_price,sl,net_pnl,exit_reason,comment\n"
        "2026-06-01T07:00:00.000Z,2026-06-01T19:00:00.000Z,short,0.0200,4501.94600,4487.02900,,29.8300,time,HAL\n"
        "2026-06-03T00:00:01.000Z,2026-06-03T12:00:00.000Z,short,0.0100,4475.05700,4462.40100,4470.00000,10.0000,sl,HAL\n"
        "2026-06-10T00:00:00.000Z,2026-06-10T12:00:00.000Z,long,0.0100,100.00000,101.00000,,1.0000,time,HAL\n",
        encoding="utf-8",
    )
    report = compare_trades(load_our_csv(ours), load_mt5(FIXTURE))
    assert report["mt5"] == 2
    assert report["ours"] == 3
    assert report["paired"] == 2
    assert report["exact"] == 1
    assert report["paired_with_mismatch"] == 1
    assert report["ours_only"] == 1
    assert report["mt5_only"] == 0
    bad = next(row for row in report["pairs"] if not row["match"])
    assert bad["reasons"] == ["entry_price"]
    assert bad["entry_price_delta"] == pytest.approx(1.0)

    window = compare_trades(
        load_our_csv(ours),
        load_mt5(FIXTURE),
        start=datetime(2026, 6, 3, tzinfo=timezone.utc),
        end=datetime(2026, 6, 4, tzinfo=timezone.utc),
    )
    assert window["mt5"] == 1
    assert window["ours"] == 1
    assert window["exact"] == 0


def test_json_deals(tmp_path: Path):
    path = tmp_path / "deals.json"
    path.write_text(
        '{"deals":['
        '{"time":"2026-06-01 07:00:00","type":"buy","direction":"in","volume":0.01,"price":100.5,"comment":"HAL"},'
        '{"time":"2026-06-01 08:00:00","type":"sell","direction":"out","volume":0.01,"price":101.5,"profit":10,"comment":"sl 99.000"}'
        "]}",
        encoding="utf-8",
    )
    trades = load_mt5(path)
    assert len(trades) == 1
    assert trades[0].side == 1
    assert trades[0].sl == 99.0
    assert trades[0].profit == 10


def test_aligned_profile_ignores_subsecond_price_noise():
    moment = datetime(2026, 6, 1, 7, 0, tzinfo=timezone.utc)
    ours = [
        OurTrade(moment, moment, -1, 0.02, 4502.30, 4487.40, None, 1.0, "time", "HAL"),
    ]
    mt5 = [
        Mt5Trade(moment.replace(second=4), moment, -1, 0.02, 4501.95, 4487.03, None, 0.0, 0.0, 1.0, "HAL", ""),
    ]
    strict = compare_trades(ours, mt5, **tolerance_profile("strict"))
    aligned = compare_trades(ours, mt5, **tolerance_profile("aligned"))
    assert strict["exact"] == 0
    assert "entry_price" in strict["pairs"][0]["reasons"]
    assert "entry_time" in strict["pairs"][0]["reasons"]
    assert aligned["exact"] == 1
    assert tolerance_profile("aligned")["entry_time_sec"] == 5.0
    assert tolerance_profile("aligned")["price_tol"] == 0.5
    assert tolerance_profile("aligned")["exit_time_sec"] == 5.0


def test_cli_module_answers_help():
    proc = subprocess.run(
        [sys.executable, "-m", "backtester.cli", "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    assert "alchemist" in proc.stdout


def test_cli_refuses_holdout():
    with pytest.raises(SystemExit, match="холдаут"):
        main(["alchemist", "--ticks", "missing.csv.gz", "--to", "2026-10-16", "--out", "out"])
    with pytest.raises(SystemExit, match="холдаут"):
        main(["compare", "--ours", "a.csv", "--mt5", "b.htm", "--end", "2026-10-16"])
