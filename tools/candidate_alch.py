#!/usr/bin/env python3
"""Один кандидат: hybrid-alchemist, только покупки, выход через 24 бара.

Окно (a) — 2026.01.01–2026.10.15, только реальные тики.
Окно (b) — 2024.01.01–2025.12.31, реальные тики, если отчёт их показывает,
иначе вызывающий код повторяет прогон на OHLC M1.
Холдаут с 2026.10.16 сюда не входит.
"""

import json
import os
import re
import sys
from pathlib import Path

import robot_audit as audit

EXPERT = "hybrid/hybrid-alchemist_v1.0"
PERIOD = "H1"
INPUTS = {"TradeSide": 1, "ExitBars": 24}
WINDOWS = {
    "a": {"id": "window-a", "from": "2026.01.01", "to": "2026.10.15"},
    "b": {"id": "window-b", "from": "2024.01.01", "to": "2025.12.31"},
}
MODEL_NAME = {4: "every tick based on real ticks", 1: "1-minute OHLC"}
NOTE_RE = re.compile(r"^[A-Za-z0-9 ._-]{0,80}$")


def _fail(message):
    raise ValueError(message)


class NeedOhlc(ValueError):
    """Окно (b) на модели 4 не показало реальные тики. Можно повторить на OHLC M1."""


def month_span(date_from, date_to):
    year, month = int(date_from[0:4]), int(date_from[5:7])
    end_year, end_month = int(date_to[0:4]), int(date_to[5:7])
    months = []
    while (year, month) <= (end_year, end_month):
        months.append(f"{year:04d}-{month:02d}")
        month += 1
        if month == 13:
            month = 1
            year += 1
    return months


def _history_cell(rows):
    for row in rows:
        for index, cell in enumerate(row):
            if audit._label(cell) in ("history quality", "качество истории"):
                return " ".join(row[index + 1:]).strip()
    return ""


def _labeled(rows, label):
    want = label.lower()
    for row in rows:
        for index, cell in enumerate(row):
            if audit._label(cell) == want and index + 1 < len(row):
                return row[index + 1]
    return ""


def uses_real_ticks(rows, text):
    cell = _history_cell(rows)
    if not re.search(r"(?i)real ticks|реальн", cell):
        return False
    return audit._real_ticks(audit._quality_value(rows, text))


def _covers(text, date_from, date_to):
    normalized = text.replace("-", ".")
    return date_from in normalized and date_to in normalized


def summarize(text, window, model):
    if window not in WINDOWS:
        _fail("window is invalid")
    if model not in MODEL_NAME:
        _fail("model is invalid")
    spec = WINDOWS[window]
    date_from, date_to = spec["from"], spec["to"]
    if date_to >= audit.HOLD_OUT or date_from >= audit.HOLD_OUT:
        _fail("window reaches the holdout")
    rows = [[audit.redact_text(cell) for cell in row] for row in audit.drop_secret_rows(audit.html_rows(text))]
    body = audit.rows_to_html(rows)
    plain = "\n".join(" ".join(row) for row in rows)
    audit.scan_text(body + "\n" + plain)
    covered = _covers(text, date_from, date_to) or _covers(plain, date_from, date_to)
    real = uses_real_ticks(rows, text)
    if window == "b" and model == 4 and (not covered or not real):
        raise NeedOhlc("real ticks are not available")
    if not covered:
        _fail("history window is incomplete")
    if model == 4 and not real:
        _fail("history quality is not from real ticks")
    deals = audit.closing_deals(audit._deals(rows))
    months = month_span(date_from, date_to)
    nets = {month: 0.0 for month in months}
    for deal in deals:
        day = deal["time"][:10]
        if day < date_from or day > date_to:
            _fail("deal is outside the requested window")
        key = deal["time"][:4] + "-" + deal["time"][5:7]
        if key not in nets:
            _fail("deal is outside the requested window")
        nets[key] += float(deal["net"])
    metrics = audit._metrics(rows)
    trades = metrics.get("trades", "")
    trades_n = audit._number(trades) if trades else float(len(deals))
    net = audit._number(metrics.get("net", "")) if metrics.get("net") else round(sum(float(item["net"]) for item in deals), 2)
    quality = _history_cell(rows) or audit._quality_value(rows, text)
    summary = {
        "ok": True,
        "id": spec["id"],
        "window": window,
        "expert": EXPERT,
        "preset": "long-exit24",
        "from": date_from,
        "to": date_to,
        "symbol": audit.SYMBOL,
        "period": PERIOD,
        "model": model,
        "model_name": MODEL_NAME[model],
        "inputs": dict(INPUTS),
        "trades": None if trades_n is None else int(trades_n) if float(trades_n).is_integer() else trades_n,
        "closed_deals": len(deals),
        "net": net,
        "profit_factor": metrics.get("profit_factor", ""),
        "expected_payoff": metrics.get("expected_payoff", ""),
        "recovery_factor": metrics.get("recovery_factor", ""),
        "balance_dd_abs": metrics.get("balance_dd_abs", ""),
        "balance_dd_max": metrics.get("balance_dd_max", ""),
        "balance_dd_rel": metrics.get("balance_dd_rel", ""),
        "equity_dd_abs": metrics.get("equity_dd_abs", ""),
        "equity_dd_max": metrics.get("equity_dd_max", ""),
        "equity_dd_rel": metrics.get("equity_dd_rel", ""),
        "history_quality": quality,
        "ticks": _labeled(rows, "Ticks").replace(" ", ""),
        "bars": _labeled(rows, "Bars").replace(" ", ""),
        "terminal_build": audit._build(text),
        "months": {month: round(value, 2) for month, value in nets.items()},
    }
    return {"html": body, "deals": deals, "summary": summary}


