"""Скачать часовые тики XAUUSD Dukascopy за 2024–2025.

Каталог повторяет datafeed: YYYY/MM/DD/HHh_ticks.bi5, месяц с нуля.
Берётся HTTP/1.1 по IPv4: HTTPS у этого хоста держит рукопожатие и
отвечает 429. Суббота и воскресенье до 21:00 UTC не запрашиваются.
404 — маркер `.missing`. В репозиторий файлы не коммитятся.
"""

from __future__ import annotations

import lzma
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, timedelta
from pathlib import Path

ROOT = Path("/tmp/dukascopy-ticks")
START = date(2024, 1, 1)
END = date(2025, 12, 31)
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
WORKERS = 6


def hours_for(day: date) -> range:
    if day.weekday() == 5:
        return range(0)
    if day.weekday() == 6:
        return range(21, 24)
    return range(24)


def destination(day: date, hour: int) -> Path:
    return ROOT / f"{day.year}" / f"{day.month - 1:02d}" / f"{day.day:02d}" / f"{hour:02d}h_ticks.bi5"


def url_for(day: date, hour: int) -> str:
    return (
        "http://datafeed.dukascopy.com/datafeed/XAUUSD/"
        f"{day.year}/{day.month - 1:02d}/{day.day:02d}/{hour:02d}h_ticks.bi5"
    )


def looks_valid(path: Path) -> bool:
    if not path.is_file() or path.stat().st_size < 8:
        return False
    try:
        raw = lzma.decompress(path.read_bytes())
    except lzma.LZMAError:
        return False
    return len(raw) % 20 == 0


def grab(day: date, hour: int) -> tuple[date, int, str]:
    path = destination(day, hour)
    marker = Path(str(path) + ".missing")
    if looks_valid(path):
        return day, hour, "have"
    if marker.exists():
        return day, hour, "missing"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(f".{time.time_ns()}.part")
    last = "fail"
    for attempt in range(3):
        if tmp.exists():
            tmp.unlink()
        proc = subprocess.run(
            [
                "curl", "-fsS", "--http1.1", "-4",
                "--connect-timeout", "8", "--max-time", "40",
                "-A", UA, "-o", str(tmp), "-w", "%{http_code}", url_for(day, hour),
            ],
            capture_output=True,
        )
        code = proc.stdout.decode().strip() or "000"
        last = code
        # Пустой 200 — час без котировок (дневной перерыв, праздник), не сбой.
        if proc.returncode == 0 and code == "200" and (not tmp.exists() or tmp.stat().st_size == 0):
            if tmp.exists():
                tmp.unlink()
            marker.write_text("empty\n", encoding="utf-8")
            return day, hour, "empty"
        if proc.returncode == 0 and code == "200" and looks_valid(tmp):
            tmp.replace(path)
            return day, hour, "ok"
        if tmp.exists():
            tmp.unlink()
        if code == "404":
            marker.write_text("404\n", encoding="utf-8")
            return day, hour, "404"
        time.sleep(1.0 + attempt)
    return day, hour, last


def all_jobs() -> list[tuple[date, int]]:
    jobs = []
    day = START
    while day <= END:
        for hour in hours_for(day):
            jobs.append((day, hour))
        day += timedelta(days=1)
    return jobs


def main() -> int:
    jobs = all_jobs()
    print(f"jobs {len(jobs)}", flush=True)
    last_fail = len(jobs)
    for pass_n in range(1, 8):
        todo = [(day, hour) for day, hour in jobs if not looks_valid(destination(day, hour)) and not Path(str(destination(day, hour)) + ".missing").exists()]
        if not todo:
            print(f"pass {pass_n} nothing left", flush=True)
            break
        ok = missing = fail = 0
        print(f"pass {pass_n} todo {len(todo)}", flush=True)
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            futures = [pool.submit(grab, day, hour) for day, hour in todo]
            for fut in as_completed(futures):
                day, hour, status = fut.result()
                if status in ("ok", "have"):
                    ok += 1
                elif status in ("404", "missing", "empty"):
                    missing += 1
                else:
                    fail += 1
                done = ok + missing + fail
                if done % 250 == 0:
                    print(f"  pass {pass_n} {done}/{len(todo)} ok {ok} missing {missing} fail {fail} at {day}", flush=True)
        print(f"pass {pass_n} ok {ok} missing {missing} fail {fail}", flush=True)
        if fail == 0:
            break
        if fail >= last_fail:
            time.sleep(20)
        last_fail = fail
    have = sum(1 for day, hour in jobs if looks_valid(destination(day, hour)))
    missing = sum(1 for day, hour in jobs if Path(str(destination(day, hour)) + ".missing").exists())
    print(f"done have={have} missing={missing} of {len(jobs)}", flush=True)
    return 0 if have + missing == len(jobs) else 1


if __name__ == "__main__":
    raise SystemExit(main())
