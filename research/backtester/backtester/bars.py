"""Бары из тиков. Сигнал видит только закрытый бар.

Граница бара — сетка UTC от эпохи (сервер Exness = UTC+0, своего DST нет).
Тик ровно на границе открывает новый бар и не попадает в предыдущий.
Пустые интервалы без тиков баров не создают: так же делает MT5.
OHLC — по bid. Ask копится отдельно и в сигнал не подмешивается.
"""

from __future__ import annotations

from .types import Bar, DataError, Tick

TF_MS: dict[str, int] = {
    "M1": 60_000,
    "M2": 120_000,
    "M5": 300_000,
    "M15": 900_000,
    "M30": 1_800_000,
    "H1": 3_600_000,
    "H2": 7_200_000,
    "H3": 10_800_000,
    "H4": 14_400_000,
    "H6": 21_600_000,
    "H8": 28_800_000,
    "H12": 43_200_000,
    "D1": 86_400_000,
}


def align_open(time_msc: int, tf_ms: int) -> int:
    if tf_ms <= 0:
        raise DataError("период бара <= 0")
    return time_msc - (time_msc % tf_ms)


class BarBuilder:
    def __init__(self, timeframes: list[str]):
        unknown = [tf for tf in timeframes if tf not in TF_MS]
        if unknown:
            raise DataError(f"неизвестный таймфрейм: {unknown}")
        # Стабильный порядок: сначала старшие, чтобы на общей границе
        # стратегия увидела закрытый старший бар раньше младшего.
        self.timeframes = sorted(timeframes, key=lambda tf: -TF_MS[tf])
        self._sec = {tf: TF_MS[tf] for tf in self.timeframes}
        self._cur: dict[str, dict] = {}
        self.closed: dict[str, list[Bar]] = {tf: [] for tf in self.timeframes}

    def seed_closed(self, bars: list[Bar]) -> None:
        """Готовые закрытые бары до первого тика (прогрев индикаторов).

        Бар, который ещё не закрыт к моменту первого тика, класть нельзя.
        """
        for bar in bars:
            if bar.tf not in self.closed:
                raise DataError(f"прогрев: таймфрейм {bar.tf} не запрошен")
            bucket = self.closed[bar.tf]
            if bucket and bar.time_msc <= bucket[-1].time_msc:
                raise DataError("прогрев: бары должны идти строго вперёд")
            bucket.append(bar)

    def forming_open(self, tf: str) -> int | None:
        cur = self._cur.get(tf)
        return None if cur is None else int(cur["open"])

    def add(self, tick: Tick) -> list[Bar]:
        closed_now: list[Bar] = []
        for tf in self.timeframes:
            period = self._sec[tf]
            open_msc = align_open(tick.time_msc, period)
            cur = self._cur.get(tf)
            if cur is None:
                self._cur[tf] = _new(tf, open_msc, tick)
                continue
            if open_msc < cur["open"]:
                raise DataError(f"{tf}: тик попал в уже закрытый бар")
            if open_msc != cur["open"]:
                bar = _freeze(cur)
                self.closed[tf].append(bar)
                closed_now.append(bar)
                self._cur[tf] = _new(tf, open_msc, tick)
            else:
                _update(cur, tick)
        return closed_now


def _new(tf: str, open_msc: int, tick: Tick) -> dict:
    return {
        "tf": tf,
        "open": open_msc,
        "bid_o": tick.bid,
        "bid_h": tick.bid,
        "bid_l": tick.bid,
        "bid_c": tick.bid,
        "ask_o": tick.ask,
        "ask_h": tick.ask,
        "ask_l": tick.ask,
        "ask_c": tick.ask,
        "n": 1,
        "vol": tick.volume,
    }


def _update(cur: dict, tick: Tick) -> None:
    cur["bid_h"] = max(cur["bid_h"], tick.bid)
    cur["bid_l"] = min(cur["bid_l"], tick.bid)
    cur["bid_c"] = tick.bid
    cur["ask_h"] = max(cur["ask_h"], tick.ask)
    cur["ask_l"] = min(cur["ask_l"], tick.ask)
    cur["ask_c"] = tick.ask
    cur["n"] += 1
    cur["vol"] += tick.volume


def _freeze(cur: dict) -> Bar:
    return Bar(
        tf=cur["tf"],
        time_msc=cur["open"],
        open=cur["bid_o"],
        high=cur["bid_h"],
        low=cur["bid_l"],
        close=cur["bid_c"],
        ask_open=cur["ask_o"],
        ask_high=cur["ask_h"],
        ask_low=cur["ask_l"],
        ask_close=cur["ask_c"],
        tick_count=cur["n"],
        volume=cur["vol"],
    )


def aggregate_bars(bars: list[Bar], tf: str) -> list[Bar]:
    """Собрать старший ТФ из уже закрытых младших баров (только для прогрева)."""
    if tf not in TF_MS:
        raise DataError(tf)
    period = TF_MS[tf]
    out: list[Bar] = []
    cur: dict | None = None
    for bar in bars:
        open_msc = align_open(bar.time_msc, period)
        if cur is None or open_msc != cur["open"]:
            if cur is not None:
                out.append(_freeze(cur))
            cur = {
                "tf": tf,
                "open": open_msc,
                "bid_o": bar.open,
                "bid_h": bar.high,
                "bid_l": bar.low,
                "bid_c": bar.close,
                "ask_o": bar.ask_open,
                "ask_h": bar.ask_high,
                "ask_l": bar.ask_low,
                "ask_c": bar.ask_close,
                "n": bar.tick_count,
                "vol": bar.volume,
            }
        else:
            cur["bid_h"] = max(cur["bid_h"], bar.high)
            cur["bid_l"] = min(cur["bid_l"], bar.low)
            cur["bid_c"] = bar.close
            cur["ask_h"] = max(cur["ask_h"], bar.ask_high)
            cur["ask_l"] = min(cur["ask_l"], bar.ask_low)
            cur["ask_c"] = bar.ask_close
            cur["n"] += bar.tick_count
            cur["vol"] += bar.volume
    if cur is not None:
        out.append(_freeze(cur))
    return out
