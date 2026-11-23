"""Исполнение защитных уровней и отложенных заявок.

Длинная позиция смотрит на bid, короткая — на ask.

Стоп (SL и стоп-заявка): если цена перескочила уровень, исполнение по
фактической цене, а не по уровню. Это проскальзывание на гэпе.

Тейк и лимитная заявка: исполнение по цене заявки. Улучшение за гэп не даём.

Лимит исполняется, только когда котировка прошла цену на `penetration`
(покупка: ask <= limit - penetration). Касание при penetration > 0 — не сделка.

Одна метка времени: если в пачке тиков с одной миллисекундой (или на отрезке
от предыдущей цены) достижимы и SL, и TP, берётся стоп. Это худший исход,
потому что порядок внутри миллисекунды не считается надёжным.
"""

from __future__ import annotations


def stop_fill(side: int, price: float, level: float) -> float:
    """Цена стопа с учётом гэпа. side +1 — длинная (продаём по bid)."""
    if side == 1:
        return price if price < level else level
    return price if price > level else level


def resolve_protective(
    side: int,
    prev: float | None,
    prices: list[float],
    sl: float | None,
    tp: float | None,
) -> tuple[str, float, bool] | None:
    """Вернуть (reason, fill, ambiguous) или None.

    prices — котировки стороны позиции в порядке файла, одна миллисекунда
    либо один тик. prev — последняя котировка предыдущей миллисекунды.
    """
    if not prices:
        return None
    anchor = prices[0] if prev is None else prev
    lo = min([anchor, *prices])
    hi = max([anchor, *prices])

    def level_in(level: float | None) -> bool:
        return level is not None and level > 0.0 and lo <= level <= hi

    def beyond_sl(price: float) -> bool:
        if sl is None or sl <= 0.0:
            return False
        return price <= sl if side == 1 else price >= sl

    def beyond_tp(price: float) -> bool:
        if tp is None or tp <= 0.0:
            return False
        return price >= tp if side == 1 else price <= tp

    sl_hit = (sl is not None and sl > 0.0 and level_in(sl)) or any(beyond_sl(p) for p in prices)
    tp_hit = (tp is not None and tp > 0.0 and level_in(tp)) or any(beyond_tp(p) for p in prices)
    if not sl_hit and not tp_hit:
        return None
    if sl_hit and tp_hit:
        assert sl is not None
        worst = min(prices) if side == 1 else max(prices)
        return "sl", stop_fill(side, worst, sl), True
    if sl_hit:
        assert sl is not None
        for price in prices:
            if beyond_sl(price) or (prev is not None and min(prev, price) <= sl <= max(prev, price)):
                return "sl", stop_fill(side, price, sl), False
        return "sl", stop_fill(side, prices[-1], sl), False
    assert tp is not None
    return "tp", tp, False


def limit_hit(side: int, quote: float, limit: float, penetration: float) -> bool:
    """side +1 — buy limit, котировка ask. side −1 — sell limit, котировка bid."""
    if penetration < 0.0:
        raise ValueError("penetration < 0")
    if side == 1:
        return quote <= limit - penetration
    return quote >= limit + penetration


def stop_entry_hit(side: int, quote: float, level: float) -> bool:
    if side == 1:
        return quote >= level
    return quote <= level
