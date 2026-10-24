"""Скачать часовые тики XAUUSD Dukascopy за 2024–2025.

Каталог повторяет datafeed: YYYY/MM/DD/HHh_ticks.bi5, месяц с нуля.
Суббота и воскресенье до 21:00 UTC не запрашиваются: там рынка нет,
а каждое обращение упирается в лимит. Уже лежащий непустой файл
не качается снова. 404 — маркер `.missing`, чтобы не долбить дыру.
В репозиторий эти файлы не коммитятся.
"""

from __future__ import annotations

import sys
import time
import urllib.error
import urllib.request
from datetime import date, timedelta
from pathlib import Path

ROOT = Path("/tmp/dukascopy-ticks")
START = date(2024, 1, 1)
END = date(2025, 12, 31)
UA = "Mozilla/5.0"


def hours_for(day: date) -> range:
    if day.weekday() == 5:
        return range(0)
    if day.weekday() == 6:
        return range(21, 24)
    return range(24)


def destination(day: date, hour: int) -> Path:
    return ROOT / f"{day.year}" / f"{day.month - 1:02d}" / f"{day.day:02d}" / f"{hour:02d}h_ticks.bi5"


def fetch(url: str) -> tuple[int, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.status, resp.read()


def main() -> int:
    day = START
    done = 0
    missing = 0
    while day <= END:
        for hour in hours_for(day):
            path = destination(day, hour)
            marker = path.with_suffix(".bi5.missing")
            if path.exists() and path.stat().st_size > 0:
                done += 1
                continue
            if marker.exists():
                missing += 1
                continue
            url = (
                "https://datafeed.dukascopy.com/datafeed/XAUUSD/"
                f"{day.year}/{day.month - 1:02d}/{day.day:02d}/{hour:02d}h_ticks.bi5"
            )
            delay = 5.0
            while True:
                try:
                    status, body = fetch(url)
                except urllib.error.HTTPError as exc:
                    if exc.code == 404:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        marker.write_text("404\n", encoding="utf-8")
                        missing += 1
                        break
                    if exc.code in (429, 503):
                        time.sleep(delay)
                        delay = min(delay * 1.5, 60.0)
                        continue
                    print(f"fail {day} {hour:02d} {exc}", file=sys.stderr)
                    time.sleep(delay)
                    continue
                except Exception as exc:
                    print(f"fail {day} {hour:02d} {exc}", file=sys.stderr)
                    time.sleep(delay)
                    delay = min(delay * 1.5, 60.0)
                    continue
                if status != 200 or not body or body[:1] == b"{":
                    time.sleep(delay)
                    delay = min(delay * 1.5, 60.0)
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(body)
                done += 1
                if done % 25 == 0:
                    print(f"saved {done} missing {missing} at {day} {hour:02d}", file=sys.stderr)
                time.sleep(0.5)
                break
        day += timedelta(days=1)
    print(f"done saved={done} missing={missing}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
