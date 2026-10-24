#!/usr/bin/env python3
"""Санитайзер дневного экспорта демо-форварда.

Принимает только DEMO и три CSV без полей счёта. Кладёт их в
research/demo-forward и рядом собирает trades.json для compare.
"""

from __future__ import annotations

import csv
import io
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREP = ROOT / "research" / "demo-forward"
WORKFLOW = ROOT / ".github" / "workflows" / "demo-forward-monitor.yml"

IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
SECRET_WORD_RE = re.compile(r"(?i)\b(login|password|server|account)\b")
TIME_RE = re.compile(r"^\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2}$")
NUM_RE = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")
DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

DEAL_FIELDS = [
    "time", "symbol", "type", "direction", "volume", "price",
    "commission", "swap", "profit", "magic", "position",
]
POSITION_FIELDS = [
    "time_open", "symbol", "type", "volume", "price_open",
    "sl", "tp", "swap", "profit", "magic",
]
TRADE_FIELDS = [
    "entry_time", "exit_time", "side", "volume", "entry_price",
    "exit_price", "sl", "net_pnl", "exit_reason", "comment",
]
MODES = {"DEMO", "REAL", "CONTEST", "UNKNOWN"}
EXIT_REASONS = {"sl", "tp", "expert", "client", "other"}
COMMENT_RE = re.compile(r"^[A-Za-z0-9 ._#-]{0,40}$")

SET_INT = {
    "TradingTimeframe": 16385,
    "MaPeriod": 200,
    "HmaPeriod": 21,
    "CciPeriod": 20,
    "HtfTimeframe": 16388,
    "HtfEmaPeriod": 50,
    "TradeSide": 1,
    "ExitBars": 24,
    "AtrPeriod": 14,
    "DayTrendFilter": 1,
    "DayStructureLen": 5,
    "DayEmaPeriod": 50,
    "RegimeMode": 0,
    "RegimeTimeframe": 16408,
    "RegimePeriod": 20,
    "AvoidNewsMinutes": 0,
    "MagicNumber": 71012,
    "TrailingMode": 0,
}
SET_BOOL = {
    "UseHma": "true",
    "UseCci": "true",
    "UseHtf": "true",
    "ExitOnOpposite": "false",
    "NewsNFP": "true",
    "NewsCPI": "true",
    "NewsFOMC": "true",
    "NewsISM": "true",
    "CloseOnSlippage": "false",
    "UseRiskGuard": "false",
    "RiskGuardReset": "false",
}
SET_FLOAT = {
    "CciLevel": 100.0,
    "StopAtrMult": 3.0,
    "MinSLPoints": 1000.0,
    "RiskReward": 0.0,
    "RegimeThreshold": 0.30,
    "RiskPercent": 1.0,
    "MaxRiskOvershoot": 1.5,
    "MaxAccountRiskPercent": 0.0,
    "MaxSpreadToSL": 0.10,
    "MaxSlippageToSL": 0.10,
    "TrailingStartFactor": 0.5,
    "BreakevenOffsetPoints": 175.0,
    "SyncTrailStepPoints": 0.0,
}
INI_LINES = [
    "[Common]",
    "ProxyEnable=0",
    "NewsEnable=0",
    "[Experts]",
    "AllowLiveTrading=1",
    "AllowDllImport=0",
    "Enabled=1",
    "Account=1",
    "Profile=1",
    "Chart=0",
    "[StartUp]",
    "Symbol=XAUUSDm",
    "Period=H1",
    "Expert=experts\\hybrid\\hybrid-alchemist_v1.0",
    "ExpertParameters=candidate-long24.set",
    "ShutdownTerminal=0",
]


def _fail(message):
    raise ValueError(message)


def _rows(text, fields):
    if IP_RE.search(text) or SECRET_WORD_RE.search(text):
        _fail("export contains a forbidden token")
    if text.startswith("\ufeff"):
        _fail("export has a BOM")
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames != fields:
        _fail("export header is unexpected")
    rows = []
    for row in reader:
        if None in row or any(key not in fields for key in row):
            _fail("export row has an unexpected column")
        rows.append({key: (row[key] or "").strip() for key in fields})
    return rows


