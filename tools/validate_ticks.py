#!/usr/bin/env python3
"""Проверка и упаковка помесячного CSV с тиками Exness.

Колонки: time_msc,bid,ask,last,volume,volume_real,flags.
time_msc — часы сервера брокера (миллисекунды с 1970-01-01), без сдвига.
На Exness эти часы совпадают с UTC, поэтому суточные паузы ищутся
в тех же цифрах: летом закрытие около 20:57, зимой около 21:57.

Запуск проверки синтаксиса правил:
    python3 tools/validate_ticks.py --self-test

Упаковка выгрузки терминала:
    python3 tools/validate_ticks.py --raw DIR --out DIR \\
        --symbol XAUUSDm --date-from 2026-09-01 --date-to 2026-09-30 --gap-minutes 5
"""

import gzip
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

HEADER = "time_msc,bid,ask,last,volume,volume_real,flags"
INFO_KEYS = {
    "complete",
    "error",
    "script_version",
    "symbol",
    "from",
    "to_exclusive",
    "exported_at",
    "terminal_build",
    "terminal_name",
    "terminal_company",
    "broker_company",
    "digits",
    "point",
    "columns",
    "history_ended_at",
}
MONTH_FIELDS = {
    "rows",
    "first_time_msc",
    "last_time_msc",
    "copy_errors",
    "empty_chunks",
    "splits",
    "file",
}
SAFE_ERRORS = {
    "",
    "job_file_missing",
    "bad_job",
    "not_connected",
    "symbol_not_selected",
    "range_too_long",
}
TEXT_KEYS = {"exported_at", "terminal_name", "terminal_company", "broker_company"}
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
MONTH_RE = re.compile(r"^\d{4}-\d{2}$")


def to_ms(dt):
    epoch = datetime(1970, 1, 1)
    delta = dt - epoch
    return delta.days * 86400000 + delta.seconds * 1000 + delta.microseconds // 1000


def from_ms(ms):
    return datetime(1970, 1, 1) + timedelta(milliseconds=int(ms))


def format_server_time(ms):
    base = from_ms(ms)
    return base.strftime("%Y-%m-%d %H:%M:%S.") + f"{int(ms) % 1000:03d}"


def month_span(date_from, date_to):
    start = datetime.strptime(date_from, "%Y-%m-%d")
    end = datetime.strptime(date_to, "%Y-%m-%d")
    y, m = start.year, start.month
    out = []
    while (y, m) <= (end.year, end.month):
        out.append(f"{y:04d}-{m:02d}")
        m += 1
        if m == 13:
            m = 1
            y += 1
    return out


def clip_ms(month, date_from, date_to):
    year, mon = (int(part) for part in month.split("-"))
    month_start = datetime(year, mon, 1)
    if mon == 12:
        month_end = datetime(year + 1, 1, 1)
    else:
        month_end = datetime(year, mon + 1, 1)
    req_start = datetime.strptime(date_from, "%Y-%m-%d")
    req_end = datetime.strptime(date_to, "%Y-%m-%d") + timedelta(days=1)
    return to_ms(max(month_start, req_start)), to_ms(min(month_end, req_end))


def _minutes(dt):
    return dt.hour * 60 + dt.minute


def is_daily_break(t1, t2):
    """Суточная пауза Exness: 63–65 минут, окно сдвигается вместе с DST США."""
    if t1.date() != t2.date():
        return False
    dur = t2 - t1
    if not (timedelta(minutes=45) <= dur <= timedelta(minutes=100)):
        return False
    start = _minutes(t1)
    end = _minutes(t2)
    return (20 * 60 + 50) <= start <= (22 * 60 + 10) and (21 * 60 + 50) <= end <= (23 * 60 + 25)


def is_weekend_closure(t1, t2):
    """Пятница вечером (или суббота) до открытия в воскресенье."""
    dur = t2 - t1
    if dur < timedelta(hours=20) or dur > timedelta(hours=60):
        return False
    start_ok = (t1.weekday() == 4 and _minutes(t1) >= 20 * 60 + 50) or t1.weekday() == 5
    end_ok = t2.weekday() == 6 and (21 * 60 + 30) <= _minutes(t2) <= (23 * 60 + 45)
    return start_ok and end_ok


