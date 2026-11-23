"""Тики Dukascopy .bi5, час или дерево часов.

Запись 20 байт, big-endian: миллисекунды от начала часа, ask, bid
(целые), объём ask и bid float. Для XAUUSD цена = целое / 1000.
Пустой час и отсутствующий файл — не ошибка: в паузе тиков нет.

Каталог повторяет путь datafeed, месяц с нуля:
`YYYY/MM/DD/HHh_ticks.bi5`. Сутки с 2026-10-16 не открываются.
"""

from __future__ import annotations

import lzma
import struct
from datetime import date, datetime, timezone
from pathlib import Path

from .types import DataError, Tick

HOLDOUT_DAY = date(2026, 10, 16)
PRICE_SCALE = 1000.0
_REC = struct.Struct(">IIIff")


def hour_start_msc(year: int, month_index: int, day: int, hour: int) -> int:
    """month_index — как в URL Dukascopy, январь = 0."""
    if not 0 <= month_index <= 11 or not 1 <= day <= 31 or not 0 <= hour <= 23:
        raise DataError(f"битый путь часа: {year}-{month_index}-{day} {hour}")
    try:
        moment = datetime(year, month_index + 1, day, hour, tzinfo=timezone.utc)
    except ValueError as exc:
        raise DataError(f"битая дата часа: {year}-{month_index + 1}-{day} {hour}") from exc
    if moment.date() >= HOLDOUT_DAY:
        raise DataError("отказ: час тиков попадает в холдаут с 2026-10-16")
    return int(moment.timestamp() * 1000)


def decode_hour_ticks(blob: bytes, start_msc: int) -> list[Tick]:
    """Один часовой bi5. Пустой ответ — пустой список."""
    if not blob:
        return []
    try:
        raw = lzma.decompress(blob)
    except lzma.LZMAError as exc:
        raise DataError("часовой bi5 не распаковывается") from exc
    if len(raw) % _REC.size != 0:
        raise DataError(f"длина тикового часа {len(raw)} не кратна 20")
    out: list[Tick] = []
    prev = -1
    for offset in range(0, len(raw), _REC.size):
        ms, ask_i, bid_i, ask_vol, bid_vol = _REC.unpack_from(raw, offset)
        if ms < prev or ms >= 3_600_000:
            raise DataError(f"время тика в часе вне порядка: {ms}")
        prev = ms
        bid = bid_i / PRICE_SCALE
        ask = ask_i / PRICE_SCALE
        if bid <= 0.0 or ask <= 0.0 or bid > ask:
            raise DataError(f"битая котировка часа t={ms}: bid={bid} ask={ask}")
        if bid < 500.0 or ask > 20_000.0:
            raise DataError(f"цена часа не похожа на золото: bid={bid} ask={ask}")
        out.append(
            Tick(
                time_msc=start_msc + int(ms),
                bid=bid,
                ask=ask,
                bid_vol=float(bid_vol),
                ask_vol=float(ask_vol),
                volume=float(bid_vol) + float(ask_vol),
            )
        )
    return out


def _hour_from_path(root: Path, path: Path) -> int:
    rel = path.relative_to(root)
    if len(rel.parts) != 4 or not rel.parts[3].endswith("h_ticks.bi5"):
        raise DataError(f"не часовой bi5: {path}")
    year = int(rel.parts[0])
    month_index = int(rel.parts[1])
    day = int(rel.parts[2])
    hour = int(rel.parts[3][:2])
    return hour_start_msc(year, month_index, day, hour)


def iter_bi5_tree(root: str | Path):
    """Часы по порядку пути. Дыры в каталоге — паузы, не ошибка."""
    root = Path(root)
    paths = sorted(root.glob("*/*/*/*h_ticks.bi5"))
    if not paths:
        raise DataError(f"в {root} нет YYYY/MM/DD/HHh_ticks.bi5")
    prev: int | None = None
    for path in paths:
        start = _hour_from_path(root, path)
        blob = path.read_bytes()
        for tick in decode_hour_ticks(blob, start):
            if prev is not None and tick.time_msc < prev:
                raise DataError(f"тики дерева пошли назад: {tick.time_msc} < {prev}")
            prev = tick.time_msc
            yield tick
