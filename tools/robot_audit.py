#!/usr/bin/env python3
"""Инвентарь и разбор отчётов честного прогона роботов.

Даты прогона зашиты: 2026.01.01–2026.10.15. Холдаут с 2026.10.16
сюда не входит. Счёт, логин, сервер, IP и имя счёта в выход не попадают.
"""

import json
import os
import re
import sys
from pathlib import Path

HOLD_OUT = "2026.10.16"
DATE_FROM = "2026.01.01"
DATE_TO = "2026.10.15"
SYMBOL = "XAUUSDm"
MODEL = 4
DELAY = 200
DEPOSIT = 10000
LEVERAGE = 2000
PERIODS = {
    "M1", "M2", "M3", "M4", "M5", "M6", "M10", "M12", "M15", "M20", "M30",
    "H1", "H2", "H3", "H4", "H6", "H8", "H12", "D1", "W1", "MN1",
}
ID_RE = re.compile(r"^[a-z0-9-]{1,40}$")
EXPERT_RE = re.compile(r"^(archive|hybrid)/[A-Za-z0-9._-]{1,64}$")
NOTE_RE = re.compile(r"^[A-Za-z0-9 ._-]{0,80}$")
INPUT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,40}$")
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
HOLDOUT_RE = re.compile(
    r"2026[.\-]10[.\-](?:1[6-9]|[23]\d)|2026[.\-]1[12][.\-]|202[7-9][.\-]"
)
LABEL_RE = re.compile(
    r"^(account|login|server|name|company|ip|e-mail|email|phone|investor|"
    r"счёт|счет|логин|сервер|имя|компания)$",
    re.I,
)
MONTHS = [f"2026-{m:02d}" for m in range(1, 11)]

METRIC_KEYS = {
    "total net profit": "net",
    "чистая прибыль": "net",
    "profit factor": "profit_factor",
    "прибыльность": "profit_factor",
    "expected payoff": "expected_payoff",
    "матожидание": "expected_payoff",
    "математическое ожидание": "expected_payoff",
    "recovery factor": "recovery_factor",
    "фактор восстановления": "recovery_factor",
    "total trades": "trades",
    "всего трейдов": "trades",
    "всего сделок": "trades",
    "balance drawdown absolute": "balance_dd_abs",
    "абсолютная просадка по балансу": "balance_dd_abs",
    "balance drawdown maximal": "balance_dd_max",
    "максимальная просадка по балансу": "balance_dd_max",
    "balance drawdown relative": "balance_dd_rel",
    "относительная просадка по балансу": "balance_dd_rel",
    "equity drawdown absolute": "equity_dd_abs",
    "абсолютная просадка по средствам": "equity_dd_abs",
    "equity drawdown maximal": "equity_dd_max",
    "максимальная просадка по средствам": "equity_dd_max",
    "equity drawdown relative": "equity_dd_rel",
    "относительная просадка по средствам": "equity_dd_rel",
}


def _fail(message):
    raise ValueError(message)


def load_text(path):
    raw = Path(path).read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16")
    if raw.startswith(b"\xef\xbb\xbf"):
        _fail("report has a utf-8 bom")
    return raw.decode("utf-8")


def html_rows(text):
    rows = []
    for row in re.findall(r"<tr\b[^>]*>(.*?)</tr>", text, flags=re.I | re.S):
        cells = re.findall(r"<t[dh]\b[^>]*>(.*?)</t[dh]>", row, flags=re.I | re.S)
        clean = []
        for cell in cells:
            value = re.sub(r"<[^>]+>", "", cell)
            value = value.replace("&nbsp;", " ").replace("\xa0", " ")
            value = re.sub(r"\s+", " ", value).strip()
            clean.append(value)
        rows.append(clean)
    return rows


def _label(cell):
    return cell.strip().rstrip(":").strip().lower()


def drop_secret_rows(rows):
    kept = []
    for row in rows:
        labels = [_label(cell) for cell in row if cell]
        if any(LABEL_RE.fullmatch(label) for label in labels):
            continue
        kept.append(row)
    return kept


