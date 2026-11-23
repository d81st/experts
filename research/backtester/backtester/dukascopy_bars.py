"""Прогрев баров из публичных свечей Dukascopy BID M1.

Файл datafeed — LZMA, сутки, запись 24 байта big-endian:
секунды от полуночи UTC, open, close, low, high (целые), объём float.
Для XAUUSD цена = целое / 1000.

Прогрев только бары. Заявок по ним нет. В живой бар, который откроет
первый тик Exness, прогрев не заходит: иначе один и тот же час
посчитался бы дважды.

Сдвиг уровня. На пересечении с Exness (начало 2026, до холдаута)
считается медиана (close Exness − close Dukascopy) по общим минутам bid.
Это и есть добавка к OHLC прогрева. Середина спреда здесь ни при чём:
обе стороны — bid, как OHLC бара.
"""

from __future__ import annotations

import lzma
import struct
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from .bars import TF_MS, aggregate_bars, align_open
from .session import ExnessGoldSession
from .types import Bar, DataError

# Холдаут протокола. Модуль не читает сутки, которые начинаются в этот день или позже.
HOLDOUT_DAY = date(2026, 10, 16)
PRICE_SCALE = 1000.0
_REC = struct.Struct(">IIIIIf")


def day_start_msc(day: date) -> int:
    if day >= HOLDOUT_DAY:
        raise DataError("отказ: сутки прогрева попадают в холдаут с 2026-10-16")
    moment = datetime(day.year, day.month, day.day, tzinfo=timezone.utc)
    return int(moment.timestamp() * 1000)


def decode_bid_m1(blob: bytes, day: date, source: str = "dukascopy") -> list[Bar]:
    """Один суточный bi5 → закрытые M1. Пустой ответ брокера — пустой список."""
    start = day_start_msc(day)
    if not blob:
        return []
    try:
        raw = lzma.decompress(blob)
    except lzma.LZMAError as exc:
        raise DataError(f"{day}: bi5 не распаковывается") from exc
    if len(raw) % _REC.size != 0:
        raise DataError(f"{day}: длина {len(raw)} не кратна 24")
    bars: list[Bar] = []
    prev = -1
    for offset in range(0, len(raw), _REC.size):
        sec, open_i, close_i, low_i, high_i, volume = _REC.unpack_from(raw, offset)
        if sec < prev:
            raise DataError(f"{day}: время свечи пошло назад")
        prev = sec
        time_msc = start + int(sec) * 1000
        if datetime.fromtimestamp(time_msc / 1000.0, timezone.utc).date() >= HOLDOUT_DAY:
            raise DataError("отказ: свеча прогрева попала в холдаут")
        open_, close, low, high = (open_i / PRICE_SCALE, close_i / PRICE_SCALE, low_i / PRICE_SCALE, high_i / PRICE_SCALE)
        if min(open_, close, low, high) <= 0.0 or low > high or open_ < low or open_ > high or close < low or close > high:
            raise DataError(f"{day}: битая свеча t={sec}")
        bars.append(
            Bar("M1", time_msc, open_, high, low, close, open_, high, low, close, 1, float(volume), source)
        )
    return bars


def load_m1_tree(root: str | Path, source: str = "dukascopy") -> list[Bar]:
    """Каталог YYYY/MM/DD.bi5. Сутки читаются по порядку, холдаут не открывается."""
    root = Path(root)
    paths = sorted(root.glob("*/*/*.bi5"))
    if not paths:
        raise DataError(f"в {root} нет YYYY/MM/DD.bi5")
    out: list[Bar] = []
    for path in paths:
        try:
            day = date(int(path.parts[-3]), int(path.parts[-2]), int(path.stem))
        except ValueError as exc:
            raise DataError(f"не разобрать дату {path}") from exc
        if day >= HOLDOUT_DAY:
            raise DataError(f"отказ: файл {path} в холдауте, он не читается")
        out.extend(decode_bid_m1(path.read_bytes(), day, source))
    return out


def shift_bars(bars: list[Bar], offset: float, source: str | None = None) -> list[Bar]:
    """Сдвинуть bid и ask на одну и ту же величину. Источник можно переименовать."""
    shifted: list[Bar] = []
    for bar in bars:
        shifted.append(
            Bar(
                bar.tf,
                bar.time_msc,
                bar.open + offset,
                bar.high + offset,
                bar.low + offset,
                bar.close + offset,
                bar.ask_open + offset,
                bar.ask_high + offset,
                bar.ask_low + offset,
                bar.ask_close + offset,
                bar.tick_count,
                bar.volume,
                bar.source if source is None else source,
            )
        )
    return shifted


def in_session(bars: list[Bar], session=None) -> list[Bar]:
    """Минута остаётся, если её открытие попадает в торговую сессию.

    Суббота у Dukascopy — плоская свеча на каждой минуте. В сессии Exness
    её нет, и дневной бар из неё сломал бы склейку воскресенья.
    """
    gate = session if session is not None else ExnessGoldSession()
    return [bar for bar in bars if gate.is_open(bar.time_msc)]


