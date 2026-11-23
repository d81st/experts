"""Общие типы. Цены баров — bid, если не сказано иное."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone


class BacktesterError(Exception):
    """Ошибка модели. Прогон останавливается: лучше упасть, чем выдать лот наугад."""


class DataError(BacktesterError):
    pass


class SizingError(BacktesterError):
    pass


class ConfigError(BacktesterError):
    pass


def utc_from_msc(time_msc: int) -> datetime:
    return datetime.fromtimestamp(time_msc / 1000.0, timezone.utc)


def msc_from_utc(dt: datetime) -> int:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def round_price(price: float, digits: int) -> float:
    """Округление половины от нуля, как NormalizeDouble в MQL5 (не банковское)."""
    if digits < 0:
        raise ConfigError("digits < 0")
    q = 10 ** digits
    sign = 1.0 if price >= 0.0 else -1.0
    return sign * int(abs(price) * q + 0.5) / q


@dataclass(frozen=True)
class Tick:
    time_msc: int
    bid: float
    ask: float
    last: float = 0.0
    volume: float = 0.0
    bid_vol: float = 0.0
    ask_vol: float = 0.0
    flags: int = 0

    def __post_init__(self) -> None:
        if self.time_msc < 0:
            raise DataError("time_msc < 0")
        if not (self.bid > 0.0 and self.ask > 0.0):
            raise DataError(f"неположительная котировка bid={self.bid} ask={self.ask}")
        if self.bid > self.ask:
            raise DataError(f"bid > ask: {self.bid} > {self.ask}")


@dataclass(frozen=True)
class Bar:
    """Бар. open/high/low/close — bid. Ask хранится отдельно.

    time_msc — время открытия. Бар закрыт: его цены не зависят от будущих тиков.
    """

    tf: str
    time_msc: int
    open: float
    high: float
    low: float
    close: float
    ask_open: float
    ask_high: float
    ask_low: float
    ask_close: float
    tick_count: int
    volume: float
    # Откуда бар: ticks, exness, dukascopy, csv. Прогрев и живые тики не смешиваются.
    source: str = "ticks"

    @property
    def spread_close(self) -> float:
        return self.ask_close - self.close


@dataclass(frozen=True)
class SymbolSpec:
    """Спецификация символа.

    money_per_price — сколько USD приносит движение цены на 1.00 при объёме 1.0 лот.
    Для XAUUSDm это tick_value / tick_size из выгрузки терминала (100 USD).
    stops_level и freeze_level — пункты брокера. 0 значит ограничения нет.
    """

    name: str
    digits: int
    point: float
    contract_size: float
    tick_size: float
    tick_value: float
    volume_min: float
    volume_max: float
    volume_step: float
    adjusted_point: float
    leverage: float = 2000.0
    stops_level: int = 0
    freeze_level: int = 0

    def __post_init__(self) -> None:
        checks = {
            "digits": self.digits >= 0,
            "point": self.point > 0.0,
            "contract_size": self.contract_size > 0.0,
            "tick_size": self.tick_size > 0.0,
            "tick_value": self.tick_value > 0.0,
            "volume_min": self.volume_min > 0.0,
            "volume_max": self.volume_max >= self.volume_min,
            "volume_step": self.volume_step > 0.0,
            "adjusted_point": self.adjusted_point > 0.0,
            "leverage": self.leverage > 0.0,
            "stops_level": self.stops_level >= 0,
            "freeze_level": self.freeze_level >= 0,
        }
        bad = [name for name, ok in checks.items() if not ok]
        if bad:
            raise ConfigError("невалидная спецификация символа: " + ", ".join(bad))

    @property
    def money_per_price(self) -> float:
        return self.tick_value / self.tick_size


def adjusted_point(digits: int, point: float) -> float:
    """Как BrokerInit: digits 3 или 5 → point, 2 или 4 → point/10, иначе point."""
    if point <= 0.0:
        raise ConfigError("point <= 0")
    if digits in (3, 5):
        return point
    if digits in (2, 4):
        return point / 10.0
    return point


def xauusd_exness(leverage: float = 2000.0) -> SymbolSpec:
    """XAUUSDm из data/symbol-spec/XAUUSDm.json. Без файла прогон не стартует."""
    from .symbol_spec import load_xauusdm

    return load_xauusdm(leverage=leverage).spec


@dataclass
class Trade:
    id: int
    side: int  # +1 long, −1 short
    volume: float
    entry_time_msc: int
    exit_time_msc: int
    entry_price: float
    exit_price: float
    sl: float | None
    tp: float | None
    initial_sl: float | None
    exit_reason: str
    gross_pnl: float
    commission: float
    swap: float
    net_pnl: float
    initial_risk: float | None
    r_multiple: float | None
    entry_spread: float
    exit_spread: float
    comment: str
    ambiguous_sl_tp: bool = False
    magic: int = 0

    def entry_time(self) -> datetime:
        return utc_from_msc(self.entry_time_msc)

    def exit_time(self) -> datetime:
        return utc_from_msc(self.exit_time_msc)


@dataclass
class EquityPoint:
    time_msc: int
    balance: float
    equity: float
    event: str = ""


@dataclass
class Drawdown:
    max_balance_dd_money: float = 0.0
    max_balance_dd_pct: float = 0.0
    max_equity_dd_money: float = 0.0
    max_equity_dd_pct: float = 0.0
    balance_peak: float = 0.0
    equity_peak: float = 0.0
    balance_trough_msc: int | None = None
    equity_trough_msc: int | None = None
    equity_at_trough: float = 0.0
    balance_at_equity_trough: float = 0.0


@dataclass
class BacktestResult:
    trades: list[Trade] = field(default_factory=list)
    equity_curve: list[EquityPoint] = field(default_factory=list)
    drawdown: Drawdown = field(default_factory=Drawdown)
    metrics: dict = field(default_factory=dict)
    rejected: list[str] = field(default_factory=list)
    open_positions: list[dict] = field(default_factory=list)
    last_time_msc: int | None = None
    tick_count: int = 0
    strategy_counts: dict = field(default_factory=dict)
