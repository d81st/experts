"""Сделка к сделке: наш список против отчёта MT5.

Пара — одна и та же сторона, ближайшее время входа в пределах допуска.
Дальше каждая пара получает причины, если цена, выход или объём разъехались.
Сделка без пары — отдельно: только у нас или только в MT5.
"""

from __future__ import annotations

import csv
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

from .mt5report import Mt5Trade, load_mt5


@dataclass
class OurTrade:
    entry_time: datetime
    exit_time: datetime
    side: int
    volume: float
    entry_price: float
    exit_price: float
    sl: float | None
    net_pnl: float
    exit_reason: str
    comment: str


def _parse_time(text: str) -> datetime:
    text = text.strip().replace("Z", "")
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y.%m.%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    raise ValueError(text)


def load_our_csv(path: str | Path) -> list[OurTrade]:
    trades = []
    with Path(path).open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            side_raw = row["side"].strip().lower()
            side = 1 if side_raw in ("1", "+1", "long", "buy") else -1
            sl = row.get("sl") or ""
            trades.append(
                OurTrade(
                    entry_time=_parse_time(row["entry_time"]),
                    exit_time=_parse_time(row["exit_time"]),
                    side=side,
                    volume=float(row["volume"]),
                    entry_price=float(row["entry_price"]),
                    exit_price=float(row["exit_price"]),
                    sl=None if sl in ("", "None") else float(sl),
                    net_pnl=float(row["net_pnl"]),
                    exit_reason=row.get("exit_reason") or "",
                    comment=row.get("comment") or "",
                )
            )
    return trades


def _in_window(moment: datetime, start: datetime | None, end: datetime | None) -> bool:
    if start is not None and moment < start:
        return False
    if end is not None and moment >= end:
        return False
    return True


def compare_trades(
    ours: list[OurTrade],
    mt5: list[Mt5Trade],
    *,
    start: datetime | None = None,
    end: datetime | None = None,
    entry_pair_sec: float = 180.0,
    entry_time_sec: float = 2.0,
    exit_time_sec: float = 5.0,
    price_tol: float = 0.05,
    pair_price_tol: float = 3.0,
    volume_tol: float = 0.001,
) -> dict:
    """end исключительный. В пару попадают сделки со входом в [start, end)."""
    left = [t for t in ours if _in_window(t.entry_time, start, end)]
    right = [t for t in mt5 if _in_window(t.entry_time, start, end)]
    used = [False] * len(left)
    paired = []
    mt5_only = []
    for their in right:
        best_i = None
        best_dt = None
        for i, our in enumerate(left):
            if used[i] or our.side != their.side:
                continue
            delta = abs((our.entry_time - their.entry_time).total_seconds())
            if delta > entry_pair_sec:
                continue
            if abs(our.entry_price - their.entry_price) > pair_price_tol:
                continue
            if best_dt is None or delta < best_dt:
                best_dt = delta
                best_i = i
        if best_i is None:
            mt5_only.append(_public_mt5(their))
            continue
        used[best_i] = True
        our = left[best_i]
        reasons = []
        entry_dt = (our.entry_time - their.entry_time).total_seconds()
        exit_dt = (our.exit_time - their.exit_time).total_seconds()
        entry_px = our.entry_price - their.entry_price
        exit_px = our.exit_price - their.exit_price
        if abs(entry_dt) > entry_time_sec:
            reasons.append("entry_time")
        if abs(entry_px) > price_tol:
            reasons.append("entry_price")
        if abs(exit_dt) > exit_time_sec:
            reasons.append("exit_time")
        if abs(exit_px) > price_tol:
            reasons.append("exit_price")
        if abs(our.volume - their.volume) > volume_tol:
            reasons.append("volume")
        if their.sl is not None and our.sl is not None and abs(our.sl - their.sl) > price_tol:
            reasons.append("sl")
        paired.append(
            {
                "match": not reasons,
                "reasons": reasons,
                "entry_time_delta_sec": entry_dt,
                "exit_time_delta_sec": exit_dt,
                "entry_price_delta": entry_px,
                "exit_price_delta": exit_px,
                "volume_delta": our.volume - their.volume,
                "ours": _public_our(our),
                "mt5": _public_mt5(their),
            }
        )
    ours_only = [_public_our(trade) for trade, taken in zip(left, used) if not taken]
    reason_hist: dict[str, int] = {}
    for row in paired:
        for reason in row["reasons"]:
            reason_hist[reason] = reason_hist.get(reason, 0) + 1
    return {
        "ours": len(left),
        "mt5": len(right),
        "paired": len(paired),
        "exact": sum(1 for row in paired if row["match"]),
        "paired_with_mismatch": sum(1 for row in paired if not row["match"]),
        "ours_only": len(ours_only),
        "mt5_only": len(mt5_only),
        "reason_counts": reason_hist,
        "tolerances": {
            "entry_pair_sec": entry_pair_sec,
            "entry_time_sec": entry_time_sec,
            "exit_time_sec": exit_time_sec,
            "price_tol": price_tol,
            "pair_price_tol": pair_price_tol,
            "volume_tol": volume_tol,
        },
        "pairs": paired,
        "ours_only_trades": ours_only,
        "mt5_only_trades": mt5_only,
    }


def _public_our(trade: OurTrade) -> dict:
    row = asdict(trade)
    row["entry_time"] = trade.entry_time.strftime("%Y-%m-%dT%H:%M:%S%z")
    row["exit_time"] = trade.exit_time.strftime("%Y-%m-%dT%H:%M:%S%z")
    row["side"] = "long" if trade.side == 1 else "short"
    return row


def _public_mt5(trade: Mt5Trade) -> dict:
    return {
        "entry_time": trade.entry_time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "exit_time": trade.exit_time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "side": "long" if trade.side == 1 else "short",
        "volume": trade.volume,
        "entry_price": trade.entry_price,
        "exit_price": trade.exit_price,
        "sl": trade.sl,
        "profit": trade.profit,
        "swap": trade.swap,
        "commission": trade.commission,
        "comment_out": trade.comment_out,
    }


def load_our(path: str | Path) -> list[OurTrade]:
    return load_our_csv(path)


def load_their(path: str | Path) -> list[Mt5Trade]:
    return load_mt5(path)
