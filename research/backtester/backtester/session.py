"""Торговая сессия XAUUSDm по выгрузке терминала.

Окна берутся из sessions.trade файла data/symbol-spec/XAUUSDm.json,
серверное время UTC+0. Дамп снят 2026-10-24, в летнее время США:

- понедельник–четверг: 00:00–20:58 и 22:01–24:00;
- пятница: 00:00–20:58;
- воскресенье: с 22:05;
- суббота закрыта.

Полночь (00:00 и 24:00) — якорь суток и при сдвиге не двигается.
Сдвигаются только внутренние границы паузы.

- captured, сдвиг 0: окна как в файле. Окно сверки июнь–октябрь 2026
  целиком в летнем времени США, для него это и есть расписание.
- winter, сдвиг +1 час: воскресенье с 23:05, пн–чт 00:00–21:58 и
  23:01–24:00, пятница до 21:58. Это гипотеза на зиму, дамп её не содержит.
- auto: +1 час, когда в США зимнее время (до второго воскресенья марта
  07:00 UTC и с первого воскресенья ноября 06:00 UTC). Тоже не проверено
  отдельной зимней выгрузкой.

Котировочные сессии (они чуть шире) воротами входа не являются.
Праздники не моделируются. SL и TP обрабатываются на любом тике.
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
        shift: Shift = "captured",
        ranges: tuple[tuple[tuple[int, int], ...], ...] | None = None,
    ) -> None:
        if ranges is None:
            from .symbol_spec import load_xauusdm

            ranges = load_xauusdm().trade_ranges
        if len(ranges) != 7:
            raise ValueError("сессия: нужно 7 дней, понедельник = 0")
        self.base = tuple(tuple(day) for day in ranges)
        self.shift = shift
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
        """Летнее время США. Сервер Exness его не переводит; это только режим auto."""
        year = datetime.fromtimestamp(time_msc / 1000.0, timezone.utc).year
        start, end = self._dst_bounds_msc(year)
        return start <= time_msc < end

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
