"""Порт hybrid/hybrid-asia-breakout_v1.1.mq5.

Источник правды — MQL, не отчёт тестера. Порядок OnTick тот же:

1. новый бар TradingTimeframe замечается до проверки сессии;
2. закрытая сессия выходит сразу, коробка в этот тик не строится;
3. открытая позиция при hour >= CloseHour закрывается и на этом тике
   вход уже не рассматривается;
4. коробка Азии — один раз, на первом тике, у которого серверная секунда
   дошла до конца окна (06:59:59 при конце 07:00). High/low — bid M1
   с открытия startHour до открытия endHour, включая ещё не закрытую
   минуту. Тик ровно в endHour в коробку не входит;
5. одна попытка в день. Лот 0 съедает день. Отказ по спреду
   (MaxSpreadToSL) день не съедает: CLOSE повторит на следующем баре;
6. BREAKOUT_CLOSE смотрит close последнего закрытого бара и только если
   этот бар открылся не раньше конца Азии;
7. режим: OFF — сигнал как есть; FILTER — во флэте и при короткой
   истории день пропускается; SWITCH — во флэте вход против пробоя,
   стоп за экстремумом пробоя.

Задержка тестера живёт в движке: цена входа и время закрытия — котировка
строго раньше submit+latency. ATR здесь нет. Трейлинг и
закрытие по проскальзыванию в обоих пресетах выключены; включить их
в конфиге — ошибка, а не тихий пропуск.
"""

from __future__ import annotations

import bisect
from dataclasses import dataclass

from ..bars import TF_MS
from ..types import ConfigError, round_price
from ..strategy import Context

DAY_MS = 86_400_000
HOUR_MS = 3_600_000


@dataclass
class AsiaBreakoutConfig:
    asia_start_hour: int = 0
    asia_end_hour: int = 7
    min_box_points: float = 3000.0
    max_box_points: float = 0.0
    entry_mode: str = "close"  # touch | close
    timeframe: str = "M15"
    entry_end_hour: int = 11
    break_buffer_points: float = 200.0
    stop_mode: str = "opposite"  # opposite | mid
    sl_buffer_points: float = 200.0
    min_sl_points: float = 1000.0
    risk_reward: float = 1.5
    close_hour: int = 20
    regime: str = "off"  # off | filter | switch
    regime_tf: str = "H1"
    regime_period: int = 24
    regime_threshold: float = 0.30
    risk_percent: float = 3.0
    max_risk_overshoot: float = 1.5
    risk_basis: str = "balance"
    max_spread_to_sl: float = 0.10
    magic: int = 71007
    trailing: str = "off"
    close_on_slippage: bool = False

    def __post_init__(self) -> None:
        if self.timeframe not in TF_MS or self.regime_tf not in TF_MS:
            raise ConfigError("неизвестный таймфрейм")
        if self.entry_mode not in ("touch", "close"):
            raise ConfigError("entry_mode")
        if self.stop_mode not in ("opposite", "mid"):
            raise ConfigError("stop_mode")
        if self.regime not in ("off", "filter", "switch"):
            raise ConfigError("regime")
        if self.risk_basis not in ("balance", "equity"):
            raise ConfigError("risk_basis")
        if not 0 <= self.asia_start_hour < self.asia_end_hour <= 24:
            raise ConfigError("окно Азии")
        if not 0 <= self.entry_end_hour <= 24:
            raise ConfigError("EntryEndHour")
        if self.regime_period < 1:
            raise ConfigError("RegimePeriod")
        if self.trailing != "off" or self.close_on_slippage:
            raise ConfigError("трейлинг и close-on-slippage в порте Азии не реализованы")


def code_defaults() -> AsiaBreakoutConfig:
    """Заводские input'ы v1.1: закрытие M15, стоп за противоположной границей, RR 1.5."""
    return AsiaBreakoutConfig()


def trend_filter() -> AsiaBreakoutConfig:
    """Аудит asia-breakout-trend: StopMode=1, RiskReward=2, RegimeMode=1.

    Остальное — заводские значения, включая риск 3%.
    """
    return AsiaBreakoutConfig(stop_mode="mid", risk_reward=2.0, regime="filter")


