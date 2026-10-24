"""Своп по ночам. Спред сидит в самих тиках, здесь его не добавляют.

Начисление в полночь UTC, если позиция открыта строго раньше полуночи.
День, который заканчивается, — это сутки до полуночи.

- суббота и воскресенье не начисляют отдельную ночь;
- ночь пятницы — одна (удержанные выходные не умножаются);
- день triple_swap_weekday (по умолчанию среда, Monday=0 → 2) умножается на 3.

Так устроен отчёт h1-x12-st за август 2026: удержание с пятницы по понедельник
дало одну ночь, среда — тройную. Это наблюдение по одному отчёту, не таблица
свопов брокера. Ставка по умолчанию 0: без явного числа деньги не выдумываются.

Знак как в MT5: отрицательный своп уменьшает результат.
"""

from __future__ import annotations

from .session import DAY_MS, weekday_mon0


def swap_charges(
    prev_msc: int,
    now_msc: int,
    entry_msc: int,
    last_swap_msc: int,
    *,
    triple_weekday: int = 2,
) -> list[tuple[int, int]]:
    """Список (полночь, множитель 1 или 3) для одной позиции."""
    if triple_weekday < 0 or triple_weekday > 6:
        raise ValueError("triple_weekday должен быть 0..6")
    if now_msc < prev_msc:
        return []
    first = (prev_msc // DAY_MS + 1) * DAY_MS
    out: list[tuple[int, int]] = []
    midnight = first
    while midnight <= now_msc:
        if entry_msc < midnight and last_swap_msc < midnight:
            departing = midnight - DAY_MS
            wd = weekday_mon0(departing)
            if wd < 5:
                mult = 3 if wd == triple_weekday else 1
                out.append((midnight, mult))
        midnight += DAY_MS
    return out
