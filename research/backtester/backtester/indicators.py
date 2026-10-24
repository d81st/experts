"""Индикаторы сигнала Алхимика.

SMA, CCI и HMA повторяют Include/Triggers/AlchemistSignal.mqh и screen.py.
HMA — дословный перенос AlchemistWma / AlchemistHma2: веса n…1 на свежих барах,
half = n//2, sqrt = floor. Запрашивается n + floor(sqrt(n)) + 1 закрытие,
как CopyClose в MQL; если их нет, значения нет.

EMA для фильтра H4 — как iMA(MODE_EMA) / pandas ewm(adjust=False):
первое значение равно первому закрытию, дальше k = 2/(n+1).
Это не то же самое, что MsEmaTrend (тот считается в structure.py по окну D1).

ATR — Уайлдер: первое значение — среднее n истинных диапазонов, дальше
(prev*(n-1) + TR) / n. Пока посева нет, функция возвращает None.
"""

from __future__ import annotations

import math


def sma_at(closes: list[float], index: int, period: int) -> float | None:
    if period < 1 or index < period - 1 or index >= len(closes):
        return None
    window = closes[index - period + 1 : index + 1]
    return sum(window) / period


def ema_series(closes: list[float], period: int) -> list[float] | None:
    if period < 1 or len(closes) < 1:
        return None
    k = 2.0 / (period + 1.0)
    out = [closes[0]]
    for price in closes[1:]:
        out.append(k * price + (1.0 - k) * out[-1])
    return out


def _wma_mql(series_newest_first: list[float], start: int, period: int) -> float:
    num = 0.0
    den = 0.0
    for k in range(period):
        weight = period - k
        num += weight * series_newest_first[start + k]
        den += weight
    return num / den


def hma_last_two(closes: list[float], period: int) -> tuple[float, float] | None:
    """HMA на последнем и предпоследнем баре. closes — от старых к новым.

    Возвращает (hma_последний, hma_предыдущий), как (h0, h1) в MQL.
    """
    half = period // 2
    sq = int(math.floor(math.sqrt(period)))
    if half < 1 or sq < 1:
        return None
    need = period + sq + 1
    if len(closes) < need:
        return None
    newest_first = list(reversed(closes[-need:]))
    raw = [
        2.0 * _wma_mql(newest_first, k, half) - _wma_mql(newest_first, k, period)
        for k in range(sq + 1)
    ]
    return _wma_mql(raw, 0, sq), _wma_mql(raw, 1, sq)


def cci_at(highs: list[float], lows: list[float], closes: list[float], index: int, period: int) -> float | None:
    if period < 1 or index < period - 1:
        return None
    start = index - period + 1
    typical = [(highs[i] + lows[i] + closes[i]) / 3.0 for i in range(start, index + 1)]
    mean = sum(typical) / period
    mean_dev = sum(abs(value - mean) for value in typical) / period
    if mean_dev == 0.0:
        return None
    return (typical[-1] - mean) / (0.015 * mean_dev)


def wilder_atr_last(highs: list[float], lows: list[float], closes: list[float], period: int) -> float | None:
    if period < 1 or len(closes) < period:
        return None
    trs: list[float] = []
    prev_close = closes[0]
    # Первый бар без предыдущего закрытия не даёт TR. Посев — следующие period TR.
    for i in range(1, len(closes)):
        tr = max(highs[i] - lows[i], abs(highs[i] - prev_close), abs(lows[i] - prev_close))
        prev_close = closes[i]
        trs.append(tr)
    if len(trs) < period:
        return None
    atr = sum(trs[:period]) / period
    for tr in trs[period:]:
        atr = (atr * (period - 1) + tr) / period
    return atr
