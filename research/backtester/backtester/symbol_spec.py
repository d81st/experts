"""Спецификация XAUUSDm из data/symbol-spec/XAUUSDm.json.

Числа контракта, свопа и торговых сессий читаются из файла. В коде их нет
второй копией: пропал файл — загрузка падает, а не подставляет допущение.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .types import ConfigError, SymbolSpec, adjusted_point

RELATIVE = Path("data") / "symbol-spec" / "XAUUSDm.json"
MT5_DAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
# Индекс MT5 (воскресенье = 0) → наш понедельник = 0.
MON0_FROM_MT5 = (1, 2, 3, 4, 5, 6, 0)

_CACHED_PATH: Path | None = None
_CACHED_RAW: dict | None = None


@dataclass(frozen=True)
class CapturedSymbol:
    spec: SymbolSpec
    path: str
    captured_at: str
    captured_date: str
    swap_mode: str
    swap_long_points: float
    swap_short_points: float
    swap_long_per_lot: float
    swap_short_per_lot: float
    swap_rollover3days: str
    triple_swap_weekday: int
    swap_multipliers: tuple[float, ...]
    trade_ranges: tuple[tuple[tuple[int, int], ...], ...]
    quote_ranges: tuple[tuple[tuple[int, int], ...], ...]
    server_utc_offset_seconds: int


def find_spec_path() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / RELATIVE
        if candidate.is_file():
            return candidate
    raise ConfigError(
        "нет data/symbol-spec/XAUUSDm.json: спецификация не подставляется из кода"
    )


def points_to_usd_per_lot(points: float, point: float, tick_size: float, tick_value: float) -> float:
    """SYMBOL_SWAP_MODE_POINTS → USD на 1.00 лот за ночь.

    points × point × (tick_value / tick_size). Для этой выгрузки
    −490.8 × 0.001 × 100 = −49.08.
    """
    if point <= 0.0 or tick_size <= 0.0 or tick_value <= 0.0:
        raise ConfigError("своп: point, tick_size и tick_value должны быть > 0")
    return points * point * (tick_value / tick_size)


def _end_seconds(raw: int) -> int:
    # В дампе to_seconds = 0 у окна, которое кончается в 00:00 следующих суток.
    if raw == 0:
        return 86_400
    return raw


def _session_ranges(sessions: dict, kind: str) -> tuple[tuple[tuple[int, int], ...], ...]:
    table = sessions.get(kind)
    if not isinstance(table, dict):
        raise ConfigError(f"в спецификации нет sessions.{kind}")
    by_mt5: list[tuple[tuple[int, int], ...]] = []
    for name in MT5_DAYS:
        rows = table.get(name)
        if not isinstance(rows, list):
            raise ConfigError(f"sessions.{kind}.{name} не список")
        windows: list[tuple[int, int]] = []
        for row in rows:
            start = int(row["from_seconds"])
            end = _end_seconds(int(row["to_seconds"]))
            if start < 0 or end > 86_400 or end <= start:
                raise ConfigError(f"окно сессии {name} вне суток: {start}..{end}")
            windows.append((start, end))
        by_mt5.append(tuple(windows))
    return tuple(by_mt5[index] for index in MON0_FROM_MT5)


def _trade_ranges(sessions: dict) -> tuple[tuple[tuple[int, int], ...], ...]:
    return _session_ranges(sessions, "trade")


def _multipliers(raw: dict) -> tuple[float, ...]:
    table = raw.get("swap_weekday")
    if not isinstance(table, dict):
        raise ConfigError("нет swap_weekday")
    ordered = []
    for name in MT5_DAYS:
        if name not in table:
            raise ConfigError(f"нет множителя свопа {name}")
        value = float(table[name])
        if value < 0.0:
            raise ConfigError(f"множитель свопа {name} < 0")
        ordered.append(value)
    return tuple(ordered[index] for index in MON0_FROM_MT5)


def _read(path: Path) -> dict:
    global _CACHED_PATH, _CACHED_RAW
    resolved = path.resolve()
    if _CACHED_RAW is not None and _CACHED_PATH == resolved:
        return _CACHED_RAW
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"не читается спецификация {path.name}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        raise ConfigError("спецификация символа не ok")
    _CACHED_PATH = resolved
    _CACHED_RAW = payload
    return payload


def load_xauusdm(leverage: float = 2000.0, path: Path | None = None) -> CapturedSymbol:
    spec_path = path if path is not None else find_spec_path()
    if not spec_path.is_file():
        raise ConfigError(f"нет файла спецификации: {spec_path.name}")
    raw = _read(spec_path)
    if raw.get("symbol") != "XAUUSDm":
        raise ConfigError("спецификация не XAUUSDm")
    offset = int(raw.get("server_utc_offset_seconds", -1))
    if offset != 0:
        raise ConfigError("сессии заданы не в UTC+0")
    swap_mode = raw.get("swap_mode") or {}
    if swap_mode.get("name") != "SYMBOL_SWAP_MODE_POINTS":
        raise ConfigError("своп не в пунктах: пересчёт в USD не сделан")
    profit = raw.get("currency_profit")
    if profit != "USD":
        raise ConfigError("валюта прибыли не USD")
    tick_value = float(raw["trade_tick_value"])
    tick_profit = float(raw["trade_tick_value_profit"])
    tick_loss = float(raw["trade_tick_value_loss"])
    if tick_profit != tick_value or tick_loss != tick_value:
        raise ConfigError("tick value прибыли и убытка различаются")
    digits = int(raw["digits"])
    point = float(raw["point"])
    tick_size = float(raw["trade_tick_size"])
    rollover = raw.get("swap_rollover3days") or {}
    rollover_value = int(rollover.get("value", -1))
    if rollover_value < 0 or rollover_value > 6:
        raise ConfigError("swap_rollover3days вне 0..6")
    triple = (rollover_value + 6) % 7
    multipliers = _multipliers(raw)
    if multipliers[triple] != 3.0:
        raise ConfigError("день тройного свопа не совпадает с swap_weekday")
    long_points = float(raw["swap_long"])
    short_points = float(raw["swap_short"])
    try:
        repo_relative = str(spec_path.resolve().relative_to(_repo_root(spec_path)))
    except ValueError:
        repo_relative = RELATIVE.as_posix()
    spec = SymbolSpec(
        name="XAUUSDm",
        digits=digits,
        point=point,
        contract_size=float(raw["trade_contract_size"]),
        tick_size=tick_size,
        tick_value=tick_value,
        volume_min=float(raw["volume_min"]),
        volume_max=float(raw["volume_max"]),
        volume_step=float(raw["volume_step"]),
        adjusted_point=adjusted_point(digits, point),
        leverage=leverage,
        stops_level=int(raw["trade_stops_level"]),
        freeze_level=int(raw["trade_freeze_level"]),
    )
    return CapturedSymbol(
        spec=spec,
        path=repo_relative,
        captured_at=str(raw.get("captured_at", "")),
        captured_date=str(raw.get("captured_date", "")),
        swap_mode=str(swap_mode.get("name")),
        swap_long_points=long_points,
        swap_short_points=short_points,
        swap_long_per_lot=points_to_usd_per_lot(long_points, point, tick_size, tick_value),
        swap_short_per_lot=points_to_usd_per_lot(short_points, point, tick_size, tick_value),
        swap_rollover3days=str(rollover.get("name", "")),
        triple_swap_weekday=triple,
        swap_multipliers=multipliers,
        trade_ranges=_session_ranges(raw.get("sessions") or {}, "trade"),
        quote_ranges=_session_ranges(raw.get("sessions") or {}, "quote"),
        server_utc_offset_seconds=offset,
    )


def _repo_root(spec_path: Path) -> Path:
    resolved = spec_path.resolve()
    for parent in resolved.parents:
        if (parent / RELATIVE).resolve() == resolved:
            return parent
    return resolved.parents[2]
