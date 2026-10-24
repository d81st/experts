"""Своп по ночам. Спред сидит в самих тиках, здесь его не добавляют.

Начисление в полночь UTC, если позиция открыта строго раньше полуночи.
День, который заканчивается, — это сутки до полуночи.

Без multipliers сохраняется прежняя схема: суббота и воскресенье не
начисляют ночь, ночь пятницы — одна, день triple_swap_weekday (по
умолчанию среда, понедельник = 0 → 2) умножается на 3.

С multipliers (7 чисел, понедельник = 0) ночь берёт множитель дня,
который заканчивается. Ноль — ночи нет. Таблица XAUUSDm из выгрузки:
пн–вт 1, ср 3, чт–пт 1, сб–вс 0. Ставка в USD на лот считается снаружи
из пунктов: points × point × tick_value / tick_size.

Знак как в MT5: отрицательный своп уменьшает результат.
"""

from __future__ import annotations

from collections.abc import Sequence

from .session import DAY_MS, weekday_mon0


def swap_charges(
    prev_msc: int,
    now_msc: int,
    entry_msc: int,
    last_swap_msc: int,
    *,
    triple_weekday: int = 2,
    multipliers: Sequence[float] | None = None,
) -> list[tuple[int, float]]:
    """Список (полночь, множитель) для одной позиции."""
    if multipliers is not None:
        if len(multipliers) != 7:
            raise ValueError("multipliers: нужно 7 чисел, понедельник = 0")
        if any(value < 0.0 for value in multipliers):
            raise ValueError("множитель свопа < 0")
    elif triple_weekday < 0 or triple_weekday > 6:
        raise ValueError("triple_weekday должен быть 0..6")
    if now_msc < prev_msc:
        return []
    first = (prev_msc // DAY_MS + 1) * DAY_MS
    out: list[tuple[int, float]] = []
    midnight = first
    while midnight <= now_msc:
        if entry_msc < midnight and last_swap_msc < midnight:
            departing = midnight - DAY_MS
            wd = weekday_mon0(departing)
            if multipliers is not None:
                mult = float(multipliers[wd])
                if mult != 0.0:
                    out.append((midnight, mult))
            elif wd < 5:
                mult = 3.0 if wd == triple_weekday else 1.0
                out.append((midnight, mult))
        midnight += DAY_MS
    return out