def _num(text, low, high):
    if not NUM_RE.fullmatch(text):
        _fail("export number is invalid")
    value = float(text)
    if value < low or value > high:
        _fail("export number is out of range")
    return value


def _time(text):
    if not TIME_RE.fullmatch(text):
        _fail("export time is invalid")
    return text


def check_deals(text):
    rows = _rows(text, DEAL_FIELDS)
    for row in rows:
        _time(row["time"])
        if row["symbol"] != "XAUUSDm":
            _fail("export symbol is unexpected")
        if row["type"] not in ("buy", "sell"):
            _fail("export deal type is invalid")
        if row["direction"] not in ("in", "out", "inout", "out_by"):
            _fail("export direction is invalid")
        _num(row["volume"], 0.01, 200.0)
        _num(row["price"], 100.0, 20000.0)
        _num(row["commission"], -1000000.0, 1000000.0)
        _num(row["swap"], -1000000.0, 1000000.0)
        _num(row["profit"], -1000000.0, 1000000.0)
        if row["magic"] != "71012":
            _fail("export magic is unexpected")
        if not re.fullmatch(r"[0-9]{1,20}", row["position"]):
            _fail("export position id is invalid")
    return rows


def check_positions(text):
    rows = _rows(text, POSITION_FIELDS)
    for row in rows:
        _time(row["time_open"])
        if row["symbol"] != "XAUUSDm":
            _fail("export symbol is unexpected")
        if row["type"] not in ("buy", "sell"):
            _fail("export position type is invalid")
        _num(row["volume"], 0.01, 200.0)
        _num(row["price_open"], 100.0, 20000.0)
        _num(row["sl"], 0.0, 20000.0)
        _num(row["tp"], 0.0, 20000.0)
        _num(row["swap"], -1000000.0, 1000000.0)
        _num(row["profit"], -1000000.0, 1000000.0)
        if row["magic"] != "71012":
            _fail("export magic is unexpected")
    return rows


def check_trades(text):
    rows = _rows(text, TRADE_FIELDS)
    for row in rows:
        _time(row["entry_time"])
        _time(row["exit_time"])
        if row["side"] not in ("long", "short"):
            _fail("export side is invalid")
        _num(row["volume"], 0.01, 200.0)
        _num(row["entry_price"], 100.0, 20000.0)
        _num(row["exit_price"], 100.0, 20000.0)
        _num(row["sl"], 0.0, 20000.0)
        _num(row["net_pnl"], -1000000.0, 1000000.0)
        if row["exit_reason"] not in EXIT_REASONS:
            _fail("export exit reason is invalid")
        if not COMMENT_RE.fullmatch(row["comment"]):
            _fail("export comment is invalid")
    return rows


def check_mode(text):
    if text not in {mode + "\n" for mode in MODES}:
        _fail("export mode is invalid")
    return text.strip()


def check_dir(path: Path):
    mode = check_mode((path / "demo-forward-mode.txt").read_text(encoding="utf-8"))
    if mode != "DEMO":
        _fail("export account mode is not DEMO")
    deals = (path / "demo-forward-deals.csv").read_text(encoding="utf-8")
    positions = (path / "demo-forward-positions.csv").read_text(encoding="utf-8")
    trades = (path / "demo-forward-trades.csv").read_text(encoding="utf-8")
    return {
        "deals": check_deals(deals),
        "positions": check_positions(positions),
        "trades": check_trades(trades),
        "deals_text": _rewrite(DEAL_FIELDS, check_deals(deals)),
        "positions_text": _rewrite(POSITION_FIELDS, check_positions(positions)),
        "trades_text": _rewrite(TRADE_FIELDS, check_trades(trades)),
    }


def _rewrite(fields, rows):
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buffer.getvalue()


