"""Сессия XAUUSDm: пауза Нью-Йорка, торговля с первого тика после неё.

Сервер Exness — UTC+0 и своё летнее время не переводит. Дыра в тиках
идёт за Америкой/Нью-Йорк:

- последний тик около 16:58 ET;
- первый тик после паузы — медиана 18:00:32 ET (p95 +158 с от 18:00).
  Летом это 22:00:30 UTC, зимой около 23:01 UTC.

Ворота по умолчанию открыты с 18:00 ET, то есть с 22:00 UTC летом и
с 23:00 UTC зимой (`--session-shift auto`). Тик 22:00:30 уже внутри
сессии: номинальные 22:01 из `sessions.trade` (дамп 2026-10-24) его
не держат. Таблица trade остаётся режимом `--session-gate trade`.

Закрыто [16:58, 18:00) ET в понедельник–четверг. Пятница закрывается
в 16:58 ET до воскресенья 18:00 ET. Суббота закрыта. Полночь UTC не
сдвигается. Праздники не моделируются. SL и TP — на любом тике.
"""

from __future__ import annotations

import calendar
from datetime import datetime, timezone

DAY_MS = 86_400_000
DAY_S = 86_400

Shift = str | int


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


_DST: dict[int, tuple[int, int]] = {}


def us_dst_bounds_msc(year: int) -> tuple[int, int]:
    cached = _DST.get(year)
    if cached is not None:
        return cached
    start = datetime(year, 3, _nth_sunday(year, 3, 2), 7, tzinfo=timezone.utc)
    end = datetime(year, 11, _nth_sunday(year, 11, 1), 6, tzinfo=timezone.utc)
    bounds = (int(start.timestamp() * 1000), int(end.timestamp() * 1000))
    _DST[year] = bounds
    return bounds


def is_us_dst(time_msc: int) -> bool:
    """Летнее время США. Сервер Exness его не переводит."""
    start, end = us_dst_bounds_msc(_utc_year(time_msc))
    return start <= time_msc < end


_YEAR_CACHE = [0, 0, 0]


def _utc_year(time_msc: int) -> int:
    """Год UTC. Границы года считаются один раз, не на каждый тик."""
    year, start, end = _YEAR_CACHE
    if start <= time_msc < end and year:
        return year
    year = datetime.fromtimestamp(time_msc / 1000.0, timezone.utc).year
    start = int(datetime(year, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
    end = int(datetime(year + 1, 1, 1, tzinfo=timezone.utc).timestamp() * 1000)
    _YEAR_CACHE[:] = [year, start, end]
    return year


def et_hour_minute(time_msc: int) -> tuple[int, int]:
    """Час и минута Нью-Йорка. Лето UTC−4, зима UTC−5, по тем же границам, что и сессия."""
    start, end = us_dst_bounds_msc(_utc_year(time_msc))
    offset_s = 4 * 3600 if start <= time_msc < end else 5 * 3600
    sec = (time_msc // 1000 - offset_s) % DAY_S
    return sec // 3600, (sec % 3600) // 60


def in_reopen_stale_window(time_msc: int, minutes: int = 2) -> bool:
    """Первые минуты после 18:00 ET. У Dukascopy там часто висит допаузная цена."""
    if minutes <= 0:
        return False
    hour, minute = et_hour_minute(time_msc)
    return hour == 18 and minute < minutes


def shift_edge(seconds: int, hours: int) -> int:
    """Сдвинуть границу. 00:00 и 24:00 остаются на месте."""
    if hours == 0 or seconds <= 0 or seconds >= DAY_S:
        return seconds
    moved = seconds + hours * 3600
    if moved <= 0 or moved >= DAY_S:
        raise ValueError(f"сдвиг сессии выносит границу за сутки: {seconds} + {hours}ч")
    return moved


def shift_ranges(
    ranges: tuple[tuple[tuple[int, int], ...], ...] | list,
    hours: int,
) -> tuple[tuple[tuple[int, int], ...], ...]:
    if hours == 0:
        return tuple(tuple(day) for day in ranges)
    shifted = []
    for day in ranges:
        shifted.append(tuple((shift_edge(start, hours), shift_edge(end, hours)) for start, end in day))
    return tuple(shifted)


class AlwaysOpen:
    def is_open(self, time_msc: int) -> bool:
        return True


class ExnessGoldSession:
    def __init__(
        self,
        shift: Shift = "auto",
        ranges: tuple[tuple[tuple[int, int], ...], ...] | None = None,
        gate: str = "quote",
    ) -> None:
        if gate not in ("quote", "trade"):
            raise ValueError("gate должен быть quote или trade")
        self.gate = gate
        if ranges is None:
            from .symbol_spec import load_xauusdm

            captured = load_xauusdm()
            ranges = captured.quote_ranges if gate == "quote" else captured.trade_ranges
        if len(ranges) != 7:
            raise ValueError("сессия: нужно 7 дней, понедельник = 0")
        self.base = tuple(tuple(day) for day in ranges)
        self.shift = shift
        self._day: int | None = None
        self._ranges: list[tuple[int, int]] = []

    def is_dst(self, time_msc: int) -> bool:
        return is_us_dst(time_msc)

    def shift_hours(self, time_msc: int) -> int:
        if self.shift == "captured":
            return 0
        if self.shift == "winter":
            return 1
        if self.shift == "auto":
            return 0 if self.is_dst(time_msc) else 1
        if isinstance(self.shift, int):
            if self.shift < 0:
                raise ValueError("сдвиг сессии < 0")
            return self.shift
        raise ValueError(f"неизвестный сдвиг сессии: {self.shift}")

    def _ranges_for_day(self, day_index: int) -> list[tuple[int, int]]:
        noon = day_index * DAY_MS + 12 * 3_600_000
        hours = self.shift_hours(noon)
        wd = weekday_mon0(day_index * DAY_MS)
        return [(shift_edge(start, hours), shift_edge(end, hours)) for start, end in self.base[wd]]

    def is_open(self, time_msc: int) -> bool:
        day = time_msc // DAY_MS
        if day != self._day:
            self._day = day
            self._ranges = self._ranges_for_day(day)
        sec = (time_msc // 1000) % DAY_S
        return any(start <= sec < end for start, end in self._ranges)