def redact_text(text):
    server = os.environ.get("MT5_SERVER", "")
    login = os.environ.get("MT5_LOGIN", "")
    password = os.environ.get("MT5_PASSWORD", "")
    if server and len(server) >= 4 and re.search(r"[A-Za-z]", server):
        text = text.replace(server, "[redacted]")
    if login and re.fullmatch(r"\d{5,}", login):
        text = re.sub(rf"(?<!\d){re.escape(login)}(?!\d)", "[redacted]", text)
    if password and len(password) >= 8 and re.search(r"[A-Za-z]", password):
        text = text.replace(password, "[redacted]")
    return IP_RE.sub("[redacted]", text)


def rows_to_html(rows):
    lines = ["<!DOCTYPE html>", "<html><body><table>"]
    for row in rows:
        cells = "".join(f"<td>{cell}</td>" for cell in row)
        lines.append(f"<tr>{cells}</tr>")
    lines.append("</table></body></html>")
    return "\n".join(lines) + "\n"


def scan_text(text):
    if IP_RE.search(text):
        _fail("report contains a network address")
    if HOLDOUT_RE.search(text):
        _fail("report reaches the holdout")
    if re.search(r"(?i)\b(account|login|server|password)\s*:", text):
        _fail("report still has an account label")
    login = os.environ.get("MT5_LOGIN", "")
    server = os.environ.get("MT5_SERVER", "")
    password = os.environ.get("MT5_PASSWORD", "")
    if login and re.fullmatch(r"\d{5,}", login) and re.search(rf"(?<!\d){re.escape(login)}(?!\d)", text):
        _fail("report contains the account number")
    if server and server in text:
        _fail("report contains the server secret")
    if password and len(password) >= 8 and re.search(r"[A-Za-z]", password) and password in text:
        _fail("report contains the password")


def _number(text):
    match = re.search(r"-?\d[\d ]*(?:[.,]\d+)?", text.replace("\xa0", " "))
    if not match:
        return None
    token = match.group(0).replace(" ", "").replace(",", ".")
    try:
        return float(token)
    except ValueError:
        return None


def _quality(text):
    match = re.search(
        r"(?i)(?:history quality|качество истории)[^0-9%]{0,80}([0-9]+(?:[.,][0-9]+)?\s*%|n/a)",
        text,
    )
    if not match:
        return ""
    return re.sub(r"\s+", "", match.group(1)).replace(",", ".")


def _quality_value(rows, text):
    for row in rows:
        for index, cell in enumerate(row):
            if _label(cell) not in ("history quality", "качество истории"):
                continue
            match = re.search(r"([0-9]+(?:[.,][0-9]+)?\s*%|n/a)", " ".join(row[index:]), re.I)
            if match:
                return re.sub(r"\s+", "", match.group(1)).replace(",", ".")
    return _quality(text)


def _real_ticks(quality):
    if not quality or quality.lower() == "n/a":
        return False
    if re.fullmatch(r"0+(?:\.0+)?%", quality):
        return False
    return True


def _covers_window(text):
    normalized = text.replace("-", ".")
    return DATE_FROM in normalized and DATE_TO in normalized


def _build(text):
    match = re.search(r"(?i)\bbuild\s+(\d{3,5})\b", text)
    return int(match.group(1)) if match else None


def _metrics(rows):
    found = {}
    for row in rows:
        index = 0
        while index < len(row):
            label = _label(row[index])
            key = METRIC_KEYS.get(label)
            if key and index + 1 < len(row) and key not in found:
                found[key] = row[index + 1]
                index += 2
                continue
            index += 1
    return found


def _deals(rows):
    header = None
    start = None
    for index, row in enumerate(rows):
        if row and row[0].lower() in ("time", "время") and len(row) >= 11:
            header = [cell.lower() for cell in row]
            start = index + 1
    if header is None:
        return []
    deals = []
    for row in rows[start:]:
        if len(row) < len(header):
            continue
        if not re.match(r"^\d{4}\.\d{2}\.\d{2}", row[0]):
            continue
        item = dict(zip(header, row))
        deals.append(item)
    return deals


def _direction(deal):
    for key in ("direction", "направление"):
        if key in deal:
            return deal[key].strip().lower()
    return ""


