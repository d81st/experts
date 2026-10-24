"""Лот от риска и дистанции до стопа.

Формула та же, что BrokerCalcLot(LOT_BY_TICK_VALUE), но битый вход
не подменяется минимальным лотом: выбрасывается SizingError.

    money_per_lot = stop_distance / tick_size * tick_value
    lot = capital * risk_percent / 100 / money_per_lot

Дальше пол вниз до шага объёма и зажим в [min, max].
Если минимальный лот рискует больше, чем risk * max_risk_overshoot,
возвращается 0 — сделку надо пропустить, как делает советник.
max_risk_overshoot <= 0 отключает эту проверку (в MQL порог строго > 0).
"""

from __future__ import annotations

import math

from .types import SizingError


def _bad(value: float) -> bool:
    return isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value))


def size_by_risk(
    capital: float,
    risk_percent: float,
    stop_distance: float,
    *,
    tick_size: float,
    tick_value: float,
    volume_min: float,
    volume_max: float,
    volume_step: float,
    max_risk_overshoot: float = 1.5,
) -> float:
    values = {
        "capital": capital,
        "risk_percent": risk_percent,
        "stop_distance": stop_distance,
        "tick_size": tick_size,
        "tick_value": tick_value,
        "volume_min": volume_min,
        "volume_max": volume_max,
        "volume_step": volume_step,
        "max_risk_overshoot": max_risk_overshoot,
    }
    broken = [name for name, value in values.items() if _bad(value)]
    if broken:
        raise SizingError("нечисловой вход: " + ", ".join(broken))
    if capital <= 0.0:
        raise SizingError("capital <= 0")
    if not 0.0 < risk_percent <= 100.0:
        raise SizingError("risk_percent вне (0, 100]")
    if stop_distance <= 0.0:
        raise SizingError("stop_distance <= 0")
    if tick_size <= 0.0 or tick_value <= 0.0:
        raise SizingError("tick_size или tick_value <= 0")
    if volume_step <= 0.0 or volume_min <= 0.0 or volume_max < volume_min:
        raise SizingError("границы объёма невалидны")

    money_per_lot = (stop_distance / tick_size) * tick_value
    if not math.isfinite(money_per_lot) or money_per_lot <= 0.0:
        raise SizingError("money_per_lot не посчитался")
    risk_money = capital * risk_percent / 100.0
    min_lot_risk = money_per_lot * volume_min
    if max_risk_overshoot > 0.0 and min_lot_risk > risk_money * max_risk_overshoot:
        return 0.0

    raw = risk_money / money_per_lot
    steps = math.floor(raw / volume_step + 1e-8)
    lot = steps * volume_step
    if lot < volume_min:
        lot = volume_min
    if lot > volume_max:
        lot = volume_max
    # Срезаем двоичный хвост шага 0.01.
    decimals = max(0, int(round(-math.log10(volume_step)))) if volume_step < 1 else 0
    return round(lot, decimals + 2)
