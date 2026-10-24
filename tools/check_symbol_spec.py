#!/usr/bin/env python3
"""Проверка JSON спецификации символа перед коммитом.

Файл должен содержать только поля SymbolInfo и время сервера.
Логин, счёт, баланс, имя сервера и IP отклоняются, значения не печатаются.
"""

import json
import os
import re
import sys
from pathlib import Path

IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SYMBOL_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._]{0,31}$")
CLOCK_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
HHMM_RE = re.compile(r"^\d{2}:\d{2}$")
NAME_RE = re.compile(r"^[A-Z0-9_]+$")
FLAG_RE = re.compile(r"^(?:SYMBOL_[A-Z0-9_]+|bit_[0-9]+)$")
CURRENCY_RE = re.compile(r"^[A-Z0-9]{1,16}$")
TERMINAL_RE = re.compile(r"^[A-Za-z0-9 ._-]{1,80}$")
DAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
DAY_NAMES = ("SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "UNKNOWN")
ERRORS = {"", "job_file_missing", "bad_job", "not_connected", "symbol_not_selected", "write_failed"}
FORBIDDEN_KEYS = {
    "login",
    "password",
    "account",
    "balance",
    "equity",
    "credit",
    "server",
    "ip",
    "email",
    "phone",
    "investor",
}
TOP_KEYS = {
    "ok",
    "error",
    "script_version",
    "symbol",
    "captured_at",
    "captured_date",
    "terminal_build",
    "terminal_name",
    "server_utc_offset_seconds",
    "time_gmt",
    "time_trade_server",
    "digits",
    "point",
    "trade_contract_size",
    "trade_tick_size",
    "trade_tick_value",
    "trade_tick_value_profit",
    "trade_tick_value_loss",
    "volume_min",
    "volume_max",
    "volume_step",
    "volume_limit",
    "trade_stops_level",
    "trade_freeze_level",
    "trade_calc_mode",
    "trade_exemode",
    "filling_mode",
    "order_mode",
    "expiration_mode",
    "swap_mode",
    "swap_long",
    "swap_short",
    "swap_rollover3days",
    "swap_weekday",
    "margin_initial",
    "margin_maintenance",
    "margin_rate_buy",
    "margin_rate_sell",
    "currency_base",
    "currency_profit",
    "currency_margin",
    "spread_float",
    "sessions",
}


def _fail(message):
    raise ValueError(message)


def _walk(value, found):
    if isinstance(value, dict):
        for key, item in value.items():
            if str(key).lower() in FORBIDDEN_KEYS:
                found.append(str(key).lower())
            _walk(item, found)
    elif isinstance(value, list):
        for item in value:
            _walk(item, found)


def scan(text, data):
    if IP_RE.search(text):
        _fail("spec contains a network address")
    found = []
    _walk(data, found)
    if found:
        _fail("spec contains a forbidden field")
    login = os.environ.get("MT5_LOGIN", "")
    server = os.environ.get("MT5_SERVER", "")
    password = os.environ.get("MT5_PASSWORD", "")
    if login and re.fullmatch(r"\d{5,}", login) and re.search(rf"(?<!\d){re.escape(login)}(?!\d)", text):
        _fail("spec contains the account number")
    if server and server in text:
        _fail("spec contains the server secret")
    if password and len(password) >= 8 and re.search(r"[A-Za-z]", password) and password in text:
        _fail("spec contains the password")


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(name + " is not a number")
    return float(value)


def _named(value, prefix):
    if not isinstance(value, dict) or set(value) != {"value", "name"}:
        _fail("named field has an unexpected shape")
    if isinstance(value["value"], bool) or not isinstance(value["value"], int):
        _fail("named field value is not an integer")
    name = value["name"]
    if not isinstance(name, str) or not re.fullmatch(prefix, name):
        _fail("named field has an unexpected name")
    return value


def _flags(value, prefix):
    if not isinstance(value, dict) or set(value) != {"value", "flags"}:
        _fail("flag field has an unexpected shape")
    if isinstance(value["value"], bool) or not isinstance(value["value"], int):
        _fail("flag field value is not an integer")
    if not isinstance(value["flags"], list):
        _fail("flag field flags is not a list")
    for item in value["flags"]:
        if not isinstance(item, str) or not FLAG_RE.fullmatch(item) or not item.startswith(prefix) and not item.startswith("bit_"):
            _fail("flag field has an unexpected flag")
    return value


def _sessions(value):
    if not isinstance(value, dict) or set(value) != set(DAYS):
        _fail("sessions are missing a weekday")
    count = 0
    for day in DAYS:
        windows = value[day]
        if not isinstance(windows, list):
            _fail("session list has an unexpected shape")
        for window in windows:
            if not isinstance(window, dict) or set(window) != {"from", "to", "from_seconds", "to_seconds"}:
                _fail("session window has an unexpected shape")
            if not isinstance(window["from"], str) or not HHMM_RE.fullmatch(window["from"]):
                _fail("session start is not HH:MM")
            if not isinstance(window["to"], str) or not HHMM_RE.fullmatch(window["to"]):
                _fail("session end is not HH:MM")
            for key in ("from_seconds", "to_seconds"):
                if isinstance(window[key], bool) or not isinstance(window[key], int) or not 0 <= window[key] <= 86399:
                    _fail("session seconds are out of range")
            count += 1
    return count


def check(data, text, symbol):
    scan(text, data)
    if not isinstance(data, dict):
        _fail("spec must be an object")
    if data.get("ok") is not True:
        err = data.get("error", "")
        if err not in ERRORS:
            _fail("spec failed with an unknown error")
        _fail("spec was not captured")
    extra = set(data) - TOP_KEYS
    missing = TOP_KEYS - set(data)
    if extra or missing:
        _fail("spec has an unexpected shape")
    if data.get("error") not in ERRORS:
        _fail("spec failed with an unknown error")
    if data.get("symbol") != symbol or not isinstance(symbol, str) or not SYMBOL_RE.fullmatch(symbol):
        _fail("spec symbol does not match the request")
    if not isinstance(data["captured_at"], str) or not CLOCK_RE.fullmatch(data["captured_at"]) or not data["captured_at"].endswith("Z"):
        _fail("captured_at is not UTC")
    if data.get("captured_date") != data["captured_at"][:10] or not DATE_RE.fullmatch(data["captured_date"]):
        _fail("captured_date does not match captured_at")
    if not isinstance(data["time_gmt"], str) or data["time_gmt"] != data["captured_at"]:
        _fail("time_gmt does not match captured_at")
    if not isinstance(data["time_trade_server"], str) or not CLOCK_RE.fullmatch(data["time_trade_server"]):
        _fail("time_trade_server is not a timestamp")
    build = data["terminal_build"]
    if isinstance(build, bool) or not isinstance(build, int) or build <= 0:
        _fail("terminal_build is missing")
    if not isinstance(data["terminal_name"], str) or not TERMINAL_RE.fullmatch(data["terminal_name"]):
        _fail("terminal_name has an unexpected value")
    offset = data["server_utc_offset_seconds"]
    if isinstance(offset, bool) or not isinstance(offset, int) or not -86400 <= offset <= 86400:
        _fail("server offset is out of range")
    digits = data["digits"]
    if isinstance(digits, bool) or not isinstance(digits, int) or not 0 <= digits <= 8:
        _fail("digits are out of range")
    point = _number(data["point"], "point")
    if point <= 0:
        _fail("point is not positive")
    contract = _number(data["trade_contract_size"], "trade_contract_size")
    if contract <= 0:
        _fail("contract size is not positive")
    for key in (
        "trade_tick_size",
        "trade_tick_value",
        "trade_tick_value_profit",
        "trade_tick_value_loss",
        "volume_min",
        "volume_max",
        "volume_step",
        "volume_limit",
        "swap_long",
        "swap_short",
        "margin_initial",
        "margin_maintenance",
    ):
        _number(data[key], key)
    if _number(data["volume_min"], "volume_min") <= 0 or _number(data["volume_step"], "volume_step") <= 0:
        _fail("volume step is not positive")
    for key in ("trade_stops_level", "trade_freeze_level"):
        if isinstance(data[key], bool) or not isinstance(data[key], int) or data[key] < 0:
            _fail(key + " is not a point count")
    _named(data["trade_calc_mode"], r"SYMBOL_CALC_MODE_[A-Z0-9_]+|UNKNOWN")
    _named(data["trade_exemode"], r"SYMBOL_TRADE_EXECUTION_[A-Z0-9_]+|UNKNOWN")
    _named(data["swap_mode"], r"SYMBOL_SWAP_MODE_[A-Z0-9_]+|UNKNOWN")
    rollover = _named(data["swap_rollover3days"], r"[A-Z]+")
    if rollover["name"] not in DAY_NAMES:
        _fail("rollover day is unexpected")
    _flags(data["filling_mode"], "SYMBOL_FILLING_")
    _flags(data["order_mode"], "SYMBOL_ORDER_")
    _flags(data["expiration_mode"], "SYMBOL_EXPIRATION_")
    swaps = data["swap_weekday"]
    if not isinstance(swaps, dict) or set(swaps) != set(DAYS):
        _fail("swap weekdays are incomplete")
    for day in DAYS:
        if swaps[day] is not None:
            _number(swaps[day], "swap_weekday")
    for key in ("margin_rate_buy", "margin_rate_sell"):
        rate = data[key]
        if rate is None:
            continue
        if not isinstance(rate, dict) or set(rate) != {"initial", "maintenance"}:
            _fail("margin rate has an unexpected shape")
        _number(rate["initial"], key)
        _number(rate["maintenance"], key)
    for key in ("currency_base", "currency_profit", "currency_margin"):
        if not isinstance(data[key], str) or not CURRENCY_RE.fullmatch(data[key]):
            _fail(key + " has an unexpected value")
    if not isinstance(data["spread_float"], bool):
        _fail("spread_float is not a boolean")
    sessions = data["sessions"]
    if not isinstance(sessions, dict) or set(sessions) != {"trade", "quote"}:
        _fail("sessions have an unexpected shape")
    trade_count = _sessions(sessions["trade"])
    _sessions(sessions["quote"])
    if trade_count < 1:
        _fail("no trade sessions were returned")
    return data


def check_request(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        _fail("request must be an object")
    extra = set(data) - {"run", "symbol", "note"}
    if extra:
        _fail("request has an unexpected field")
    note = data.get("note", "")
    if not isinstance(note, str) or not re.fullmatch(r"[A-Za-z0-9 ._-]{0,80}", note):
        _fail("request note is invalid")
    if data.get("run") is not True:
        if data.get("run") is not False:
            _fail("run must be a boolean")
        return False, ""
    symbol = data.get("symbol")
    if not isinstance(symbol, str) or not SYMBOL_RE.fullmatch(symbol):
        _fail("symbol is invalid")
    return True, symbol


def _sample():
    days = {}
    for day in DAYS:
        days[day] = []
    days["monday"] = [{"from": "01:00", "to": "23:55", "from_seconds": 3600, "to_seconds": 86100}]
    swaps = {day: 1 for day in DAYS}
    swaps["wednesday"] = 3
    return {
        "ok": True,
        "error": "",
        "script_version": "1",
        "symbol": "XAUUSDm",
        "captured_at": "2026-10-24T08:00:00Z",
        "captured_date": "2026-10-24",
        "terminal_build": 6281,
        "terminal_name": "MetaTrader 5 EXNESS",
        "server_utc_offset_seconds": 0,
        "time_gmt": "2026-10-24T08:00:00Z",
        "time_trade_server": "2026-10-24T08:00:00",
        "digits": 3,
        "point": 0.001,
        "trade_contract_size": 100,
        "trade_tick_size": 0.001,
        "trade_tick_value": 0.1,
        "trade_tick_value_profit": 0.1,
        "trade_tick_value_loss": 0.1,
        "volume_min": 0.01,
        "volume_max": 100,
        "volume_step": 0.01,
        "volume_limit": 0,
        "trade_stops_level": 0,
        "trade_freeze_level": 0,
        "trade_calc_mode": {"value": 4, "name": "SYMBOL_CALC_MODE_CFD"},
        "trade_exemode": {"value": 2, "name": "SYMBOL_TRADE_EXECUTION_MARKET"},
        "filling_mode": {"value": 1, "flags": ["SYMBOL_FILLING_FOK"]},
        "order_mode": {"value": 127, "flags": ["SYMBOL_ORDER_MARKET"]},
        "expiration_mode": {"value": 1, "flags": ["SYMBOL_EXPIRATION_GTC"]},
        "swap_mode": {"value": 1, "name": "SYMBOL_SWAP_MODE_POINTS"},
        "swap_long": -5.2,
        "swap_short": 1.1,
        "swap_rollover3days": {"value": 3, "name": "WEDNESDAY"},
        "swap_weekday": swaps,
        "margin_initial": 0,
        "margin_maintenance": 0,
        "margin_rate_buy": {"initial": 1, "maintenance": 1},
        "margin_rate_sell": {"initial": 1, "maintenance": 1},
        "currency_base": "XAU",
        "currency_profit": "USD",
        "currency_margin": "USD",
        "spread_float": True,
        "sessions": {"trade": days, "quote": days},
    }


def self_test():
    sample = _sample()
    text = json.dumps(sample)
    got = check(json.loads(text), text, "XAUUSDm")
    if got["trade_contract_size"] != 100:
        raise AssertionError("contract size")
    leaked = dict(sample)
    leaked["login"] = "1"
    try:
        check(leaked, json.dumps(leaked), "XAUUSDm")
        raise AssertionError("login field must fail")
    except ValueError as exc:
        if "login" in str(exc):
            raise AssertionError("rejection must not echo the field") from exc
    armed, symbol = check_request_text('{"run": true, "symbol": "XAUUSDm", "note": "xauusdm-spec"}')
    if not armed or symbol != "XAUUSDm":
        raise AssertionError("armed request")
    parked, _symbol = check_request_text('{"run": false, "symbol": "XAUUSDm"}')
    if parked:
        raise AssertionError("disarmed request")
    print("check_symbol_spec self-test passed")


def check_request_text(text):
    import tempfile

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(text)
        path = handle.name
    try:
        return check_request(path)
    finally:
        os.unlink(path)


def summary(data):
    rollover = data["swap_rollover3days"]["name"]
    lines = [
        f"symbol={data['symbol']}",
        f"captured_at={data['captured_at']}",
        f"terminal_build={data['terminal_build']}",
        f"contract_size={data['trade_contract_size']}",
        f"tick_size={data['trade_tick_size']}",
        f"tick_value={data['trade_tick_value']}",
        f"tick_value_profit={data['trade_tick_value_profit']}",
        f"tick_value_loss={data['trade_tick_value_loss']}",
        f"volume_min={data['volume_min']}",
        f"volume_step={data['volume_step']}",
        f"volume_max={data['volume_max']}",
        f"swap_mode={data['swap_mode']['name']}",
        f"swap_long={data['swap_long']}",
        f"swap_short={data['swap_short']}",
        f"swap_rollover3days={rollover}",
        f"stops_level={data['trade_stops_level']}",
        f"freeze_level={data['trade_freeze_level']}",
        f"server_utc_offset_seconds={data['server_utc_offset_seconds']}",
        f"spread_float={str(data['spread_float']).lower()}",
        f"currency_base={data['currency_base']}",
        f"currency_profit={data['currency_profit']}",
        f"currency_margin={data['currency_margin']}",
    ]
    trade = data["sessions"]["trade"]
    for day in DAYS:
        windows = trade[day]
        if not windows:
            lines.append(f"trade_{day}=closed")
            continue
        parts = [item["from"] + "-" + item["to"] for item in windows]
        lines.append(f"trade_{day}={','.join(parts)}")
    return "\n".join(lines)


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--resolve-request" in argv:
        slot = argv.index("--resolve-request")
        armed, symbol = check_request(argv[slot + 1])
        path = os.environ.get("GITHUB_OUTPUT")
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("run=" + ("true" if armed else "false") + "\n")
                handle.write("symbol=" + (symbol if armed else "") + "\n")
        print(("run " + symbol) if armed else "run skipped")
        return 0
    if "--check" in argv:
        slot = argv.index("--check")
        spec_path = Path(argv[slot + 1])
        symbol = argv[argv.index("--symbol") + 1]
        text = spec_path.read_text(encoding="utf-8")
        data = json.loads(text)
        check(data, text, symbol)
        print(summary(data))
        return 0
    raise SystemExit("usage: check_symbol_spec.py --self-test | --resolve-request FILE | --check FILE --symbol SYM")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        print("failure: " + str(exc))
        sys.exit(2)
