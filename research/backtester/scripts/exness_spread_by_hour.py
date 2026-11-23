"""Медиана спреда Exness XAUUSDm по часу Нью-Йорка.

Окно только 2026-01-01 .. 2026-10-15. Тик 2026-10-16 и позже не читается:
итератор обрывается на исключительной границе. В вывод попадают 24 числа,
не котировки.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from backtester.session import et_hour_minute
from backtester.ticks import iter_ticks

HOLDOUT = int(datetime(2026, 10, 16, tzinfo=timezone.utc).timestamp() * 1000)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: exness_spread_by_hour.py OUT.json TICKS...", file=sys.stderr)
        return 2
    out = Path(argv[1])
    counts = [Counter() for _ in range(24)]
    seen = 0
    for tick in iter_ticks(argv[2:], "exness", end_msc=HOLDOUT):
        if tick.time_msc >= HOLDOUT:
            raise SystemExit("отказ: в поток попал тик холдаута")
        hour, _minute = et_hour_minute(tick.time_msc)
        mills = int(round((tick.ask - tick.bid) * 1000.0))
        counts[hour][mills] += 1
        seen += 1
        if seen % 5_000_000 == 0:
            print(f"… {seen}", file=sys.stderr)

    def median(counter: Counter) -> float | None:
        total = sum(counter.values())
        if total == 0:
            return None
        left = (total - 1) // 2
        right = total // 2
        running = 0
        first = None
        second = None
        for mills in sorted(counter):
            running += counter[mills]
            if first is None and running > left:
                first = mills
            if running > right:
                second = mills
                break
        return (first + second) / 2.0 / 1000.0

    hours = [median(counter) for counter in counts]
    payload = {
        "clock": "America/New_York",
        "source": "Exness XAUUSDm ticks 2026-01-01..2026-10-15",
        "stat": "median ask-bid",
        "ticks": seen,
        "hours": hours,
        "counts": [sum(counter.values()) for counter in counts],
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ticks": seen, "hours": hours}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
