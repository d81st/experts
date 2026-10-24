"""Торговая сессия XAUUSD.

Расписание выведено из двух наблюдений, не из SymbolInfoSessionTrade:

1. Аудит баров: дневная дыра котировок — около 20:57–22:00 летом США
   и около 21:57–23:00 зимой. Воскресенье открывается чуть позже.
2. Сделки h1-x12-st: зимой 2026 отложенный вход в 23:01, летом в 22:00:30.
   Часа 21 среди входов нет.

Это пауза COMEX 17:00–18:00 America/New_York:

- летнее время США (EDT): закрыто [21:00, 22:00) UTC;
- зимнее (EST): закрыто [22:00, 23:00) UTC.

Пятница закрывается в начале этой паузы и не открывается до воскресенья.
Суббота закрыта. Переход DST — второе воскресенье марта 07:00 UTC и
первое воскресенье ноября 06:00 UTC. Праздники биржи не моделируются.
"""

from __future__ import annotations

import calendar
from datetime import datetime, timezone

DAY_MS = 86_400_000


def weekday_mon0(time_msc: int) -> int:
    """Понедельник = 0 … воскресенье = 6. Эпоха 1970-01-01 — четверг."""
    days = time_msc // DAY_MS
    return (days + 3) % 7


def _nth_sunday(year: int, month: int, n: int) -> int:
    sundays = [
        d
        for d in calendar.Calendar().itermonthdates(year, month)
        if d.month == month and d.weekday() == 6
    ]
    return sundays[n - 1].day


class AlwaysOpen:
    def is_open(self, time_msc: int) -> bool:
        return True


class ExnessGoldSession:
    def __init__(self) -> None:
        self._dst: dict[int, tuple[int, int]] = {}
        self._day: int | None = None
        self._ranges: list[tuple[int, int]] = []

    def _dst_bounds_msc(self, year: int) -> tuple[int, int]:
        cached = self._dst.get(year)
        if cached is not None:
            return cached
        start = datetime(year, 3, _nth_sunday(year, 3, 2), 7, tzinfo=timezone.utc)
        end = datetime(year, 11, _nth_sunday(year, 11, 1), 6, tzinfo=timezone.utc)
        bounds = (int(start.timestamp() * 1000), int(end.timestamp() * 1000))
        self._dst[year] = bounds
        return bounds

    def is_dst(self, time_msc: int) -> bool:
        year = datetime.fromtimestamp(time_msc / 1000.0, timezone.utc).year
        # На границе года зимнее расписание, DST внутри года.
        start, end = self._dst_bounds_msc(year)
        return start <= time_msc < end

    def _ranges_for_day(self, day_index: int) -> list[tuple[int, int]]:
        noon = day_index * DAY_MS + 12 * 3_600_000
        dst = self.is_dst(noon)
        close_s = 21 * 3600 if dst else 22 * 3600
        open_s = 22 * 3600 if dst else 23 * 3600
        wd = weekday_mon0(day_index * DAY_MS)
        if wd == 5:  # суббота
            return []
        if wd == 6:  # воскресенье — только после открытия
            return [(open_s, 24 * 3600)]
        if wd == 4:  # пятница — до начала паузы
            return [(0, close_s)]
        return [(0, close_s), (open_s, 24 * 3600)]

    def is_open(self, time_msc: int) -> bool:
        day = time_msc // DAY_MS
        if day != self._day:
            self._day = day
            self._ranges = self._ranges_for_day(day)
        sec = (time_msc // 1000) % 86400
        return any(a <= sec < b for a, b in self._ranges)
