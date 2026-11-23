"""Тренд структуры D1 — перенос MarketStructure.mqh (MsClosedBars + MsStructureTrend).

Окно копирования: (MS_BARS + 5) * 2 суток до asOf, как в CopyRates.
Воскресный бар сливается с понедельником. Бар, чьё модельное время закрытия
позже asOf, отбрасывается вместе со всем, что правее.

Точка разворота: len баров слева и справа. Слева равенство ломает точку,
справа равенство разрешено. Если на одном баре и максимум, и минимум —
берётся максимум. Пробой вверх требует, чтобы минимумов уже было больше одного.
"""

from __future__ import annotations

from dataclasses import dataclass

from .session import DAY_MS, weekday_mon0
from .types import Bar

MS_BARS = 400


@dataclass
class _Day:
    time_msc: int
    high: float
    low: float
    close: float
    dow: int


def merged_d1(bars: list[Bar], as_of_msc: int, lookback_days: int = (MS_BARS + 5) * 2) -> list[_Day]:
    """Закрытые для структуры дневные бары, старые → новые. as_of — момент сигнала."""
    start = as_of_msc - lookback_days * DAY_MS
    selected = [b for b in bars if start <= b.time_msc < as_of_msc]
    merged: list[_Day] = []
    for i, bar in enumerate(selected):
        dow = weekday_mon0(bar.time_msc)
        # MQL: day_of_week == 0 это воскресенье. У нас воскресенье = 6.
        close_t = bar.time_msc + DAY_MS
        if dow == 6:
            close_t += DAY_MS
        join = False
        if merged and i > 0:
            prev = selected[i - 1]
            prev_dow = weekday_mon0(prev.time_msc)
            join = prev_dow == 6 and (bar.time_msc - prev.time_msc) <= DAY_MS
        if join:
            last = merged[-1]
            last.high = max(last.high, bar.high)
            last.low = min(last.low, bar.low)
            last.close = bar.close
        else:
            merged.append(_Day(bar.time_msc, bar.high, bar.low, bar.close, dow))
        if close_t > as_of_msc:
            merged.pop()
            break
    return merged


def structure_trend(days: list[_Day], length: int) -> int:
    n = len(days)
    if length < 1 or n < 2 * length + 3:
        return 0
    high = [d.high for d in days]
    low = [d.low for d in days]
    close = [d.close for d in days]
    up = 0.0
    dn = 0.0
    has_up = False
    has_dn = False
    n_high = 0
    n_low = 0
    trend = 0
    for i in range(n):
        center = i - length
        if center >= length:
            pivot_high = True
            pivot_low = True
            for k in range(center - length, center + length + 1):
                if k == center:
                    continue
                if not pivot_high and not pivot_low:
                    break
                if k < center:
                    if high[k] >= high[center]:
                        pivot_high = False
                    if low[k] <= low[center]:
                        pivot_low = False
                else:
                    if high[k] > high[center]:
                        pivot_high = False
                    if low[k] < low[center]:
                        pivot_low = False
            if pivot_high:
                up = high[center]
                has_up = True
                n_high += 1
            elif pivot_low:
                dn = low[center]
                has_dn = True
                n_low += 1
        if i > 0:
            if has_up and n_low > 1 and close[i] > up and close[i - 1] <= up:
                trend = 1
                has_up = False
            if has_dn and n_high > 1 and close[i] < dn and close[i - 1] >= dn:
                trend = -1
                has_dn = False
    return trend


def ema_trend(days: list[_Day], period: int) -> int:
    """MsEmaTrend: семя — первое закрытие окна, не SMA и не вся история графика."""
    if period < 1 or len(days) < period:
        return 0
    alpha = 2.0 / (period + 1.0)
    value = days[0].close
    for day in days[1:]:
        value = alpha * day.close + (1.0 - alpha) * value
    last = days[-1].close
    if last > value:
        return 1
    if last < value:
        return -1
    return 0


def d1_trend(bars: list[Bar], as_of_msc: int, mode: str, length: int = 5, ema_period: int = 50) -> int:
    days = merged_d1(bars, as_of_msc)
    if mode == "structure":
        return structure_trend(days, length)
    if mode == "ema":
        return ema_trend(days, ema_period)
    if mode == "off":
        return 0
    raise ValueError(f"неизвестный фильтр D1: {mode}")
