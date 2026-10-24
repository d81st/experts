"""Интерфейс стратегии.

Советник видит закрытые бары и текущий тик. Заявки, отправленные с нулевой
задержкой, исполняются на этом же тике после возврата из колбэка. С задержкой
они ждут первый тик на отметке submit + latency.

on_bar_close приходит раньше on_tick того же тика, который закрыл бар.
"""

from __future__ import annotations

from typing import Protocol

from .types import Bar, Tick


class Context(Protocol):
    def now_msc(self) -> int: ...

    def tick(self) -> Tick: ...

    def session_open(self) -> bool: ...

    def bars(self, tf: str) -> list[Bar]: ...

    def forming_open_msc(self, tf: str) -> int | None: ...

    @property
    def position(self): ...

    @property
    def balance(self) -> float: ...

    @property
    def equity(self) -> float: ...

    def size_for_risk(
        self, stop_distance: float, risk_percent: float, basis: str = "equity", max_risk_overshoot: float | None = None,
    ) -> float: ...

    def buy_market(self, volume: float, sl: float | None, tp: float | None, comment: str = "") -> int | None: ...

    def sell_market(self, volume: float, sl: float | None, tp: float | None, comment: str = "") -> int | None: ...

    def buy_limit(
        self, volume: float, price: float, sl: float | None, tp: float | None,
        expiry_msc: int | None = None, comment: str = "", penetration: float | None = None,
    ) -> int | None: ...

    def sell_limit(
        self, volume: float, price: float, sl: float | None, tp: float | None,
        expiry_msc: int | None = None, comment: str = "", penetration: float | None = None,
    ) -> int | None: ...

    def buy_stop(
        self, volume: float, price: float, sl: float | None, tp: float | None,
        expiry_msc: int | None = None, comment: str = "",
    ) -> int | None: ...

    def sell_stop(
        self, volume: float, price: float, sl: float | None, tp: float | None,
        expiry_msc: int | None = None, comment: str = "",
    ) -> int | None: ...

    def close_position(self, reason: str = "strategy") -> bool: ...


class Strategy(Protocol):
    def required_timeframes(self) -> list[str]: ...

    def on_start(self, ctx: Context) -> None: ...

    def on_bar_close(self, ctx: Context, bar: Bar) -> None: ...

    def on_tick(self, ctx: Context, tick: Tick) -> None: ...


class CallbackStrategy:
    """Маленькая стратегия для тестов: один колбэк на тик и один на бар."""

    def __init__(self, timeframes: list[str], on_tick=None, on_bar=None, on_start=None):
        self._tfs = timeframes
        self._on_tick = on_tick
        self._on_bar = on_bar
        self._on_start = on_start

    def required_timeframes(self) -> list[str]:
        return list(self._tfs)

    def on_start(self, ctx: Context) -> None:
        if self._on_start:
            self._on_start(ctx)

    def on_bar_close(self, ctx: Context, bar: Bar) -> None:
        if self._on_bar:
            self._on_bar(ctx, bar)

    def on_tick(self, ctx: Context, tick: Tick) -> None:
        if self._on_tick:
            self._on_tick(ctx, tick)