def classify_gap(prev_ms, next_ms, gap_minutes):
    delta = next_ms - prev_ms
    if delta <= gap_minutes * 60 * 1000:
        return "ok"
    t1 = from_ms(prev_ms)
    t2 = from_ms(next_ms)
    if is_daily_break(t1, t2) or is_weekend_closure(t1, t2):
        return "closure"
    return "anomaly"


def parse_export_info(path):
    """Разобрать export_info.txt. Чужие поля отклоняются, значения не печатаются наружу."""
    text = Path(path).read_text(encoding="ascii")
    if IP_RE.search(text):
        raise ValueError("export_info contains a network address")
    info = {}
    months = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if "=" not in line:
            raise ValueError("export_info line has no separator")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Za-z0-9._\-]+", key):
            raise ValueError("export_info has an unexpected field")
        if "\x00" in value:
            raise ValueError("export_info has an unexpected field")
        parts = key.split(".")
        if parts[0] == "month":
            if len(parts) != 3 or not MONTH_RE.fullmatch(parts[1]) or parts[2] not in MONTH_FIELDS:
                raise ValueError("export_info has an unexpected field")
            months.setdefault(parts[1], {})[parts[2]] = value
            continue
        if key not in INFO_KEYS:
            raise ValueError("export_info has an unexpected field")
        if key == "columns":
            if value != HEADER:
                raise ValueError("export_info has an unexpected value")
            info[key] = value
            continue
        if key not in TEXT_KEYS and not re.fullmatch(r"[A-Za-z0-9._\-]*", value):
            raise ValueError("export_info has an unexpected value")
        if key in TEXT_KEYS and not re.fullmatch(r"[A-Za-z0-9 .:_\-]*", value):
            raise ValueError("export_info has an unexpected value")
        info[key] = value
    return info, months


def _empty_month(month, symbol):
    return {
        "month": month,
        "file": f"ticks_{symbol}_{month}.csv.gz",
        "row_count": 0,
        "first_time_msc": None,
        "last_time_msc": None,
        "first_timestamp": None,
        "last_timestamp": None,
        "sha256": None,
        "bytes": None,
        "bid_gt_ask": 0,
        "nonpositive_price": 0,
        "identical_rows": 0,
        "repeated_time_msc": 0,
        "out_of_order": 0,
        "parse_errors": 0,
        "gap_anomalies": 0,
        "gap_examples": [],
        "normal_closures": 0,
        "copy_errors": 0,
        "empty_chunks": 0,
        "splits": 0,
    }


def validate_csv(path, month, symbol, gap_minutes, clip_start, clip_end):
    stats = _empty_month(month, symbol)
    failures = []
    path = Path(path)
    if not path.is_file():
        failures.append(f"{month}: file is missing")
        return stats, failures
    prev = None
    prev_ms = None
    outside = 0
    with path.open("r", encoding="ascii", newline="") as handle:
        header = handle.readline().strip("\r\n")
        if header != HEADER:
            failures.append(f"{month}: unexpected header")
            return stats, failures
        for line_no, raw in enumerate(handle, start=2):
            line = raw.strip("\r\n")
            if line == "":
                continue
            fields = line.split(",")
            if len(fields) != 7:
                stats["parse_errors"] += 1
                if stats["parse_errors"] <= 5:
                    failures.append(f"{month}: parse error on line {line_no}")
                prev = None
                continue
            try:
                ms = int(fields[0])
                bid = Decimal(fields[1])
                ask = Decimal(fields[2])
                Decimal(fields[3])
                int(fields[4])
                Decimal(fields[5])
                int(fields[6])
            except (InvalidOperation, ValueError):
                stats["parse_errors"] += 1
                if stats["parse_errors"] <= 5:
                    failures.append(f"{month}: parse error on line {line_no}")
                prev = None
                continue
            if ms < clip_start or ms >= clip_end:
                outside += 1
            if prev is not None and line == prev:
                stats["identical_rows"] += 1
            if prev_ms is not None:
                if ms < prev_ms:
                    stats["out_of_order"] += 1
                elif ms == prev_ms:
                    stats["repeated_time_msc"] += 1
                else:
                    kind = classify_gap(prev_ms, ms, gap_minutes)
                    if kind == "closure":
                        stats["normal_closures"] += 1
                    elif kind == "anomaly":
                        stats["gap_anomalies"] += 1
                        if len(stats["gap_examples"]) < 20:
                            stats["gap_examples"].append(
                                {
                                    "from": format_server_time(prev_ms),
                                    "to": format_server_time(ms),
                                    "minutes": round((ms - prev_ms) / 60000, 3),
                                }
                            )
            if bid <= 0 or ask <= 0:
                stats["nonpositive_price"] += 1
            elif bid > ask:
                stats["bid_gt_ask"] += 1
            stats["row_count"] += 1
            if stats["row_count"] == 1:
                stats["first_time_msc"] = ms
                stats["first_timestamp"] = format_server_time(ms)
            stats["last_time_msc"] = ms
            stats["last_timestamp"] = format_server_time(ms)
            prev = line
            prev_ms = ms
    if outside:
        failures.append(f"{month}: ticks outside the requested range={outside}")
    if stats["parse_errors"]:
        failures.append(f"{month}: parse_errors={stats['parse_errors']}")
    if stats["identical_rows"]:
        failures.append(f"{month}: identical_rows={stats['identical_rows']}")
    if stats["out_of_order"]:
        failures.append(f"{month}: out_of_order={stats['out_of_order']}")
    if stats["nonpositive_price"]:
        failures.append(f"{month}: nonpositive_price={stats['nonpositive_price']}")
    if stats["bid_gt_ask"]:
        failures.append(f"{month}: bid_gt_ask={stats['bid_gt_ask']}")
    return stats, failures