def write_sanitized(text, window, model, out_dir, xml_text=None):
    parsed = summarize(text, window, model)
    spec_id = parsed["summary"]["id"]
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / f"{spec_id}.htm").write_text(parsed["html"], encoding="utf-8")
    lines = ["time,type,direction,volume,price,commission,swap,profit,net"]
    for deal in parsed["deals"]:
        lines.append(",".join([
            deal["time"], deal["type"], deal["direction"], deal["volume"], deal["price"],
            deal["commission"], deal["swap"], deal["profit"], deal["net"],
        ]))
    (out / f"{spec_id}.deals.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / f"{spec_id}.summary.json").write_text(
        json.dumps(parsed["summary"], ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    if xml_text is not None:
        cleaned = audit.redact_text(xml_text)
        audit.scan_text(cleaned)
        (out / f"{spec_id}.xml").write_text(cleaned, encoding="utf-8")
    return parsed["summary"]


def spec():
    if set(INPUTS) != {"TradeSide", "ExitBars"}:
        _fail("inputs are not the two allowed overrides")
    if INPUTS["TradeSide"] != 1 or INPUTS["ExitBars"] != 24:
        _fail("override values are wrong")
    windows = []
    for key in ("a", "b"):
        item = dict(WINDOWS[key])
        if item["to"] >= audit.HOLD_OUT:
            _fail("window reaches the holdout")
        item["window"] = key
        item["model"] = 4
        item["fallback_ohlc"] = key == "b"
        windows.append(item)
    return {
        "expert": EXPERT,
        "period": PERIOD,
        "symbol": audit.SYMBOL,
        "delay": audit.DELAY,
        "deposit": audit.DEPOSIT,
        "currency": "USD",
        "leverage": audit.LEVERAGE,
        "inputs": dict(INPUTS),
        "windows": windows,
    }


def check_request(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if set(data) != {"run", "note"}:
        _fail("request has an unexpected field")
    if not isinstance(data["note"], str) or not NOTE_RE.fullmatch(data["note"]):
        _fail("request note is invalid")
    if data["run"] is True:
        return True
    if data["run"] is False:
        return False
    _fail("run must be a boolean")
    return False


def _sample(period, quality, deals):
    deal_rows = "\n".join(
        "<tr><td>{time}</td><td>2</td><td>XAUUSDm</td><td>buy</td><td>out</td>"
        "<td>0.10</td><td>2700.00</td><td>1</td><td>0.00</td><td>0.00</td>"
        "<td>{profit}</td><td>10000.00</td><td>tp</td></tr>".format(time=when, profit=profit)
        for when, profit in deals
    )
    return """<!DOCTYPE html><body><table>
<tr><td>Account:</td><td>12345678</td><td>Server:</td><td>Exness-MT5Trial9</td></tr>
<tr><td>Broker-Live01</td><td>10.1.2.3</td></tr>
<tr><td>Period:</td><td>H1 ({period})</td></tr>
<tr><td>History Quality:</td><td>{quality}</td></tr>
<tr><td>Bars:</td><td>100</td><td>Ticks:</td><td>2000</td></tr>
<tr><td>Build</td><td>6283</td></tr>
<tr><td>Total Net Profit:</td><td>150.50</td><td>Balance Drawdown Absolute:</td><td>40.00</td><td>Equity Drawdown Absolute:</td><td>55.25</td></tr>
<tr><td>Profit Factor:</td><td>1.40</td><td>Balance Drawdown Maximal:</td><td>80.00 (8.00%)</td><td>Equity Drawdown Maximal:</td><td>90.00 (9.00%)</td></tr>
<tr><td>Expected Payoff:</td><td>75.25</td><td>Balance Drawdown Relative:</td><td>8.00% (80.00)</td><td>Equity Drawdown Relative:</td><td>9.00% (90.00)</td></tr>
<tr><td>Recovery Factor:</td><td>1.88</td><td>Total Trades:</td><td>1</td></tr>
<tr><td>Time</td><td>Deal</td><td>Symbol</td><td>Type</td><td>Direction</td><td>Volume</td><td>Price</td><td>Order</td><td>Commission</td><td>Swap</td><td>Profit</td><td>Balance</td><td>Comment</td></tr>
{deals}
</table></body>
""".format(period=period, quality=quality, deals=deal_rows)


def self_test():
    plan = spec()
    if plan["inputs"] != {"TradeSide": 1, "ExitBars": 24}:
        raise AssertionError("inputs")
    if plan["windows"][0]["to"] != "2026.10.15" or plan["windows"][1]["to"] != "2025.12.31":
        raise AssertionError("windows")
    if plan["windows"][0]["fallback_ohlc"] or not plan["windows"][1]["fallback_ohlc"]:
        raise AssertionError("fallback")
    if not check_request_text('{"run": true, "note": "alch-long24-1"}'):
        raise AssertionError("request")
    if check_request_text('{"run": false, "note": "off"}'):
        raise AssertionError("disarmed")
    sample_a = _sample("2026.01.01 - 2026.10.15", "100% real ticks", [("2026.02.02 10:00:00", "150.50")])
    parsed = summarize(sample_a, "a", 4)
    if parsed["summary"]["trades"] != 1 or parsed["summary"]["net"] != 150.50:
        raise AssertionError("metrics")
    if parsed["summary"]["model_name"] != "every tick based on real ticks":
        raise AssertionError("model name")
    if "12345678" in parsed["html"] or "10.1.2.3" in parsed["html"]:
        raise AssertionError("secret survived")
    os.environ["MT5_SERVER"] = "Broker-Live01"
    try:
        hidden = summarize(sample_a, "a", 4)
        if "Broker-Live01" in hidden["html"]:
            raise AssertionError("server cell survived")
    finally:
        os.environ.pop("MT5_SERVER", None)
    bare = _sample("2024.01.01 - 2025.12.31", "n/a", [("2024.03.04 10:00:00", "10.00")])
    try:
        summarize(bare, "b", 4)
        raise AssertionError("missing ticks must fall back")
    except NeedOhlc:
        pass
    ohlc = summarize(bare, "b", 1)
    if ohlc["summary"]["model_name"] != "1-minute OHLC":
        raise AssertionError("ohlc model")
    if ohlc["summary"]["months"]["2024-03"] != 10.0 or ohlc["summary"]["months"]["2025-12"] != 0:
        raise AssertionError("prior months")
    real_b = _sample("2024.01.01 - 2025.12.31", "100% real ticks", [("2025.11.02 10:00:00", "10.00")])
    kept = summarize(real_b, "b", 4)
    if kept["summary"]["model"] != 4:
        raise AssertionError("prior real ticks")
    leaked = _sample("2026.01.01 - 2026.10.15", "100% real ticks", [("2026.10.16 00:00:01", "1.00")])
    try:
        summarize(leaked, "a", 4)
        raise AssertionError("holdout must fail")
    except ValueError as exc:
        if "holdout" not in str(exc):
            raise
    outside = _sample("2024.01.01 - 2025.12.31", "n/a", [("2026.01.02 00:00:00", "1.00")])
    try:
        summarize(outside, "b", 1)
        raise AssertionError("2026 deal must fail on the prior window")
    except ValueError as exc:
        if "window" not in str(exc):
            raise
    print("candidate_alch self-test passed")


def check_request_text(text):
    import tempfile

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(text)
        path = handle.name
    try:
        return check_request(path)
    finally:
        os.unlink(path)


def main(argv):
    if "--self-test" in argv:
        self_test()
        return 0
    if "--resolve-request" in argv:
        armed = check_request(argv[argv.index("--resolve-request") + 1])
        path = os.environ.get("GITHUB_OUTPUT")
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("run=" + ("true" if armed else "false") + "\n")
        print("run" if armed else "run skipped")
        return 0
    if "--emit" in argv:
        print(json.dumps(spec(), ensure_ascii=False))
        return 0
    if "--sanitize" in argv:
        slot = argv.index("--sanitize")
        window = argv[argv.index("--window") + 1]
        model = int(argv[argv.index("--model") + 1])
        out_dir = argv[argv.index("--out") + 1]
        text = audit.load_text(argv[slot + 1])
        xml_text = None
        if "--xml" in argv:
            xml_path = Path(argv[argv.index("--xml") + 1])
            if xml_path.is_file():
                xml_text = audit.scrub_xml(audit.load_text(xml_path))
        summary = write_sanitized(text, window, model, out_dir, xml_text)
        print(
            f"{summary['id']} model={summary['model_name']} trades={summary['trades']} "
            f"net={summary['net']} quality={summary['history_quality'] or 'missing'}"
        )
        return 0
    if "--scan-dir" in argv:
        audit.scan_dir(argv[argv.index("--scan-dir") + 1])
        print("scan passed")
        return 0
    raise SystemExit(
        "usage: candidate_alch.py --self-test | --resolve-request FILE | --emit | "
        "--sanitize FILE --window a|b --model 4|1 --out DIR [--xml FILE] | --scan-dir DIR"
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except NeedOhlc as exc:
        print("failure: " + str(exc))
        sys.exit(4)
    except ValueError as exc:
        message = str(exc)
        print("failure: " + message)
        if "holdout" in message:
            sys.exit(3)
        sys.exit(2)
