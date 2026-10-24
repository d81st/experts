"""Страж счёта. Зеркало Include/Core/RiskGuard.mqh.

Пороги фиксированы заранее и не подбираются. Включённый страж:

- считает лот от 0.5% баланса и возвращает 0, если после шага объёма
  лот ниже минимального, вместо подъёма до минимума;
- когда средства на 2% ниже капитала на первом тике серверных суток,
  не закрывает открытое и не пускает новые входы до следующих суток;
- когда средства на 15% ниже пика, запрещает новые входы, пока не вызван
  manual_reset. Пик при сбросе не двигается, и если просадка ещё 15%,
  следующий тик снова ставит kill. Флаг пишется в файл, если он задан;
- не открывает лонг, пока закрытие D1 ниже SMA200 закрытий D1.
  Меньше 200 закрытий — тоже запрет, причина bear_history;
- отказывает при битом символе, tick value, стопе, спреде выше 3 медиан
  128 предыдущих положительных спредов или котировке старше 60 секунд.
  Пока 128 спредов нет и на первой котировке без предшественника — отказ.

Сутки — календарный день UTC: в этом проекте время сервера совпадает с UTC.
Страж не закрывает позиции. Решение всегда close=False.
"""

from __future__ import annotations

import json
import math
import statistics
from collections import deque
from dataclasses import dataclass
from pathlib import Path

RISK_PERCENT = 0.5
DAILY_LOSS_PERCENT = 2.0
MAX_DRAWDOWN_PERCENT = 15.0
BEAR_SMA_PERIOD = 200
SPREAD_MEDIAN_MULT = 3.0
SPREAD_MEDIAN_SAMPLES = 128
STALE_QUOTE_SECONDS = 60

DAY_MS = 86_400_000


def _bad(value: float) -> bool:
    return isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value))


def bear_block_reason(closes: list[float], period: int = BEAR_SMA_PERIOD) -> str | None:
    """Почему лонг запрещён. Мало истории — отдельная причина, не «ниже SMA»."""
    if period < 1 or len(closes) < period:
        return "bear_history"
    window = closes[-period:]
    if any(_bad(price) or price <= 0.0 for price in window):
        return "bear_history"
    sma = sum(window) / period
    if window[-1] < sma:
        return "bear"
    return None


def bear_blocks_long(closes: list[float], period: int = BEAR_SMA_PERIOD) -> bool:
    return bear_block_reason(closes, period) is not None


def median_spread(samples: list[float]) -> float | None:
    """Медиана ровно SPREAD_MEDIAN_SAMPLES последних значений. Иначе None."""
    if len(samples) < SPREAD_MEDIAN_SAMPLES:
        return None
    window = samples[-SPREAD_MEDIAN_SAMPLES:]
    if any(_bad(value) or value <= 0.0 for value in window):
        return None
    return float(statistics.median(window))


@dataclass(frozen=True)
class GuardDecision:
    allowed: bool
    reason: str
    close: bool = False


@dataclass
class MarketView:
    point: float
    contract_size: float
    tick_size: float
    tick_value: float
    volume_min: float
    volume_max: float
    volume_step: float
    stops_level: float
    freeze_level: float
    bid: float
    ask: float


def market_block_reason(view: MarketView, *, spread_median: float | None, quote_age_sec: float | None) -> str | None:
    """Причина отказа по котировке и спецификации. None — эта часть в порядке."""
    numbers = (
        view.point, view.contract_size, view.tick_size, view.tick_value,
        view.volume_min, view.volume_max, view.volume_step, view.stops_level,
        view.freeze_level, view.bid, view.ask,
    )
    if any(_bad(value) for value in numbers):
        return "symbol"
    if view.point <= 0.0 or view.contract_size <= 0.0 or view.volume_min <= 0.0 or view.volume_step <= 0.0:
        return "symbol"
    if view.volume_max < view.volume_min or view.stops_level < 0.0 or view.freeze_level < 0.0:
        return "symbol"
    if view.tick_size <= 0.0 or view.tick_value <= 0.0:
        return "tick_value"
    spread = view.ask - view.bid
    if view.bid <= 0.0 or view.ask < view.bid or spread <= 0.0:
        return "symbol"
    if quote_age_sec is None or _bad(quote_age_sec) or quote_age_sec > STALE_QUOTE_SECONDS:
        return "stale"
    if spread_median is None or _bad(spread_median) or spread_median <= 0.0 or spread > SPREAD_MEDIAN_MULT * spread_median:
        return "spread"
    return None


