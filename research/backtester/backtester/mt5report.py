"""Разбор отчёта тестера MT5 (HTML или JSON) в закрытые сделки.

HTML бывает и UTF-8, и UTF-16. Строка balance — не сделка.
Стоп, если он есть, берётся из комментария выхода «sl 4035.980».
Числа с пробелом тысяч (`10 433.53`) приводятся к float.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Mt5Trade:
    entry_time: datetime
    exit_time: datetime
    side: int
    volume: float
    entry_price: float
    exit_price: float
    sl: float | None
    commission: float
    swap: float
    profit: float
    comment_in: str
    comment_out: str


def _num(text: str) -> float:
    cleaned = text.replace("\xa0", "").replace(" ", "")
    if cleaned == "":
        return 0.0
    return float(cleaned)


def _when(text: str) -> datetime:
    text = text.strip().replace("Z", "")
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(f"не разобрать время: {text}")


def _read_text(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16").replace("\r", "")
    return raw.decode("utf-8-sig").replace("\r", "")


def _rows(text: str) -> list[list[str]]:
    out = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", text, re.S):
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, re.S)
        out.append([html.unescape(re.sub(r"<[^>]+>", "", cell)).strip() for cell in cells])
    return out


_SL_RE = re.compile(r"sl\s+([0-9]+(?:\.[0-9]+)?)", re.I)


def _sl_from_comment(comment: str) -> float | None:
    match = _SL_RE.search(comment or "")
    if not match:
        return None
    return float(match.group(1))


def trades_from_deals(deals: list[dict]) -> list[Mt5Trade]:
    """FIFO: in покупает/продаёт, out закрывает самый старый остаток."""
    open_legs: list[dict] = []
    trades: list[Mt5Trade] = []
    for deal in deals:
        direction = (deal.get("direction") or "").lower()
        kind = (deal.get("type") or "").lower()
        if kind == "balance" or direction not in ("in", "out"):
            continue
        if direction == "in":
            open_legs.append(dict(deal))
            continue
        if not open_legs:
            continue
        opened = open_legs.pop(0)
        side = 1 if opened.get("type", "").lower() == "buy" else -1
        comment_out = deal.get("comment") or ""
        trades.append(
            Mt5Trade(
                entry_time=_when(opened["time"]),
                exit_time=_when(deal["time"]),
                side=side,
                volume=float(opened["volume"]),
                entry_price=float(opened["price"]),
                exit_price=float(deal["price"]),
                sl=_sl_from_comment(comment_out) or _sl_from_comment(opened.get("comment") or ""),
                commission=float(opened.get("commission") or 0) + float(deal.get("commission") or 0),
                swap=float(opened.get("swap") or 0) + float(deal.get("swap") or 0),
                profit=float(deal.get("profit") or 0),
                comment_in=opened.get("comment") or "",
                comment_out=comment_out,
            )
        )
    return trades


def parse_mt5_html(path: str | Path) -> list[Mt5Trade]:
    rows = _rows(_read_text(Path(path)))
    header = None
    for row in rows:
        if row and row[0] in ("Time", "Время") and "Deal" in row or (row and row[0] in ("Time", "Время") and len(row) >= 13):
            if row[0] in ("Time", "Время") and any(cell in ("Direction", "Направление") for cell in row):
                header = row
                break
    if header is None:
        raise ValueError(f"в {path} нет таблицы сделок")
    index = {name: pos for pos, name in enumerate(header)}

    def cell(row: list[str], *names: str) -> str:
        for name in names:
            if name in index and index[name] < len(row):
                return row[index[name]]
        return ""

    deals = []
    for row in rows:
        if len(row) != len(header):
            continue
        if not re.match(r"\d{4}[.\-]\d{2}[.\-]\d{2}", row[0]):
            continue
        deals.append(
            {
                "time": cell(row, "Time", "Время"),
                "type": cell(row, "Type", "Тип"),
                "direction": cell(row, "Direction", "Направление"),
                "volume": _num(cell(row, "Volume", "Объем", "Объём")),
                "price": _num(cell(row, "Price", "Цена")),
                "commission": _num(cell(row, "Commission", "Комиссия")),
                "swap": _num(cell(row, "Swap", "Своп")),
                "profit": _num(cell(row, "Profit", "Прибыль")),
                "comment": cell(row, "Comment", "Комментарий"),
            }
        )
    return trades_from_deals(deals)


def parse_mt5_json(path: str | Path) -> list[Mt5Trade]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(payload, dict) and "trades" in payload:
        trades = []
        for row in payload["trades"]:
            side_raw = row["side"]
            side = 1 if side_raw in (1, "long", "buy") else -1
            trades.append(
                Mt5Trade(
                    entry_time=_when(row["entry_time"]),
                    exit_time=_when(row["exit_time"]),
                    side=side,
                    volume=float(row["volume"]),
                    entry_price=float(row["entry_price"]),
                    exit_price=float(row["exit_price"]),
                    sl=None if row.get("sl") in (None, "", 0) else float(row["sl"]),
                    commission=float(row.get("commission") or 0),
                    swap=float(row.get("swap") or 0),
                    profit=float(row.get("profit") if row.get("profit") is not None else row.get("net_pnl") or 0),
                    comment_in=row.get("comment") or "",
                    comment_out=row.get("exit_reason") or "",
                )
            )
        return trades
    deals = payload["deals"] if isinstance(payload, dict) else payload
    return trades_from_deals(deals)


def load_mt5(path: str | Path) -> list[Mt5Trade]:
    path = Path(path)
    if path.suffix.lower() == ".json":
        return parse_mt5_json(path)
    head = path.read_bytes()[:200]
    if head.lstrip().startswith(b"{") or head.lstrip().startswith(b"["):
        return parse_mt5_json(path)
    return parse_mt5_html(path)