def trades_json(rows):
    payload = []
    for row in rows:
        sl = float(row["sl"])
        payload.append(
            {
                "entry_time": row["entry_time"],
                "exit_time": row["exit_time"],
                "side": row["side"],
                "volume": float(row["volume"]),
                "entry_price": float(row["entry_price"]),
                "exit_price": float(row["exit_price"]),
                "sl": None if sl == 0.0 else sl,
                "profit": float(row["net_pnl"]),
                "net_pnl": float(row["net_pnl"]),
                "exit_reason": row["exit_reason"],
                "comment": row["comment"],
            }
        )
    return json.dumps({"trades": payload}, ensure_ascii=False, indent=2) + "\n"


def stage(src: Path, out_root: Path, day: str):
    if not DAY_RE.fullmatch(day):
        _fail("export day is invalid")
    checked = check_dir(src)
    documents = {
        "deals.csv": checked["deals_text"],
        "positions.csv": checked["positions_text"],
        "trades.csv": checked["trades_text"],
        "trades.json": trades_json(checked["trades"]),
    }
    for folder in (out_root, out_root / "days" / day):
        folder.mkdir(parents=True, exist_ok=True)
        for name, text in documents.items():
            if IP_RE.search(text) or SECRET_WORD_RE.search(text):
                _fail("staged export contains a forbidden token")
            (folder / name).write_text(text, encoding="utf-8")
    return {name: len(checked[name]) for name in ("deals", "positions", "trades")}


def check_ini(text):
    if IP_RE.search(text) or re.search(r"(?i)\b(login|password|server)\b", text):
        _fail("startup ini contains a forbidden token")
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if lines != INI_LINES:
        _fail("startup ini does not match the credential-free template")
    if any(line.startswith("Script=") for line in lines):
        _fail("startup ini must not be the export script")
    return True


def _set_value(line):
    name, raw = line.split("=", 1)
    value = raw.split("||", 1)[0]
    return name, value


def check_set(text):
    if IP_RE.search(text) or re.search(r"(?i)\b(login|password|server)\b", text):
        _fail("preset contains a forbidden token")
    found = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(";"):
            continue
        if "=" not in line:
            _fail("preset line is invalid")
        name, value = _set_value(line)
        if name in found:
            _fail("preset input is duplicated")
        found[name] = value
    expected = set(SET_INT) | set(SET_BOOL) | set(SET_FLOAT) | {"NewsExtraTimes"}
    if set(found) != expected:
        _fail("preset inputs do not match the expert")
    for name, want in SET_INT.items():
        if int(found[name]) != want:
            _fail("preset integer does not match")
    for name, want in SET_BOOL.items():
        if found[name] != want:
            _fail("preset flag does not match")
    for name, want in SET_FLOAT.items():
        if abs(float(found[name]) - want) > 1e-9:
            _fail("preset number does not match")
    if found["NewsExtraTimes"] != "":
        _fail("preset news times are not empty")
    if found["TradeSide"] != "1" or found["ExitBars"] != "24":
        _fail("preset candidate overrides are missing")
    if found["UseRiskGuard"] != "false" or found["RiskGuardReset"] != "false":
        _fail("preset account guard is not off")
    if float(found["RiskPercent"]) != 1.0 or float(found["MaxAccountRiskPercent"]) != 0.0:
        _fail("preset risk is not 1 percent with the cap off")
    return True


def check_workflow(text):
    if "Expert=" in text:
        _fail("monitor workflow must not attach an expert")
    if "demo-forward-export" not in text or "Script=" not in text:
        _fail("monitor workflow does not run the export script")
    if "candidate-long24.set" in text or "startup-xauusdm-h1.ini" in text:
        _fail("monitor workflow must not load the live preset")
    return True