def estimate_bid_offset(reference: list[Bar], other: list[Bar]) -> dict:
    """Медиана reference.close − other.close по общему time_msc.

    reference — Exness, other — Dukascopy. Положительное число значит,
    что Exness выше. Сравниваются только бары одного таймфрейма.
    """
    if not reference or not other:
        raise DataError("для сдвига нужны обе стороны пересечения")
    if reference[0].tf != other[0].tf:
        raise DataError("сдвиг: разный таймфрейм")
    right = {bar.time_msc: bar.close for bar in other}
    deltas = [bar.close - right[bar.time_msc] for bar in reference if bar.time_msc in right]
    if not deltas:
        raise DataError("на пересечении нет общих баров")
    ordered = sorted(deltas)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        median = ordered[mid]
    else:
        median = (ordered[mid - 1] + ordered[mid]) / 2.0

    def pct(p: float) -> float:
        rank = (len(ordered) - 1) * p
        lo = int(rank)
        hi = min(lo + 1, len(ordered) - 1)
        weight = rank - lo
        return ordered[lo] * (1.0 - weight) + ordered[hi] * weight

    return {
        "bars": len(deltas),
        "median": median,
        "p10": pct(0.10),
        "p90": pct(0.90),
        "timeframe": reference[0].tf,
    }


def stitch_bars(warmup: list[Bar], live: list[Bar]) -> list[Bar]:
    """Склеить закрытые бары одного ТФ без дыры и без общего времени.

    Последний бар прогрева закрывается ровно в открытие первого живого.
    Источник каждого бара сохраняется.
    """
    if not warmup or not live:
        raise DataError("склейка: нужны и прогрев, и живые бары")
    tf = warmup[0].tf
    if any(bar.tf != tf for bar in warmup) or any(bar.tf != tf for bar in live):
        raise DataError("склейка: бары разных таймфреймов")
    period = TF_MS[tf]
    boundary = live[0].time_msc
    if any(bar.time_msc >= boundary for bar in warmup):
        raise DataError("склейка: прогрев налезает на живой бар")
    if any(bar.time_msc < boundary for bar in live):
        raise DataError("склейка: живой бар раньше границы")
    if warmup[-1].time_msc + period != boundary:
        raise DataError(
            f"склейка: дыра или нахлёст, прогрев кончается в {warmup[-1].time_msc + period}, живой бар в {boundary}"
        )
    for seq in (warmup, live):
        for prev, nxt in zip(seq, seq[1:]):
            if nxt.time_msc <= prev.time_msc:
                raise DataError("склейка: время бара не растёт")
    return list(warmup) + list(live)


def gap_is_session_closed(start_msc: int, end_msc: int, session) -> bool:
    """Каждая минута [start, end) закрыта. start == end — не дыра."""
    if end_msc < start_msc:
        return False
    minute = 60_000
    cursor = start_msc
    while cursor < end_msc:
        if session.is_open(cursor):
            return False
        cursor += minute
    return True


def cut_before_live(bars: list[Bar], first_tick_msc: int, session) -> list[Bar]:
    """Оставить бары, которые полностью закрылись к открытию живого бара.

    Дыра до границы допустима только если в ней сессия закрыта
    (ночная пауза, выходные). Нахлёст на живой бар — ошибка.
    """
    if not bars:
        raise DataError("прогрев пуст")
    tf = bars[0].tf
    period = TF_MS[tf]
    boundary = align_open(first_tick_msc, period)
    if any(bar.tf != tf for bar in bars):
        raise DataError("прогрев: смешанный таймфрейм")
    kept = [bar for bar in bars if bar.time_msc + period <= boundary]
    if not kept:
        raise DataError(f"{tf}: прогрев не доходит до {boundary}")
    end = kept[-1].time_msc + period
    if end > boundary:
        raise DataError(f"{tf}: прогрев перекрывает живой бар")
    if end < boundary and not gap_is_session_closed(end, boundary, session):
        raise DataError(f"{tf}: дыра в открытой сессии {end} .. {boundary}")
    return kept


def warmup_timeframes(m1: list[Bar], timeframes: list[str], first_tick_msc: int, session) -> dict[str, list[Bar]]:
    """M1 уже сдвинуты и отфильтрованы сессией. На каждый ТФ — срез до первого тика."""
    ready: dict[str, list[Bar]] = {}
    for tf in timeframes:
        aggregated = aggregate_bars(m1, tf)
        ready[tf] = cut_before_live(aggregated, first_tick_msc, session)
    return ready


def iter_days(start: date, end: date):
    if end >= HOLDOUT_DAY or start >= HOLDOUT_DAY:
        raise DataError("отказ: диапазон загрузки задевает холдаут с 2026-10-16")
    day = start
    while day <= end:
        yield day
        day += timedelta(days=1)
