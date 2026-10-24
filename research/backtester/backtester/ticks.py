"""Поток тиков: Exness csv.gz и Dukascopy parquet → один Tick.

Формула котировки (сначала спред, потом сдвиг уровня):

    mid = (bid + ask) / 2
    half = (ask - bid) * spread_multiplier / 2
    bid' = mid - half - spread_addon / 2 + price_offset
    ask' = mid + half + spread_addon / 2 + price_offset

spread_addon увеличивает спред на эту величину в цене, середина не смещается.
price_offset сдвигает обе стороны (Exness сидит примерно на +0.20 USD
относительно Dukascopy). spread_multiplier < 1 сужает спред Dukascopy.
После поправки bid > ask — ошибка, поток останавливается.
"""

from __future__ import annotations

import csv
import gzip
from pathlib import Path
from typing import Iterator, Sequence

from .types import DataError, Tick


def adjust_quote(
    bid: float,
    ask: float,
    *,
    price_offset: float = 0.0,
    spread_multiplier: float = 1.0,
    spread_addon: float = 0.0,
) -> tuple[float, float]:
    if spread_multiplier < 0.0 or spread_addon < 0.0:
        raise DataError("множитель спреда и добавка не могут быть отрицательными")
    if not (bid > 0.0 and ask > 0.0) or bid > ask:
        raise DataError(f"битая котировка bid={bid} ask={ask}")
    mid = (bid + ask) / 2.0
    half = (ask - bid) * spread_multiplier / 2.0
    half_add = spread_addon / 2.0
    bid2 = mid - half - half_add + price_offset
    ask2 = mid + half + half_add + price_offset
    if not (bid2 > 0.0 and ask2 > 0.0) or bid2 > ask2:
        raise DataError(f"котировка схлопнулась после поправки: bid={bid2} ask={ask2}")
    return bid2, ask2


def _apply(tick: Tick, price_offset: float, spread_multiplier: float, spread_addon: float) -> Tick:
    if price_offset == 0.0 and spread_multiplier == 1.0 and spread_addon == 0.0:
        return tick
    bid, ask = adjust_quote(
        tick.bid,
        tick.ask,
        price_offset=price_offset,
        spread_multiplier=spread_multiplier,
        spread_addon=spread_addon,
    )
    return Tick(
        time_msc=tick.time_msc,
        bid=bid,
        ask=ask,
        last=tick.last,
        volume=tick.volume,
        bid_vol=tick.bid_vol,
        ask_vol=tick.ask_vol,
        flags=tick.flags,
    )


def iter_exness_csv_gz(path: str | Path) -> Iterator[Tick]:
    """CSV gzip: time_msc,bid,ask,last,volume[,volume_real],flags.

    Повторы одной миллисекунды сохраняются в порядке файла.
    """
    path = Path(path)
    with gzip.open(path, "rt", newline="") as fh:
        reader = csv.reader(fh)
        try:
            header = next(reader)
        except StopIteration:
            raise DataError(f"пустой файл {path}") from None
        cols = [h.strip() for h in header]
        need = ("time_msc", "bid", "ask")
        if any(n not in cols for n in need):
            raise DataError(f"{path}: в заголовке нет {need}, есть {cols}")
        idx = {name: cols.index(name) for name in cols}
        prev: int | None = None
        for row_n, row in enumerate(reader, start=2):
            if not row or all(not c.strip() for c in row):
                continue
            try:
                time_msc = int(row[idx["time_msc"]])
                bid = float(row[idx["bid"]])
                ask = float(row[idx["ask"]])
            except (ValueError, IndexError) as exc:
                raise DataError(f"{path}:{row_n}: не читается строка") from exc
            last = float(row[idx["last"]]) if "last" in idx and row[idx["last"]] else 0.0
            volume = float(row[idx["volume"]]) if "volume" in idx and row[idx["volume"]] else 0.0
            flags = int(float(row[idx["flags"]])) if "flags" in idx and row[idx["flags"]] else 0
            if prev is not None and time_msc < prev:
                raise DataError(f"{path}:{row_n}: время пошло назад {time_msc} < {prev}")
            prev = time_msc
            yield Tick(time_msc=time_msc, bid=bid, ask=ask, last=last, volume=volume, flags=flags)


def iter_dukascopy_parquet(path: str | Path) -> Iterator[Tick]:
    """Parquet zstd: time_msc (UTC мс), bid, ask, bid_vol, ask_vol."""
    try:
        import pyarrow.parquet as pq
    except ImportError as exc:
        raise DataError("для parquet нужен пакет pyarrow") from exc
    path = Path(path)
    pf = pq.ParquetFile(path)
    names = set(pf.schema_arrow.names)
    need = {"time_msc", "bid", "ask"}
    if not need <= names:
        raise DataError(f"{path}: нет колонок {need - names}")
    cols = [c for c in ("time_msc", "bid", "ask", "bid_vol", "ask_vol") if c in names]
    prev: int | None = None
    for batch in pf.iter_batches(batch_size=65_536, columns=cols):
        data = batch.to_pydict()
        n = len(data["time_msc"])
        bids = data["bid"]
        asks = data["ask"]
        bvol = data.get("bid_vol")
        avol = data.get("ask_vol")
        times = data["time_msc"]
        for i in range(n):
            time_msc = int(times[i])
            if prev is not None and time_msc < prev:
                raise DataError(f"{path}: время пошло назад {time_msc} < {prev}")
            prev = time_msc
            yield Tick(
                time_msc=time_msc,
                bid=float(bids[i]),
                ask=float(asks[i]),
                bid_vol=float(bvol[i]) if bvol is not None else 0.0,
                ask_vol=float(avol[i]) if avol is not None else 0.0,
            )


def iter_ticks(
    paths: Sequence[str | Path],
    source: str,
    *,
    start_msc: int | None = None,
    end_msc: int | None = None,
    price_offset: float = 0.0,
    spread_multiplier: float = 1.0,
    spread_addon: float = 0.0,
) -> Iterator[Tick]:
    """Склеить файлы. end_msc исключительный: тик с этим временем уже не отдаётся.

    Так можно оборвать чтение на полуночи 2026-10-06 и не забирать холдаут.
    """
    if source not in ("exness", "dukascopy"):
        raise DataError("source должен быть exness или dukascopy")
    reader = iter_exness_csv_gz if source == "exness" else iter_dukascopy_parquet
    prev: int | None = None
    for path in sorted(Path(p) for p in paths):
        for tick in reader(path):
            if start_msc is not None and tick.time_msc < start_msc:
                prev = tick.time_msc
                continue
            if end_msc is not None and tick.time_msc >= end_msc:
                return
            if prev is not None and tick.time_msc < prev:
                raise DataError(f"файлы не по времени: {tick.time_msc} < {prev}")
            prev = tick.time_msc
            yield _apply(tick, price_offset, spread_multiplier, spread_addon)