def stop_block_reason(side: int, entry: float, sl: float, view: MarketView) -> str | None:
    if side not in (1, -1) or _bad(entry) or _bad(sl) or entry <= 0.0 or sl <= 0.0:
        return "stops"
    dist = entry - sl if side == 1 else sl - entry
    if dist <= 0.0:
        return "stops"
    min_dist = max(view.stops_level, view.freeze_level) * view.point
    if min_dist > 0.0 and dist + 1e-9 < min_dist:
        return "stops"
    return None


class RiskGuard:
    """Состояние суток, пика и спреда. Пороги — константы модуля."""

    def __init__(self, store_path: str | Path | None = None):
        self.store_path = Path(store_path) if store_path else None
        self.killed = False
        self.peak: float | None = None
        self.day_index: int | None = None
        self.day_equity: float | None = None
        self.day_blocked = False
        self.store_ok = True
        self._prev_msc: int | None = None
        self._stale = True
        # Текущий спред лежит в буфере вместе с 128 предыдущими, решение
        # смотрит медиану без него. Иначе кольцо вытеснило бы старейший.
        self._spreads: deque[float] = deque(maxlen=SPREAD_MEDIAN_SAMPLES + 1)
        self._appended = False
        self._load()

    def observe(self, time_msc: int, equity: float, bid: float, ask: float) -> None:
        if _bad(time_msc) or _bad(equity):
            self.store_ok = False
            self.day_blocked = True
            self._stale = True
            return
        day = int(time_msc) // DAY_MS
        if self.day_index is None or day != self.day_index:
            self.day_index = day
            self.day_equity = equity if equity > 0.0 else None
            self.day_blocked = self.day_equity is None
            self._save()
            if not self.store_ok:
                self.day_blocked = True
        elif self.day_equity is not None and equity <= self.day_equity * (1.0 - DAILY_LOSS_PERCENT / 100.0) + 1e-6:
            self.day_blocked = True

        if self.peak is None or equity > self.peak:
            self.peak = equity
        if (
            self.peak is not None
            and self.peak > 0.0
            and equity <= self.peak * (1.0 - MAX_DRAWDOWN_PERCENT / 100.0) + 1e-6
        ):
            if not self.killed:
                self.killed = True
                self._save()

        if self._prev_msc is None:
            self._stale = True
        else:
            self._stale = (int(time_msc) - self._prev_msc) > STALE_QUOTE_SECONDS * 1000
        self._prev_msc = int(time_msc)

        spread = ask - bid if not _bad(bid) and not _bad(ask) else float("nan")
        self._appended = not _bad(spread) and spread > 0.0
        if self._appended:
            self._spreads.append(spread)

    def manual_reset(self) -> None:
        """Снять kill. Пик остаётся, и живая просадка 15% включит kill снова."""
        self.killed = False
        self._save()

    def decision(
        self,
        view: MarketView,
        *,
        side: int,
        entry: float,
        sl: float,
        d1_closes: list[float],
    ) -> GuardDecision:
        if not self.store_ok:
            return GuardDecision(False, "symbol")
        if self._prev_msc is None:
            age: float | None = None
        elif self._stale:
            age = STALE_QUOTE_SECONDS + 1
        else:
            age = 0.0
        samples = list(self._spreads)
        if self._appended and samples:
            samples.pop()
        reason = market_block_reason(view, spread_median=median_spread(samples), quote_age_sec=age)
        if reason:
            return GuardDecision(False, reason)
        if self.killed:
            return GuardDecision(False, "kill")
        if self.day_equity is None or self.day_blocked:
            return GuardDecision(False, "daily")
        if side == 1:
            bear = bear_block_reason(d1_closes)
            if bear:
                return GuardDecision(False, bear)
        stop = stop_block_reason(side, entry, sl, view)
        if stop:
            return GuardDecision(False, stop)
        return GuardDecision(True, "ok")

    def _load(self) -> None:
        if self.store_path is None or not self.store_path.exists():
            return
        try:
            raw = json.loads(self.store_path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ValueError("не объект")
            self.killed = bool(raw.get("kill", False))
            peak = raw.get("peak")
            self.peak = float(peak) if peak is not None and not _bad(float(peak)) else None
            day = raw.get("day")
            day_eq = raw.get("day_equity")
            if day is not None and day_eq is not None and not _bad(float(day_eq)):
                self.day_index = int(day)
                self.day_equity = float(day_eq)
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            self.store_ok = False
            self.killed = True
            self.day_blocked = True

    def _save(self) -> None:
        if self.store_path is None:
            return
        payload = {
            "kill": self.killed,
            "peak": self.peak,
            "day": self.day_index,
            "day_equity": self.day_equity,
        }
        try:
            self.store_path.parent.mkdir(parents=True, exist_ok=True)
            self.store_path.write_text(json.dumps(payload, ensure_ascii=False) + "\n", encoding="utf-8")
        except OSError:
            self.store_ok = False
            self.killed = True
            self.day_blocked = True
