"""Своп. Спред сидит в самих тиках, здесь его не добавляют.

Два часа начисления:

- `exness` — 17:00 ET, внутри дневной паузы. Летом это 21:00 UTC,
  зимой 22:00 UTC. День множителя — календарный день Нью-Йорка.
- `tester` — полночь сервера (UTC). Так устроен отчёт тестера MT5:
  ночь среды приходит в 00:00 четверга. Этот режим нужен для сверки.

Позиция платит, если вход строго раньше момента начисления.
Без multipliers: суббота и воскресенье не начисляют, ночь пятницы одна,
день triple_swap_weekday (по умолчанию среда, понедельник = 0) ×3.
С multipliers (7 чисел, понедельник = 0) ноль означает «ночи нет».
Таблица XAUUSDm: пн–вт 1, ср 3, чт–пт 1, сб–вс 0.

Знак как в MT5: отрицательный своп уменьшает результат.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime, timedelta, timezone

from .session import DAY_MS, is_us_dst, weekday_mon0


def swap_instant_17et(year: int, month: int, day: int) -> int:
    """17:00 America/New_York в миллисекундах UTC.

    17:00 EDT = 21:00 UTC, 17:00 EST = 22:00 UTC. Граница DST в этот
    день уже позади: перевод идёт в 02:00 местного.
    """
    summer = datetime(year, month, day, 21, tzinfo=timezone.utc)
    summer_msc = int(summer.timestamp() * 1000)
    if is_us_dst(summer_msc):
        return summer_msc
    winter = datetime(year, month, day, 22, tzinfo=timezone.utc)
    return int(winter.timestamp() * 1000)


def _check_schedule(triple_weekday: int, multipliers: Sequence[float] | None) -> None:
    if multipliers is not None:
        if len(multipliers) != 7:
            raise ValueError("multipliers: нужно 7 чисел, понедельник = 0")
        if any(value < 0.0 for value in multipliers):
            raise ValueError("множитель свопа < 0")
    elif triple_weekday < 0 or triple_weekday > 6:
        raise ValueError("triple_weekday должен быть 0..6")


def _multiplier(wd: int, triple_weekday: int, multipliers: Sequence[float] | None) -> float:
    if multipliers is not None:
        return float(multipliers[wd])
    if wd >= 5:
        return 0.0
    return 3.0 if wd == triple_weekday else 1.0


def swap_charges(
    prev_msc: int,
    now_msc: int,
    entry_msc: int,
    last_swap_msc: int,
    *,
    triple_weekday: int = 2,
    multipliers: Sequence[float] | None = None,
    clock: str = "tester",
) -> list[tuple[int, float]]:
    """Список (момент, множитель) для одной позиции.

    clock=`tester` — полночь UTC. clock=`exness` — 17:00 ET.
    """
    _check_schedule(triple_weekday, multipliers)
    if clock not in ("tester", "exness"):
        raise ValueError("clock должен быть tester или exness")
    if now_msc < prev_msc:
        return []
    if clock == "tester":
        instants = _tester_midnights(prev_msc, now_msc)
    else:
        instants = _exness_afternoons(prev_msc, now_msc)
    out: list[tuple[int, float]] = []
    for instant, wd in instants:
        if entry_msc < instant and last_swap_msc < instant:
            mult = _multiplier(wd, triple_weekday, multipliers)
            if mult != 0.0:
                out.append((instant, mult))
    return out


def _tester_midnights(prev_msc: int, now_msc: int) -> list[tuple[int, int]]:
    first = (prev_msc // DAY_MS + 1) * DAY_MS
    out: list[tuple[int, int]] = []
    midnight = first
    while midnight <= now_msc:
        departing = midnight - DAY_MS
        out.append((midnight, weekday_mon0(departing)))
        midnight += DAY_MS
    return out


def _exness_afternoons(prev_msc: int, now_msc: int) -> list[tuple[int, int]]:
    start = datetime.fromtimestamp(prev_msc / 1000.0, timezone.utc).date() - timedelta(days=1)
    end = datetime.fromtimestamp(now_msc / 1000.0, timezone.utc).date() + timedelta(days=1)
    out: list[tuple[int, int]] = []
    day = start
    while day <= end:
        instant = swap_instant_17et(day.year, day.month, day.day)
        if prev_msc < instant <= now_msc:
            out.append((instant, day.weekday()))
        day += timedelta(days=1)
    return out