def _field(deal, *names):
    for name in names:
        if name in deal and deal[name] != "":
            return deal[name]
    return ""


def closing_deals(deals):
    out = []
    for deal in deals:
        direction = _direction(deal)
        if direction not in ("out", "in/out", "выход", "вход/выход"):
            continue
        when = deal.get("time") or deal.get("время") or ""
        if when >= HOLD_OUT:
            _fail("report reaches the holdout")
        symbol = _field(deal, "symbol", "символ")
        if symbol and symbol != SYMBOL:
            _fail("report has an unexpected symbol")
        commission = _number(_field(deal, "commission", "комиссия")) or 0.0
        swap = _number(_field(deal, "swap", "своп")) or 0.0
        profit = _number(_field(deal, "profit", "прибыль")) or 0.0
        out.append({
            "time": when,
            "type": _field(deal, "type", "тип"),
            "direction": direction,
            "volume": _field(deal, "volume", "объем", "объём"),
            "price": _field(deal, "price", "цена"),
            "commission": f"{commission:.2f}",
            "swap": f"{swap:.2f}",
            "profit": f"{profit:.2f}",
            "net": f"{commission + swap + profit:.2f}",
        })
    return out


def month_nets(deals):
    nets = {month: 0.0 for month in MONTHS}
    for deal in deals:
        month = deal["time"][:4] + "-" + deal["time"][5:7]
        if month not in nets:
            _fail("deal is outside the confirmation months")
        nets[month] += float(deal["net"])
    return {month: round(value, 2) for month, value in nets.items()}


def scrub_xml(text):
    cleaned = re.sub(
        r"(?is)<(account|login|server|name|company|ip|email|phone|investor)\b[^>]*>.*?</\1>",
        "",
        text,
    )
    return redact_text(cleaned)


def summarize(text):
    rows = [[redact_text(cell) for cell in row] for row in drop_secret_rows(html_rows(text))]
    body = rows_to_html(rows)
    plain = "\n".join(" ".join(row) for row in rows)
    scan_text(body + "\n" + plain)
    if not (_covers_window(text) or _covers_window(plain)):
        _fail("history window is incomplete")
    quality = _quality_value(rows, text)
    if not _real_ticks(quality):
        _fail("history quality is not from real ticks")
    metrics = _metrics(rows)
    deals = closing_deals(_deals(rows))
    months = month_nets(deals)
    trades = metrics.get("trades", "")
    trades_n = _number(trades) if trades else float(len(deals))
    net = _number(metrics.get("net", "")) if metrics.get("net") else round(sum(float(d["net"]) for d in deals), 2)
    return {
        "html": body,
        "deals": deals,
        "summary": {
            "ok": True,
            "from": DATE_FROM,
            "to": DATE_TO,
            "symbol": SYMBOL,
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
            "terminal_build": _build(text),
            "months": months,
        },
    }


def write_sanitized(text, spec_id, out_dir, xml_text=None):
    if not ID_RE.fullmatch(spec_id):
        _fail("id is invalid")
    parsed = summarize(text)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    html_path = out / f"{spec_id}.htm"
    csv_path = out / f"{spec_id}.deals.csv"
    json_path = out / f"{spec_id}.summary.json"
    html_path.write_text(parsed["html"], encoding="utf-8")
    lines = ["time,type,direction,volume,price,commission,swap,profit,net"]
    for deal in parsed["deals"]:
        lines.append(",".join([
            deal["time"], deal["type"], deal["direction"], deal["volume"], deal["price"],
            deal["commission"], deal["swap"], deal["profit"], deal["net"],
        ]))
    csv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    summary = dict(parsed["summary"])
    summary["id"] = spec_id
    json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if xml_text is not None:
        cleaned = redact_text(xml_text)
        scan_text(cleaned)
        (out / f"{spec_id}.xml").write_text(cleaned, encoding="utf-8")
    return summary