def gzip_file(src, dest):
    with src.open("rb") as raw, dest.open("wb") as out, gzip.GzipFile(
        filename="", mode="wb", fileobj=out, compresslevel=6, mtime=0
    ) as zipped:
        shutil.copyfileobj(raw, zipped)
    digest = hashlib.sha256(dest.read_bytes()).hexdigest()
    return digest, dest.stat().st_size


def _int_field(months, month, field, failures):
    raw = months.get(month, {}).get(field, "")
    if raw == "":
        failures.append(f"{month}: export_info missing {field}")
        return None
    if not re.fullmatch(r"\d+", raw):
        failures.append(f"{month}: export_info has a bad {field}")
        return None
    return int(raw)


def package(raw_dir, out_dir, symbol, date_from, date_to, gap_minutes):
    raw_dir = Path(raw_dir)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    failures = []
    warnings = []
    info_path = raw_dir / "export_info.txt"
    info, reported = {}, {}
    if not info_path.is_file():
        failures.append("export_info.txt is missing")
    else:
        try:
            info, reported = parse_export_info(info_path)
        except ValueError as exc:
            failures.append(str(exc))
    if info.get("error", "") not in SAFE_ERRORS:
        failures.append("export finished with an unknown error")
        info["error"] = "unknown"
    if info.get("complete") != "1":
        failures.append("export did not finish (complete!=1, error=%s)" % (info.get("error") or "none"))
    if info.get("symbol") not in (None, symbol):
        failures.append("export symbol does not match the request")
    if info.get("columns") not in (None, HEADER):
        failures.append("export columns do not match the archive schema")
    excl = (datetime.strptime(date_to, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    if info.get("from", "").replace(".", "-") not in ("", date_from):
        failures.append("export from-date does not match the request")
    if info.get("to_exclusive", "").replace(".", "-") not in ("", excl):
        failures.append("export to-date does not match the request")
    build = info.get("terminal_build", "")
    if not re.fullmatch(r"[1-9]\d*", build or ""):
        failures.append("terminal_build is missing")
        build = None
    else:
        build = int(build)
    digits = info.get("digits", "")
    if digits != "" and not re.fullmatch(r"\d+", digits):
        failures.append("digits field is not a number")
        digits = None
    elif digits == "":
        digits = None
    else:
        digits = int(digits)

    months = []
    seen_data = False
    leading_empty = []
    for month in month_span(date_from, date_to):
        clip_start, clip_end = clip_ms(month, date_from, date_to)
        csv_name = f"ticks_{symbol}_{month}.csv"
        stats, month_failures = validate_csv(
            raw_dir / csv_name, month, symbol, gap_minutes, clip_start, clip_end
        )
        failures.extend(month_failures)
        reported_file = reported.get(month, {}).get("file", "")
        if reported and reported_file not in ("", csv_name):
            failures.append(f"{month}: export_info names a different file")
        rows = _int_field(reported, month, "rows", failures) if reported else None
        errors = _int_field(reported, month, "copy_errors", failures) if reported else None
        if rows is not None and rows != stats["row_count"]:
            failures.append(f"{month}: row count {stats['row_count']} does not match export_info {rows}")
        if errors:
            stats["copy_errors"] = errors
            failures.append(f"{month}: copy_errors={errors}")
        elif errors == 0:
            stats["copy_errors"] = 0
        for field in ("empty_chunks", "splits"):
            value = _int_field(reported, month, field, []) if reported else None
            if value is not None:
                stats[field] = value
        first = reported.get(month, {}).get("first_time_msc", "")
        last = reported.get(month, {}).get("last_time_msc", "")
        if stats["row_count"] and first not in ("", str(stats["first_time_msc"])):
            failures.append(f"{month}: first timestamp does not match export_info")
        if stats["row_count"] and last not in ("", str(stats["last_time_msc"])):
            failures.append(f"{month}: last timestamp does not match export_info")
        if stats["row_count"] == 0:
            if not seen_data:
                leading_empty.append(month)
            else:
                failures.append(f"{month}: no ticks after history had already started")
        else:
            seen_data = True
            gz_name = stats["file"]
            digest, size = gzip_file(raw_dir / csv_name, out_dir / gz_name)
            stats["sha256"] = digest
            stats["bytes"] = size
            (raw_dir / csv_name).unlink()
        if stats["gap_anomalies"]:
            warnings.append(f"{month}: gaps outside closures={stats['gap_anomalies']}")
        if stats["repeated_time_msc"]:
            warnings.append(
                f"{month}: repeated millisecond timestamps={stats['repeated_time_msc']} (not identical rows)"
            )
        months.append(stats)

    if not seen_data:
        failures.append("no ticks in the requested range")
    if leading_empty:
        warnings.append("no ticks before " + (months[len(leading_empty)]["month"] if seen_data else "end"))

    export_date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    terminal = {
        "terminal_build": build,
        "terminal_name": info.get("terminal_name", ""),
        "terminal_company": info.get("terminal_company", ""),
        "broker_company": info.get("broker_company", ""),
    }
    manifest = {
        "symbol": symbol,
        "export_date": export_date,
        "time_basis": (
            "time_msc is the broker server clock in milliseconds since 1970-01-01 00:00:00, "
            "with no timezone shift. On the Exness server used by this repo that clock is UTC+0."
        ),
        "columns": HEADER.split(","),
        "digits": digits,
        "point": info.get("point", ""),
        "terminal_build": build,
        "terminal_name": terminal["terminal_name"],
        "terminal_company": terminal["terminal_company"],
        "broker_company": terminal["broker_company"],
        "files": [],
    }
    for stats in months:
        if not stats["sha256"]:
            continue
        manifest["files"].append(
            {
                "file": stats["file"],
                "symbol": symbol,
                "month": stats["month"],
                "row_count": stats["row_count"],
                "first_time_msc": stats["first_time_msc"],
                "last_time_msc": stats["last_time_msc"],
                "first_timestamp": stats["first_timestamp"],
                "last_timestamp": stats["last_timestamp"],
                "sha256": stats["sha256"],
                "bytes": stats["bytes"],
                "export_date": export_date,
                "terminal_build": build,
                "terminal_name": terminal["terminal_name"],
                "broker_company": terminal["broker_company"],
            }
        )
    validation = {
        "ok": not failures,
        "symbol": symbol,
        "from": date_from,
        "to": date_to,
        "gap_minutes": gap_minutes,
        "history_starts": None if not seen_data else months[len(leading_empty)]["month"],
        "leading_empty_months": leading_empty,
        "hard_failures": failures,
        "warnings": warnings,
        "terminal_build": build,
        "broker_company": terminal["broker_company"],
        "months": months,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="ascii")
    (out_dir / "validation.json").write_text(json.dumps(validation, indent=2) + "\n", encoding="ascii")
    if info_path.is_file():
        shutil.copyfile(info_path, out_dir / "export_info.txt")
    return validation


def _write_info(path, symbol, date_from, date_to, months, build=4120):
    excl = datetime.strptime(date_to, "%Y-%m-%d") + timedelta(days=1)
    lines = [
        "complete=1",
        "error=",
        "script_version=1",
        f"symbol={symbol}",
        "from=" + date_from.replace("-", "."),
        "to_exclusive=" + excl.strftime("%Y.%m.%d"),
        "exported_at=2026.10.24 00:00:00",
        f"terminal_build={build}",
        "terminal_name=MetaTrader 5",
        "terminal_company=MetaQuotes Ltd.",
        "broker_company=Exness Technologies Ltd",
        "digits=3",
        "point=0.00100000",
        "columns=" + HEADER,
        "history_ended_at=",
    ]
    for month, rows, first, last in months:
        lines.append(f"month.{month}.rows={rows}")
        lines.append(f"month.{month}.first_time_msc={'' if first is None else first}")
        lines.append(f"month.{month}.last_time_msc={'' if last is None else last}")
        lines.append(f"month.{month}.copy_errors=0")
        lines.append(f"month.{month}.empty_chunks=1")
        lines.append(f"month.{month}.splits=0")
        lines.append(f"month.{month}.file=ticks_XAUUSDm_{month}.csv")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _csv(path, rows):
    path.write_text(HEADER + "\r\n" + "".join(row + "\r\n" for row in rows), encoding="ascii")


def _tick(ms, bid="2500.000", ask="2500.200"):
    return f"{ms},{bid},{ask},0.000,0,0.00000000,6"


def _expect(cond, message):
    if not cond:
        raise AssertionError(message)


def self_test():
    wed = datetime(2026, 9, 1)
    while wed.weekday() != 2:
        wed += timedelta(days=1)
    fri = wed + timedelta(days=2)
    sun = fri + timedelta(days=2)
    _expect(fri.weekday() == 4 and sun.weekday() == 6, "calendar fixture")

    def at(day, hour, minute, millis=0):
        return to_ms(day.replace(hour=hour, minute=minute, second=0)) + millis

    daily_from = at(wed, 20, 57)
    daily_to = at(wed, 22, 2)
    _expect(classify_gap(daily_from, daily_to, 5) == "closure", "summer daily break")
    winter_from = at(wed, 21, 57)
    winter_to = at(wed, 23, 2)
    _expect(classify_gap(winter_from, winter_to, 5) == "closure", "winter daily break")
    _expect(classify_gap(at(wed, 15, 0), at(wed, 15, 4), 5) == "ok", "4 min gap is inside N")
    _expect(classify_gap(at(wed, 15, 0), at(wed, 15, 5), 5) == "ok", "exactly N minutes is not greater")
    _expect(classify_gap(at(wed, 15, 0), at(wed, 15, 10), 5) == "anomaly", "10 min intraday gap")
    _expect(classify_gap(at(wed, 20, 40), at(wed, 22, 0), 5) == "anomaly", "gap starts before the break")
    _expect(classify_gap(at(wed, 20, 57), at(wed, 23, 20), 5) == "anomaly", "break longer than 100 min")
    weekend_from = at(fri, 20, 58)
    weekend_to = at(sun, 22, 5)
    _expect(classify_gap(weekend_from, weekend_to, 5) == "closure", "weekend")
    _expect(classify_gap(at(fri, 21, 57), at(sun, 23, 5), 5) == "closure", "winter weekend")
    monday = sun + timedelta(days=1)
    _expect(classify_gap(weekend_from, at(monday, 22, 5), 5) == "anomaly", "holiday through Monday")

    symbol = "XAUUSDm"
    month = f"{wed.year:04d}-{wed.month:02d}"
    later = f"{wed.year + (wed.month == 12):04d}-{(1 if wed.month == 12 else wed.month + 1):02d}"
    # later month label is unused when September is the only requested month; keep the next month name.
    if wed.month == 12:
        next_month = f"{wed.year + 1:04d}-01"
    else:
        next_month = f"{wed.year:04d}-{wed.month + 1:02d}"
    _expect(later == next_month or True, "month label")

    rows = [
        _tick(at(wed, 20, 56, 0)),
        _tick(at(wed, 20, 56, 0), bid="2500.010"),
        _tick(at(wed, 20, 56, 30)),
        _tick(daily_from),
        _tick(daily_to),
        _tick(at(wed, 22, 2, 30)),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        raw = root / "raw"
        out = root / "out"
        raw.mkdir()
        _csv(raw / f"ticks_{symbol}_{month}.csv", rows)
        first = at(wed, 20, 56, 0)
        last = at(wed, 22, 2, 30)
        _write_info(raw / "export_info.txt", symbol, "2026-09-01", "2026-09-30", [(month, len(rows), first, last)])
        result = package(raw, out, symbol, "2026-09-01", "2026-09-30", 5)
        _expect(result["ok"], "clean month should pass: " + "; ".join(result["hard_failures"]))
        _expect(result["months"][0]["gap_anomalies"] == 0, "closures are not anomalies")
        _expect(result["months"][0]["normal_closures"] == 1, "daily break")
        _expect(result["months"][0]["repeated_time_msc"] == 1, "same millisecond, different price")
        gz = out / f"ticks_{symbol}_{month}.csv.gz"
        _expect(gz.is_file(), "gzip written")
        manifest = json.loads((out / "manifest.json").read_text(encoding="ascii"))
        _expect(manifest["files"][0]["sha256"] == hashlib.sha256(gz.read_bytes()).hexdigest(), "sha256")
        _expect(manifest["files"][0]["row_count"] == len(rows), "manifest rows")
        _expect(manifest["terminal_build"] == 4120, "build")
        _expect("login" not in (out / "manifest.json").read_text(encoding="ascii"), "no login field")

        raw2 = root / "raw2"
        out2 = root / "out2"
        raw2.mkdir()
        bad_rows = [
            _tick(at(wed, 16, 0, 0), bid="10.000", ask="9.000"),
            _tick(at(wed, 16, 0, 0), bid="10.000", ask="9.000"),
            _tick(at(wed, 16, 30, 0), bid="0.000", ask="1.000"),
            _tick(at(wed, 12, 0, 0)),
        ]
        _csv(raw2 / f"ticks_{symbol}_{month}.csv", bad_rows)
        _write_info(
            raw2 / "export_info.txt",
            symbol,
            "2026-09-01",
            "2026-09-30",
            [(month, len(bad_rows), at(wed, 16, 0, 0), at(wed, 12, 0, 0))],
        )
        # last tick is out of order, so export_info last matches the file's last row
        bad = package(raw2, out2, symbol, "2026-09-01", "2026-09-30", 5)
        text = " ".join(bad["hard_failures"])
        _expect("bid_gt_ask=" in text, "bid>ask")
        _expect("identical_rows=" in text, "identical rows")
        _expect("nonpositive_price=" in text, "zero price")
        _expect("out_of_order=" in text, "out of order")
        _expect(not bad["ok"], "bad file fails")

        raw3 = root / "raw3"
        out3 = root / "out3"
        raw3.mkdir()
        prev_month = "2026-08"
        _csv(raw3 / f"ticks_{symbol}_{prev_month}.csv", [])
        _csv(raw3 / f"ticks_{symbol}_{month}.csv", rows)
        _write_info(
            raw3 / "export_info.txt",
            symbol,
            "2026-08-01",
            "2026-09-30",
            [(prev_month, 0, None, None), (month, len(rows), first, last)],
        )
        lead = package(raw3, out3, symbol, "2026-08-01", "2026-09-30", 5)
        _expect(lead["ok"], "leading empty month is the history edge: " + "; ".join(lead["hard_failures"]))
        _expect(lead["history_starts"] == month, "history start month")

        raw4 = root / "raw4"
        out4 = root / "out4"
        raw4.mkdir()
        _csv(raw4 / f"ticks_{symbol}_{prev_month}.csv", rows[:1])
        _csv(raw4 / f"ticks_{symbol}_{month}.csv", [])
        only = rows[0]
        only_ms = int(only.split(",")[0])
        _write_info(
            raw4 / "export_info.txt",
            symbol,
            "2026-08-01",
            "2026-09-30",
            [(prev_month, 1, only_ms, only_ms), (month, 0, None, None)],
        )
        # August row uses a September timestamp; that is outside August and must fail.
        # Build a real August tick instead.
        aug = at(datetime(2026, 8, 5, 15, 0), 15, 0)
        _csv(raw4 / f"ticks_{symbol}_{prev_month}.csv", [_tick(aug)])
        _write_info(
            raw4 / "export_info.txt",
            symbol,
            "2026-08-01",
            "2026-09-30",
            [(prev_month, 1, aug, aug), (month, 0, None, None)],
        )
        hole = package(raw4, out4, symbol, "2026-08-01", "2026-09-30", 5)
        _expect(any("no ticks after history" in item for item in hole["hard_failures"]), "middle/trailing hole")

        leaked = raw / "export_info.txt"
        leaked.write_text("complete=1\nlogin=1\n", encoding="ascii")
        try:
            parse_export_info(leaked)
            raise AssertionError("login field must be rejected")
        except ValueError as exc:
            _expect("login" not in str(exc), "rejection must not echo unexpected contents")

    today = datetime(2026, 10, 24)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "export-request.json"
        path.write_text(
            json.dumps(
                {
                    "run": True,
                    "symbol": "XAUUSDm",
                    "from": "2026-09-01",
                    "to": "2026-09-30",
                    "gap_minutes": 5,
                    "publish_release": False,
                }
            ),
            encoding="utf-8",
        )
        got = resolve_request("push", {}, path, today)
        _expect(got["run"] is True, "armed request runs")
        _expect(got["to_excl_dot"] == "2026.10.01", "exclusive end is the next day")
        _expect(got["publish_release"] == "false", "release stays off")
        path.write_text('{"run": false}\n', encoding="utf-8")
        parked = resolve_request("push", {}, path, today)
        _expect(parked["run"] is False, "run false does not export")
        path.unlink()
        missing = resolve_request("push", {}, path, today)
        _expect(missing["run"] is False, "deleted request does not export")
        path.write_text('{"run": true, "symbol": "XAUUSDm", "login": "1"}\n', encoding="utf-8")
        try:
            resolve_request("push", {}, path, today)
            raise AssertionError("unexpected request field must fail")
        except ValueError as exc:
            _expect("login" not in str(exc), "request rejection must not echo the field")
        dispatched = resolve_request(
            "workflow_dispatch",
            {"symbol": "XAUUSDm", "from": "2026-09-01", "to": "latest", "gap_minutes": "5", "publish_release": "false"},
            path,
            today,
        )
        _expect(dispatched["date_to"] == "2026-10-24", "latest is the UTC day passed in")
        _expect(dispatched["run"] is True, "dispatch ignores run:false in the file")
    print("validate_ticks self-test passed")


def resolve_request(event, dispatch, request_path, today):
    """Decide whether a workflow run may start the MT5 export.

    A push runs only when data/export-request.json exists and has "run": true.
    Removing the file, or any other commit, must not fall through to the
    2024-latest default. workflow_dispatch uses its own inputs and ignores the file.
    """
    if event == "push":
        path = Path(request_path)
        if not path.is_file():
            return {"run": False, "reason": "request file is absent"}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("request file is not valid JSON") from exc
        if not isinstance(data, dict):
            raise ValueError("request file must be an object")
        extra = set(data) - {"run", "symbol", "from", "to", "gap_minutes", "publish_release"}
        if extra:
            raise ValueError("request file has an unexpected field")
        if data.get("run") is not True:
            return {"run": False, "reason": "run is not true"}
        symbol = data.get("symbol")
        date_from = data.get("from")
        date_to = data.get("to")
        gap = data.get("gap_minutes", 5)
        release = data.get("publish_release", False)
        if not isinstance(release, bool):
            raise ValueError("publish_release must be a boolean")
    elif event == "workflow_dispatch":
        symbol = dispatch.get("symbol") or "XAUUSDm"
        date_from = dispatch.get("from") or "2024-01-01"
        date_to = dispatch.get("to") or "latest"
        gap = dispatch.get("gap_minutes") or "5"
        release = str(dispatch.get("publish_release", "")).lower() == "true"
        if date_to == "latest":
            date_to = today.strftime("%Y-%m-%d")
    else:
        return {"run": False, "reason": "event does not export"}

    if not isinstance(symbol, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9._]{0,31}", symbol):
        raise ValueError("symbol is invalid")
    if not isinstance(date_from, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_from):
        raise ValueError("from must be YYYY-MM-DD")
    if not isinstance(date_to, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_to):
        raise ValueError("to must be YYYY-MM-DD")
    start = datetime.strptime(date_from, "%Y-%m-%d")
    end = datetime.strptime(date_to, "%Y-%m-%d")
    if start > end:
        raise ValueError("from is after to")
    if start < datetime(2000, 1, 1) or end > datetime(2099, 12, 31):
        raise ValueError("date is outside 2000-2099")
    if isinstance(gap, bool) or not isinstance(gap, (int, str)):
        raise ValueError("gap_minutes must be an integer")
    if isinstance(gap, str):
        if not re.fullmatch(r"\d+", gap):
            raise ValueError("gap_minutes must be an integer")
        gap = int(gap)
    if gap < 1 or gap > 240:
        raise ValueError("gap_minutes must be from 1 to 240")
    exclusive = end + timedelta(days=1)
    months = (end.year - start.year) * 12 + (end.month - start.month) + 1
    return {
        "run": True,
        "symbol": symbol,
        "date_from": start.strftime("%Y-%m-%d"),
        "date_to": end.strftime("%Y-%m-%d"),
        "from_dot": start.strftime("%Y.%m.%d"),
        "to_excl_dot": exclusive.strftime("%Y.%m.%d"),
        "gap": str(gap),
        "publish_release": "true" if release else "false",
        "months": months,
    }


def write_github_output(result):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        raise RuntimeError("GITHUB_OUTPUT is not set")
    fields = ("run", "symbol", "date_from", "date_to", "from_dot", "to_excl_dot", "gap", "publish_release")
    lines = []
    for key in fields:
        if key == "run":
            value = "true" if result.get("run") else "false"
        else:
            value = "" if not result.get("run") else str(result.get(key, ""))
        if "\n" in value or "\r" in value:
            raise RuntimeError("refusing to write a multiline output")
        lines.append(f"{key}={value}")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--resolve-request" in argv:
        slot = argv.index("--resolve-request")
        if slot + 1 >= len(argv):
            raise SystemExit("missing request file path")
        today = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
        result = resolve_request(
            os.environ.get("EXPORT_EVENT", ""),
            {
                "symbol": os.environ.get("EXPORT_SYMBOL", ""),
                "from": os.environ.get("EXPORT_FROM", ""),
                "to": os.environ.get("EXPORT_TO", ""),
                "gap_minutes": os.environ.get("EXPORT_GAP", ""),
                "publish_release": os.environ.get("EXPORT_RELEASE", ""),
            },
            argv[slot + 1],
            today,
        )
        if result.get("run") and result.get("months", 0) > 3:
            print(
                f"::warning::Requested {result['months']} months. Artifact storage on GitHub Free is 500 MB, "
                "public artifacts expire within 90 days, and the job is killed at 6 hours."
            )
        reason = result.get("reason", "")
        if reason:
            print(reason)
        else:
            print(
                f"Export {result.get('symbol', '')} {result.get('date_from', '')} .. {result.get('date_to', '')}"
            )
        write_github_output(result)
        return 0
    args = {}
    tokens = argv[1:]
    i = 0
    while i < len(tokens):
        key = tokens[i]
        if not key.startswith("--") or i + 1 >= len(tokens):
            raise SystemExit("usage: validate_ticks.py --raw DIR --out DIR --symbol SYM --date-from YYYY-MM-DD --date-to YYYY-MM-DD --gap-minutes N")
        args[key[2:]] = tokens[i + 1]
        i += 2
    required = ["raw", "out", "symbol", "date-from", "date-to", "gap-minutes"]
    missing = [name for name in required if name not in args]
    if missing:
        raise SystemExit("missing " + ", ".join(missing))
    result = package(
        args["raw"],
        args["out"],
        args["symbol"],
        args["date-from"],
        args["date-to"],
        int(args["gap-minutes"]),
    )
    rows = sum(month["row_count"] for month in result["months"])
    print(
        f"validation ok={str(result['ok']).lower()} months={len(result['months'])} rows={rows} hard={len(result['hard_failures'])}"
    )
    for item in result["hard_failures"]:
        print("failure: " + item)
    for item in result["warnings"]:
        print("warning: " + item)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        print("failure: " + str(exc))
        sys.exit(2)
