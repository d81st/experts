#!/usr/bin/env python3
"""Проверка JSON разведки демо-счёта. Лишние поля и секреты отклоняются."""

import json
import re
import sys
from pathlib import Path

KEYS = {"trade_mode", "currency", "balance_about_10k", "autotrading"}
MODES = {"DEMO", "REAL", "CONTEST", "UNKNOWN"}
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SECRET_RE = re.compile(r"(?i)\b(login|password|server|account)\b")


def _fail(message):
    raise ValueError(message)


def check_probe(text):
    if IP_RE.search(text) or SECRET_RE.search(text):
        _fail("probe contains a forbidden token")
    data = json.loads(text)
    if set(data) != KEYS:
        _fail("probe has an unexpected field")
    if data["trade_mode"] not in MODES:
        _fail("trade mode is invalid")
    if not re.fullmatch(r"[A-Z]{3}|OTHER", data["currency"]):
        _fail("currency is invalid")
    if not isinstance(data["balance_about_10k"], bool) or not isinstance(data["autotrading"], bool):
        _fail("flag is not a boolean")
    return data


def check_host(text):
    data = json.loads(text)
    allowed = {
        "runner_kind", "image_os", "image_version", "uptime_minutes",
        "runner_service_count", "runner_service_running", "runner_service_automatic",
        "terminals_before_install", "terminal_processes_before_install",
        "startup_section", "startup_key_names", "experts_enabled", "experts_account",
        "experts_profile", "experts_chart",
    }
    if set(data) - allowed:
        _fail("host facts have an unexpected field")
    if IP_RE.search(text) or SECRET_RE.search(text):
        _fail("host facts contain a forbidden token")
    return data


def self_test():
    good = check_probe(
        '{"trade_mode":"DEMO","currency":"USD","balance_about_10k":true,"autotrading":false}\n'
    )
    if good["trade_mode"] != "DEMO" or good["balance_about_10k"] is not True:
        raise AssertionError("probe")
    for bad in (
        '{"trade_mode":"DEMO","currency":"USD","balance_about_10k":true,"autotrading":false,"login":"1"}',
        '{"trade_mode":"REAL","currency":"USD","balance":10000,"balance_about_10k":true,"autotrading":false}',
        '{"trade_mode":"DEMO","currency":"US","balance_about_10k":true,"autotrading":false}',
    ):
        try:
            check_probe(bad)
            raise AssertionError("bad probe accepted")
        except ValueError:
            pass
    print("demo_forward_probe self-test passed")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--check-probe" in argv:
        text = Path(argv[argv.index("--check-probe") + 1]).read_text(encoding="utf-8")
        print(json.dumps(check_probe(text), ensure_ascii=False))
        return 0
    if "--check-host" in argv:
        text = Path(argv[argv.index("--check-host") + 1]).read_text(encoding="utf-8")
        check_host(text)
        print("host facts accepted")
        return 0
    raise SystemExit("usage: demo_forward_probe.py --self-test | --check-probe FILE | --check-host FILE")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        print("failure: " + str(exc))
        sys.exit(2)