def load_plan(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if set(data) != {
        "symbol", "from", "to", "model", "delay", "deposit", "currency", "leverage", "presets",
    }:
        _fail("plan has an unexpected shape")
    if data["symbol"] != SYMBOL or data["from"] != DATE_FROM or data["to"] != DATE_TO:
        _fail("plan dates are not the confirmation window")
    if data["to"] >= HOLD_OUT:
        _fail("plan reaches the holdout")
    if data["model"] != MODEL or data["delay"] != DELAY or data["deposit"] != DEPOSIT:
        _fail("plan tester settings are not the fixed ones")
    if data["currency"] != "USD" or data["leverage"] != LEVERAGE:
        _fail("plan money settings are not the fixed ones")
    if not isinstance(data["presets"], list) or not data["presets"]:
        _fail("plan has no presets")
    root = Path(path).resolve().parent.parent
    seen = set()
    for preset in data["presets"]:
        if set(preset) != {
            "id", "batch", "expert", "preset", "role", "period", "inputs",
            "contaminated", "optimized_on", "note",
        }:
            _fail("preset has an unexpected shape")
        if not ID_RE.fullmatch(preset["id"]) or preset["id"] in seen:
            _fail("preset id is invalid")
        seen.add(preset["id"])
        if preset["batch"] not in ("a", "b", "c", "d", "e", "f"):
            _fail("preset batch is invalid")
        if not EXPERT_RE.fullmatch(preset["expert"]):
            _fail("expert path is invalid")
        mq5 = root / (preset["expert"] + ".mq5")
        if not mq5.is_file():
            _fail("expert file is missing")
        if preset["role"] not in ("current", "recommended", "benchmark", "notifier"):
            _fail("preset role is invalid")
        if preset["period"] not in PERIODS:
            _fail("chart period is invalid")
        if not isinstance(preset["contaminated"], bool):
            _fail("contamination flag is invalid")
        if not isinstance(preset["optimized_on"], str) or not re.fullmatch(r"[0-9.\-]{0,40}", preset["optimized_on"]):
            _fail("optimization window is invalid")
        if preset["contaminated"] and not preset["optimized_on"]:
            _fail("contaminated preset has no window")
        if HOLDOUT_RE.search(preset["optimized_on"]) or HOLDOUT_RE.search(preset["note"]):
            _fail("plan text reaches the holdout")
        if not isinstance(preset["note"], str) or len(preset["note"]) > 400:
            _fail("preset note is invalid")
        inputs = preset["inputs"]
        if not isinstance(inputs, dict):
            _fail("inputs are invalid")
        for key, value in inputs.items():
            if not INPUT_RE.fullmatch(key):
                _fail("input name is invalid")
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                _fail("input value is not a number")
    return data


def check_request(path, plan):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if set(data) != {"run", "note", "batches"}:
        _fail("request has an unexpected field")
    if not isinstance(data["note"], str) or not NOTE_RE.fullmatch(data["note"]):
        _fail("request note is invalid")
    if data["run"] is not True:
        if data["run"] is not False:
            _fail("run must be a boolean")
        return False, []
    batches = data["batches"]
    if not isinstance(batches, list) or not batches:
        _fail("batches are missing")
    known = {preset["batch"] for preset in plan["presets"]}
    for batch in batches:
        if batch not in known:
            _fail("batch is invalid")
    if len(set(batches)) != len(batches):
        _fail("batch is repeated")
    return True, batches


def emit_batch(plan, batch):
    rows = []
    for preset in plan["presets"]:
        if preset["batch"] != batch:
            continue
        rows.append({
            "id": preset["id"],
            "expert": preset["expert"],
            "period": preset["period"],
            "inputs": preset["inputs"],
            "symbol": plan["symbol"],
            "from": plan["from"],
            "to": plan["to"],
            "model": plan["model"],
            "delay": plan["delay"],
            "deposit": plan["deposit"],
            "currency": plan["currency"],
            "leverage": plan["leverage"],
        })
    if not rows:
        _fail("batch is empty")
    return rows


def scan_dir(path):
    root = Path(path)
    files = [item for item in root.rglob("*") if item.is_file()]
    if not files:
        _fail("nothing to scan")
    for item in files:
        text = load_text(item)
        scan_text(text)
        if item.suffix == ".json":
            data = json.loads(text)
            if isinstance(data, dict):
                keys = {str(key).lower() for key in data}
            elif isinstance(data, list):
                keys = set()
                for entry in data:
                    if isinstance(entry, dict):
                        keys.update(str(key).lower() for key in entry)
            else:
                keys = set()
            if keys & {"login", "password", "account", "server", "ip", "email", "balance", "equity"}:
                _fail("summary contains a forbidden field")


def _sample_report():
    return """<!DOCTYPE html><body><table>
<tr><td>Account:</td><td>12345678</td><td>Server:</td><td>Exness-MT5Trial9</td></tr>
<tr><td>Broker-Live01</td><td>10.1.2.3</td></tr>
<tr><td>Name:</td><td>Trader Name</td><td>Company:</td><td>Exness Technologies Ltd</td></tr>
<tr><td>Period:</td><td>M1 (2026.01.01 - 2026.10.15)</td></tr>
<tr><td colspan="2">History Quality:</td><td><b>100%</b></td></tr>
<tr><td>Build</td><td>6283</td></tr>
<tr><td>Total Net Profit:</td><td>150.50</td><td>Balance Drawdown Absolute:</td><td>40.00</td><td>Equity Drawdown Absolute:</td><td>55.25</td></tr>
<tr><td>Profit Factor:</td><td>1.40</td><td>Balance Drawdown Maximal:</td><td>80.00 (8.00%)</td><td>Equity Drawdown Maximal:</td><td>90.00 (9.00%)</td></tr>
<tr><td>Expected Payoff:</td><td>75.25</td><td>Balance Drawdown Relative:</td><td>8.00% (80.00)</td><td>Equity Drawdown Relative:</td><td>9.00% (90.00)</td></tr>
<tr><td>Recovery Factor:</td><td>1.88</td><td>Total Trades:</td><td>2</td></tr>
<tr><td>Time</td><td>Deal</td><td>Symbol</td><td>Type</td><td>Direction</td><td>Volume</td><td>Price</td><td>Order</td><td>Commission</td><td>Swap</td><td>Profit</td><td>Balance</td><td>Comment</td></tr>
<tr><td>2026.01.05 10:00:00</td><td>2</td><td>XAUUSDm</td><td>sell</td><td>out</td><td>0.10</td><td>2700.00</td><td>1</td><td>0.00</td><td>-1.50</td><td>100.00</td><td>10098.50</td><td>tp</td></tr>
<tr><td>2026.10.15 20:57:00</td><td>4</td><td>XAUUSDm</td><td>buy</td><td>out</td><td>0.10</td><td>2650.00</td><td>3</td><td>0.00</td><td>0.00</td><td>52.00</td><td>10150.50</td><td>sl</td></tr>
</table></body>
"""


def self_test():
    plan = load_plan(Path(__file__).with_name("robot_audit_plan.json"))
    ids = [preset["id"] for preset in plan["presets"]]
    if len(ids) != len(set(ids)) or "asia-breakout-trend" not in ids or "trend-channel-atr3" not in ids:
        raise AssertionError("plan ids")
    if any(preset["to"] >= HOLD_OUT for preset in []):
        raise AssertionError("holdout")
    armed, batches = check_request_text(
        '{"run": true, "note": "confirm-2026-all", "batches": ["a", "b", "c", "d", "e", "f"]}',
        plan,
    )
    if not armed or batches != ["a", "b", "c", "d", "e", "f"]:
        raise AssertionError("request")
    parked, _batches = check_request_text(
        '{"run": false, "note": "off", "batches": ["a"]}',
        plan,
    )
    if parked:
        raise AssertionError("disarmed request")
    sample = _sample_report()
    parsed = summarize(sample)
    if "12345678" in parsed["html"] or "Exness-MT5Trial9" in parsed["html"] or "Trader Name" in parsed["html"]:
        raise AssertionError("secret row survived")
    if parsed["summary"]["history_quality"] != "100%":
        raise AssertionError("quality")
    if parsed["summary"]["trades"] != 2 or parsed["summary"]["net"] != 150.50:
        raise AssertionError("metrics")
    if parsed["summary"]["months"]["2026-01"] != 98.50 or parsed["summary"]["months"]["2026-10"] != 52.00:
        raise AssertionError("months")
    if parsed["summary"]["months"]["2026-02"] != 0:
        raise AssertionError("empty month")
    if "10.1.2.3" in parsed["html"]:
        raise AssertionError("address survived")
    os.environ["MT5_SERVER"] = "Broker-Live01"
    try:
        hidden = summarize(sample)
        if "Broker-Live01" in hidden["html"] or "10.1.2.3" in hidden["html"]:
            raise AssertionError("server cell survived")
        if "[redacted]" not in hidden["html"]:
            raise AssertionError("server cell was not redacted")
    finally:
        os.environ.pop("MT5_SERVER", None)
    leaked = sample.replace("2026.10.15 20:57:00", "2026.10.16 00:00:01")
    try:
        summarize(leaked)
        raise AssertionError("holdout deal must fail")
    except ValueError as exc:
        if "holdout" not in str(exc):
            raise
    short = sample.replace("2026.01.01", "2025.06.01", 1)
    try:
        summarize(short)
        raise AssertionError("short window must fail")
    except ValueError as exc:
        if "history" not in str(exc):
            raise
    for marker in ("0%", "n/a"):
        try:
            summarize(sample.replace("<b>100%</b>", f"<b>{marker}</b>", 1))
            raise AssertionError("empty history must fail")
        except ValueError as exc:
            if "history" not in str(exc):
                raise
    print("robot_audit self-test passed")


def check_request_text(text, plan):
    import tempfile

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(text)
        path = handle.name
    try:
        return check_request(path, plan)
    finally:
        os.unlink(path)


def main(argv):
    plan_path = Path(__file__).with_name("robot_audit_plan.json")
    if "--self-test" in argv:
        self_test()
        return 0
    if "--resolve-request" in argv:
        slot = argv.index("--resolve-request")
        plan = load_plan(plan_path)
        armed, batches = check_request(argv[slot + 1], plan)
        path = os.environ.get("GITHUB_OUTPUT")
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write("run=" + ("true" if armed else "false") + "\n")
                handle.write("batches=" + json.dumps(batches) + "\n")
        print(("run " + ",".join(batches)) if armed else "run skipped")
        return 0
    if "--emit-batch" in argv:
        slot = argv.index("--emit-batch")
        plan = load_plan(plan_path)
        print(json.dumps(emit_batch(plan, argv[slot + 1]), ensure_ascii=False))
        return 0
    if "--sanitize" in argv:
        slot = argv.index("--sanitize")
        spec_id = argv[argv.index("--id") + 1]
        out_dir = argv[argv.index("--out") + 1]
        text = load_text(argv[slot + 1])
        xml_text = None
        if "--xml" in argv:
            xml_path = Path(argv[argv.index("--xml") + 1])
            if xml_path.is_file():
                xml_text = scrub_xml(load_text(xml_path))
        summary = write_sanitized(text, spec_id, out_dir, xml_text)
        print(
            f"{spec_id} trades={summary['trades']} net={summary['net']} "
            f"quality={summary['history_quality'] or 'missing'}"
        )
        return 0
    if "--scan-dir" in argv:
        scan_dir(argv[argv.index("--scan-dir") + 1])
        print("scan passed")
        return 0
    if "--require" in argv:
        path = Path(argv[argv.index("--require") + 1])
        if not path.is_file():
            print("no failures file")
            return 0
        rows = json.loads(path.read_text(encoding="utf-8"))
        if rows:
            print("failed presets: " + ",".join(row["id"] for row in rows))
            return 2
        print("every preset produced a report")
        return 0
    raise SystemExit(
        "usage: robot_audit.py --self-test | --resolve-request FILE | --emit-batch BATCH | "
        "--sanitize FILE --id ID --out DIR [--xml FILE] | --scan-dir DIR | --require FILE"
    )


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ValueError as exc:
        message = str(exc)
        print("failure: " + message)
        if "holdout" in message:
            sys.exit(3)
        if "history" in message:
            sys.exit(4)
        sys.exit(2)