def efficiency_ratio(closes: list[float], period: int) -> float | None:
    """Kaufman ER по закрытым барам. closes — старые в начале, последний закрытый в конце.

    None — баров меньше, чем period+1. Ноль — цена не сдвинулась ни на одном шаге.
    """
    if period < 1 or len(closes) < period + 1:
        return None
    window = closes[-(period + 1) :]
    path = 0.0
    for i in range(period):
        path += abs(window[-1 - i] - window[-2 - i])
    if path == 0.0:
        return 0.0
    return abs(window[-1] - window[0]) / path


def _day_start(time_msc: int) -> int:
    return time_msc - (time_msc % DAY_MS)


def _hour(time_msc: int) -> int:
    return (time_msc // 1000) % 86_400 // 3600


class AsiaBreakoutStrategy:
    def __init__(self, config: AsiaBreakoutConfig | None = None, digits: int = 3, adjusted_point: float = 0.001):
        self.cfg = config if config is not None else code_defaults()
        self.digits = digits
        self.adjusted_point = adjusted_point
        self.box_day = 0
        self.box_ok = False
        self.box_hi = 0.0
        self.box_lo = 0.0
        self.traded = False
        self._last_bar: int | None = None
        self.last_er: float | None = None
        self.counts: dict[str, int] = {}
        self.decisions: list[dict] = []

    def required_timeframes(self) -> list[str]:
        out = ["M1", self.cfg.timeframe]
        if self.cfg.regime != "off" and self.cfg.regime_tf not in out:
            out.append(self.cfg.regime_tf)
        return out

    def on_start(self, ctx: Context) -> None:
        return None

    def on_bar_close(self, ctx: Context, bar) -> None:
        return None

    def on_tick(self, ctx: Context, tick) -> None:
        forming = ctx.forming_open_msc(self.cfg.timeframe)
        new_bar = forming is not None and forming != self._last_bar
        if new_bar:
            self._last_bar = forming
        if not ctx.session_open():
            return
        now = ctx.now_msc()
        hour = _hour(now)
        if ctx.position is not None and self.cfg.close_hour > 0 and hour >= self.cfg.close_hour:
            ctx.close_position("time")
            self._bump("time_close")
            return
        self._update_box(ctx, now)
        today = _day_start(now)
        if ctx.position is not None or self.traded or not self.box_ok or self.box_day != today:
            return
        if hour < self.cfg.asia_end_hour or hour >= self.cfg.entry_end_hour:
            return
        buf = self.cfg.break_buffer_points * self.adjusted_point
        if self.cfg.entry_mode == "touch":
            if tick.ask >= self.box_hi + buf:
                self._enter(ctx, 1)
            elif tick.bid <= self.box_lo - buf:
                self._enter(ctx, -1)
            return
        if not new_bar:
            return
        closed = ctx.bars(self.cfg.timeframe)
        if not closed:
            return
        bar = closed[-1]
        if bar.time_msc < self.box_day + self.cfg.asia_end_hour * HOUR_MS:
            return
        if bar.close > self.box_hi + buf:
            self._enter(ctx, 1)
        elif bar.close < self.box_lo - buf:
            self._enter(ctx, -1)

    def _bump(self, name: str) -> None:
        self.counts[name] = self.counts.get(name, 0) + 1

    def _note(self, ctx: Context, event: str, sig: int) -> None:
        self.decisions.append({"time_msc": ctx.now_msc(), "event": event, "sig": sig, "day": self.box_day})

    def _update_box(self, ctx: Context, now: int) -> None:
        day = _day_start(now)
        if self.box_day == day:
            return
        ready = day + self.cfg.asia_end_hour * HOUR_MS - 1000
        if now < ready:
            return
        hi, lo = self._span(ctx, day + self.cfg.asia_start_hour * HOUR_MS, day + self.cfg.asia_end_hour * HOUR_MS)
        if hi is None or lo is None or hi <= 0.0 or lo <= 0.0:
            return
        if self.box_day != 0 and self.box_ok and not self.traded:
            self._bump("no_break")
        self.box_day = day
        self.box_hi = hi
        self.box_lo = lo
        self.traded = False
        self._bump("days")
        size = (hi - lo) / self.adjusted_point
        self.box_ok = size >= self.cfg.min_box_points and (self.cfg.max_box_points <= 0.0 or size <= self.cfg.max_box_points)
        if not self.box_ok:
            self._bump("skip_size")

    def _span(self, ctx: Context, start_msc: int, end_msc: int) -> tuple[float | None, float | None]:
        """Bid high/low M1 с открытием в [start, end). Конец не включается."""
        bars = ctx.bars("M1")
        hi: float | None = None
        lo: float | None = None
        if bars:
            i = bisect.bisect_left(bars, start_msc, key=lambda bar: bar.time_msc)
            while i < len(bars) and bars[i].time_msc < end_msc:
                bar = bars[i]
                hi = bar.high if hi is None else max(hi, bar.high)
                lo = bar.low if lo is None else min(lo, bar.low)
                i += 1
        forming = ctx.forming_bar("M1")
        if forming is not None and start_msc <= forming.time_msc < end_msc:
            hi = forming.high if hi is None else max(hi, forming.high)
            lo = forming.low if lo is None else min(lo, forming.low)
        return hi, lo

    def _regime_dir(self, ctx: Context, sig: int) -> int:
        if self.cfg.regime == "off":
            self.last_er = None
            return sig
        closes = [bar.close for bar in ctx.bars(self.cfg.regime_tf)]
        er = efficiency_ratio(closes, self.cfg.regime_period)
        self.last_er = er
        if er is None:
            return 0
        if er >= self.cfg.regime_threshold:
            return sig
        if self.cfg.regime == "switch":
            return -sig
        return 0

    def _break_extreme(self, ctx: Context, direction: int) -> float:
        start = self.box_day + self.cfg.asia_end_hour * HOUR_MS
        tick = ctx.tick()
        if direction == -1:
            ext = tick.bid
            hi, _lo = self._span(ctx, start, ctx.now_msc() + 1)
            if hi is not None:
                ext = max(ext, hi)
            return max(ext, self.box_hi)
        ext = tick.ask
        _hi, lo = self._span(ctx, start, ctx.now_msc() + 1)
        if lo is not None:
            ext = min(ext, lo)
        return min(ext, self.box_lo)

    def _enter(self, ctx: Context, sig: int) -> None:
        direction = self._regime_dir(ctx, sig)
        if direction == 0:
            self.traded = True
            self._bump("regime_skip")
            self._note(ctx, "regime_skip", sig)
            return
        fade = direction != sig
        tick = ctx.tick()
        entry = tick.ask if direction == 1 else tick.bid
        pt = self.adjusted_point
        if fade:
            anchor = self._break_extreme(ctx, direction)
        elif self.cfg.stop_mode == "mid":
            anchor = (self.box_hi + self.box_lo) / 2.0
        else:
            anchor = self.box_lo if direction == 1 else self.box_hi
        sl = anchor - direction * self.cfg.sl_buffer_points * pt
        min_dist = self.cfg.min_sl_points * pt
        if direction * (entry - sl) < min_dist:
            sl = entry - direction * min_dist
        sl = round_price(sl, self.digits)
        dist = abs(entry - sl)
        tp = None
        if self.cfg.risk_reward > 0.0:
            tp = round_price(entry + direction * self.cfg.risk_reward * dist, self.digits)
        self.traded = True
        try:
            lot = ctx.size_for_risk(
                dist,
                self.cfg.risk_percent,
                basis=self.cfg.risk_basis,
                max_risk_overshoot=self.cfg.max_risk_overshoot,
            )
        except Exception:
            self._bump("sizing_error")
            raise
        if lot <= 0.0:
            self._bump("sizing")
            self._note(ctx, "sizing", direction)
            return
        spread = tick.ask - tick.bid
        if self.cfg.max_spread_to_sl > 0.0 and dist > 0.0 and spread > self.cfg.max_spread_to_sl * dist:
            self.traded = False
            self._bump("spread")
            self._note(ctx, "spread", direction)
            return
        comment = f"ASIA_BO {'up' if sig == 1 else 'down'}{' fade' if fade else ''}"
        if direction == 1:
            order_id = ctx.buy_market(lot, sl, tp, comment)
        else:
            order_id = ctx.sell_market(lot, sl, tp, comment)
        if order_id is None:
            return
        self._bump("trades")
        if fade:
            self._bump("fade")
        self._note(ctx, "trade", direction)