def scan_prepared():
    check_ini((PREP / "startup-xauusdm-h1.ini").read_text(encoding="utf-8"))
    check_set((PREP / "candidate-long24.set").read_text(encoding="utf-8"))
    check_workflow(WORKFLOW.read_text(encoding="utf-8"))
    deals = (PREP / "deals.csv").read_text(encoding="utf-8")
    positions = (PREP / "positions.csv").read_text(encoding="utf-8")
    trades = (PREP / "trades.csv").read_text(encoding="utf-8")
    raw_json = (PREP / "trades.json").read_text(encoding="utf-8")
    check_deals(deals)
    check_positions(positions)
    check_trades(trades)
    if IP_RE.search(raw_json) or SECRET_WORD_RE.search(raw_json):
        _fail("trades.json contains a forbidden token")
    payload = json.loads(raw_json)
    if set(payload) != {"trades"} or not isinstance(payload["trades"], list):
        _fail("trades.json shape is unexpected")
    return True


def _sample_dir(path: Path, mode="DEMO\n", comment="HAL"):
    path.mkdir(parents=True, exist_ok=True)
    (path / "demo-forward-mode.txt").write_text(mode, encoding="utf-8")
    (path / "demo-forward-deals.csv").write_text(
        "time,symbol,type,direction,volume,price,commission,swap,profit,magic,position\n"
        "2026.10.24 12:00:00,XAUUSDm,buy,in,0.01,4035.100,0.00,0.00,0.00,71012,9001\n"
        "2026.10.24 16:00:00,XAUUSDm,sell,out,0.01,4040.100,-0.10,-1.20,5.00,71012,9001\n",
        encoding="utf-8",
    )
    (path / "demo-forward-positions.csv").write_text(
        "time_open,symbol,type,volume,price_open,sl,tp,swap,profit,magic\n",
        encoding="utf-8",
    )
    (path / "demo-forward-trades.csv").write_text(
        "entry_time,exit_time,side,volume,entry_price,exit_price,sl,net_pnl,exit_reason,comment\n"
        f"2026.10.24 12:00:00,2026.10.24 16:00:00,long,0.01,4035.100,4040.100,4020.000,3.70,sl,{comment}\n",
        encoding="utf-8",
    )


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        _sample_dir(src)
        counts = stage(src, Path(tmp) / "out", "2026-10-24")
        if counts != {"deals": 2, "positions": 0, "trades": 1}:
            raise AssertionError(counts)
        staged = json.loads((Path(tmp) / "out" / "trades.json").read_text(encoding="utf-8"))
        if staged["trades"][0]["side"] != "long" or staged["trades"][0]["sl"] != 4020.0:
            raise AssertionError("trades.json")
        dotted = ".".join(("10", "1", "2", "3"))
        for mode, comment in (("REAL\n", "HAL"), ("DEMO\n", "login 1"), ("DEMO\n", dotted)):
            bad = Path(tmp) / "bad"
            if bad.exists():
                for child in bad.iterdir():
                    child.unlink()
            _sample_dir(bad, mode=mode, comment=comment)
            try:
                check_dir(bad)
                raise AssertionError("bad export accepted")
            except ValueError:
                pass
    scan_prepared()
    try:
        check_ini("[Common]\n" + "Login" + "=1\n")
        raise AssertionError("ini with credentials accepted")
    except ValueError:
        pass
    print("demo_forward_export self-test passed")


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--scan-prepared" in argv:
        scan_prepared()
        print("prepared demo-forward files accepted")
        return 0
    if "--check" in argv:
        check_dir(Path(argv[argv.index("--check") + 1]))
        print("export accepted")
        return 0
    if "--stage" in argv:
        src = Path(argv[argv.index("--stage") + 1])
        out = Path(argv[argv.index("--out") + 1])
        day = argv[argv.index("--date") + 1]
        counts = stage(src, out, day)
        print(
            "deals={deals} positions={positions} trades={trades}".format(**counts)
        )
        return 0
    raise SystemExit(
        "usage: demo_forward_export.py --self-test | --scan-prepared | --check DIR | --stage DIR --out DIR --date YYYY-MM-DD"
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        print("failure: " + str(exc))
        sys.exit(2)
