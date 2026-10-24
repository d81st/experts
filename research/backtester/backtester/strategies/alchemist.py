"""Порт hybrid/hybrid-alchemist_v1.0.mq5, вариант h1-x12-st.

Источник правды — MQL, не отчёт тестера. Что повторено буквально:

- сигнал только по закрытым барам (AlchemistSignal: бар 1 против бара 2);
- H4: бар iBarShift(открытие сигнального H1) + 1, то есть последний H4,
  закрытый к началу этого H1;
- вход по рынку, когда сессия открыта; если бар открылся в паузе,
  заявка ждёт первый тик после открытия и не затирается пустым сигналом;
- стоп = max(StopAtrMult × ATR последнего закрытого H1, MinSLPoints × adjustedPoint);
  ATR читается в момент входа, а не в момент сигнала;
- лот от баланса (ACCOUNT_BALANCE в MQL), не от средств;
- выход через ExitBars: iBarShift >= ExitBars, то есть бар входа и ещё
  ExitBars−1 баров уже закрыты;
- фильтр D1 = структура, окно и склейка воскресенья как в MarketStructure.mqh;
- MaxSpreadToSL, MaxRiskOvershoot, одна позиция.

Сознательно не включено, потому что у h1-x12-st это выключено и код бы
притворился, что фильтр работает: режим рынка, новости, трейлинг,
закрытие по проскальзыванию. Если их включить в конфиге, порт падает.
"""

from __future__ import annotations

from dataclasses import dataclass

import bisect

from ..bars import TF_MS, align_open
from ..indicators import cci_at, ema_series, hma_last_two, sma_at, wilder_atr_last
from ..structure import d1_trend
from ..types import ConfigError, round_price
from ..strategy import Context


@dataclass
class AlchemistConfig:
    timeframe: str = "H1"
    ma_period: int = 200
    use_hma: bool = True
    hma_period: int = 21
    use_cci: bool = True
    cci_period: int = 20
    cci_level: float = 100.0
    use_htf: bool = True
    htf: str = "H4"
    htf_ema_period: int = 50
    trade_side: str = "both"  # both | long | short
    exit_bars: int = 12
    exit_on_opposite: bool = False
    atr_period: int = 14
    stop_atr_mult: float = 3.0
    min_sl_points: float = 1000.0
    risk_reward: float = 0.0
    day_trend: str = "structure"  # off | structure | ema
    day_structure_len: int = 5
    day_ema_period: int = 50
    risk_percent: float = 1.0
    max_risk_overshoot: float = 1.5
    # MQL читает баланс. Смена на equity — уже другой эксперимент.
    risk_basis: str = "balance"
    max_spread_to_sl: float = 0.10
    magic: int = 71012
    comment: str = "HAL"
    regime: str = "off"
    news_minutes: int = 0
    trailing: str = "off"
    close_on_slippage: bool = False

    def __post_init__(self) -> None:
        if self.timeframe not in TF_MS or (self.use_htf and self.htf not in TF_MS):
            raise ConfigError("неизвестный таймфрейм")
        if self.trade_side not in ("both", "long", "short"):
            raise ConfigError("trade_side")
        if self.day_trend not in ("off", "structure", "ema"):
            raise ConfigError("day_trend")
        if self.risk_basis not in ("balance", "equity"):
            raise ConfigError("risk_basis")
        if self.regime != "off" or self.news_minutes != 0 or self.trailing != "off" or self.close_on_slippage:
            raise ConfigError(
                "режим, новости, трейлинг и close-on-slippage в порте h1-x12-st не реализованы"
            )
        if self.ma_period < 1 or self.atr_period < 1 or self.exit_bars < 0:
            raise ConfigError("период или ExitBars")


def h1_x12_st() -> AlchemistConfig:
    """Заводской вариант: H1, выход 12 баров, структура D1, стоп 3×ATR."""
    return AlchemistConfig()


def bar_age(closed_opens: list[int], forming_open: int | None, entry_msc: int, tf_ms: int) -> int:
    """iBarShift(время входа): сколько баров отделяют текущий бар от бара входа."""
    entry_open = align_open(entry_msc, tf_ms)
    if forming_open is None or entry_open >= forming_open:
        return 0
    return 1 + sum(1 for open_msc in closed_opens if open_msc > entry_open)


class AlchemistStrategy:
    def __init__(self, config: AlchemistConfig | None = None, digits: int = 3, adjusted_point: float = 0.001):
        self.cfg = config if config is not None else h1_x12_st()
        self.digits = digits
        self.adjusted_point = adjusted_point
        self.pending = False
        self.pending_sig = 0
        self.pending_day = 0
        self.counts: dict[str, int] = {}
        self._ema: list[float] | None = None
        self._ema_n = -1

    def required_timeframes(self) -> list[str]:
        out = [self.cfg.timeframe]
        if self.cfg.use_htf and self.cfg.htf not in out:
            out.append(self.cfg.htf)
        if self.cfg.day_trend != "off" and "D1" not in out:
            out.append("D1")
        return out

    def on_start(self, ctx: Context) -> None:
        return None

    def on_bar_close(self, ctx: Context, bar) -> None:
        if bar.tf != self.cfg.timeframe:
            return
        self._on_new_bar(ctx)

    def on_tick(self, ctx: Context, tick) -> None:
        if self.pending:
            self._try_act(ctx)

    def _bump(self, name: str) -> None:
        self.counts[name] = self.counts.get(name, 0) + 1

    def _on_new_bar(self, ctx: Context) -> None:
        fresh = self._signal(ctx)
        if fresh != 0 or not self.pending:
            self.pending_sig = fresh
            if fresh == 0 or self.cfg.day_trend == "off":
                self.pending_day = 0
            else:
                as_of = ctx.forming_open_msc(self.cfg.timeframe)
                if as_of is None:
                    self.pending_day = 0
                else:
                    self.pending_day = d1_trend(
                        ctx.bars("D1"),
                        as_of,
                        self.cfg.day_trend,
                        self.cfg.day_structure_len,
                        self.cfg.day_ema_period,
                    )
        self.pending = True
        self._try_act(ctx)

    def _try_act(self, ctx: Context) -> None:
        if not self.pending or not ctx.session_open():
            return
        self.pending = False
        self._exit_by_bars(ctx)
        sig = self.pending_sig
        pos = ctx.position
        if pos is not None:
            if sig != 0:
                self._bump("signals")
            if self.cfg.exit_on_opposite and sig == -pos.side:
                ctx.close_position("opposite")
                self._bump("exit_opposite")
                pos = ctx.position
                if pos is not None:
                    self._bump("busy")
                    return
            else:
                if sig != 0:
                    self._bump("busy")
                return
        elif sig != 0:
            self._bump("signals")
        if sig == 0:
            return
        if self.cfg.day_trend != "off" and self.pending_day != sig:
            self._bump("day")
            return
        if (self.cfg.trade_side == "long" and sig != 1) or (self.cfg.trade_side == "short" and sig != -1):
            self._bump("side")
            return
        self._enter(ctx, sig)

    def _exit_by_bars(self, ctx: Context) -> None:
        if self.cfg.exit_bars <= 0:
            return
        pos = ctx.position
        if pos is None:
            return
        tf = self.cfg.timeframe
        closed = [bar.time_msc for bar in ctx.bars(tf)]
        age = bar_age(closed, ctx.forming_open_msc(tf), pos.entry_time_msc, TF_MS[tf])
        if age >= self.cfg.exit_bars:
            ctx.close_position("time")
            self._bump("exit_bars")

    def _enter(self, ctx: Context, direction: int) -> None:
        h1 = ctx.bars(self.cfg.timeframe)
        atr = wilder_atr_last(
            [b.high for b in h1], [b.low for b in h1], [b.close for b in h1], self.cfg.atr_period,
        )
        if atr is None or atr <= 0.0:
            self._bump("no_atr")
            return
        tick = ctx.tick()
        entry = tick.ask if direction == 1 else tick.bid
        dist = max(self.cfg.stop_atr_mult * atr, self.cfg.min_sl_points * self.adjusted_point)
        if dist <= 0.0:
            self._bump("no_atr")
            return
        spread = tick.ask - tick.bid
        if self.cfg.max_spread_to_sl > 0.0 and spread > self.cfg.max_spread_to_sl * dist:
            self._bump("spread")
            return
        sl = round_price(entry - direction * dist, self.digits)
        tp = None
        if self.cfg.risk_reward > 0.0:
            tp = round_price(entry + direction * self.cfg.risk_reward * dist, self.digits)
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
            return
        if direction == 1:
            order_id = ctx.buy_market(lot, sl, tp, self.cfg.comment)
        else:
            order_id = ctx.sell_market(lot, sl, tp, self.cfg.comment)
        if order_id is not None:
            self._bump("trades")

    def _signal(self, ctx: Context) -> int:
        h1 = ctx.bars(self.cfg.timeframe)
        if len(h1) < 3:
            return 0
        closes = [b.close for b in h1]
        highs = [b.high for b in h1]
        lows = [b.low for b in h1]
        s1 = self._state_at(ctx, h1, closes, highs, lows, len(h1) - 1)
        s2 = self._state_at(ctx, h1, closes, highs, lows, len(h1) - 2)
        if s1 is None or s2 is None or s1 == 0 or s1 == s2:
            return 0
        return s1

    def _state_at(self, ctx, h1, closes, highs, lows, index: int) -> int | None:
        cfg = self.cfg
        ma = sma_at(closes, index, cfg.ma_period)
        if ma is None:
            return None
        close = closes[index]
        up = close > ma
        down = close < ma
        if cfg.use_hma:
            pair = hma_last_two(closes[: index + 1], cfg.hma_period)
            if pair is None:
                return None
            h0, h1v = pair
            up = up and h0 > h1v
            down = down and h0 < h1v
        if cfg.use_cci:
            cci = cci_at(highs, lows, closes, index, cfg.cci_period)
            if cci is None:
                return None
            up = up and cci > cfg.cci_level
            down = down and cci < -cfg.cci_level
        if cfg.use_htf:
            target = self._htf_index(ctx, h1[index].time_msc)
            if target is None:
                return None
            h4 = ctx.bars(cfg.htf)
            ema = self._htf_ema(h4)
            if ema is None or target >= len(ema):
                return None
            hc = h4[target].close
            level = ema[target]
            up = up and hc > level
            down = down and hc < level
        if up:
            return 1
        if down:
            return -1
        return 0

    def _htf_index(self, ctx: Context, h1_open_msc: int) -> int | None:
        h4 = ctx.bars(self.cfg.htf)
        opens = [bar.time_msc for bar in h4]
        forming = ctx.forming_open_msc(self.cfg.htf)
        if forming is not None:
            opens.append(forming)
        idx = bisect.bisect_right(opens, h1_open_msc) - 1
        if idx < 1:
            return None
        target = idx - 1
        if target >= len(h4):
            return None
        return target

    def _htf_ema(self, h4) -> list[float] | None:
        if len(h4) == self._ema_n and self._ema is not None:
            return self._ema
        self._ema = ema_series([bar.close for bar in h4], self.cfg.htf_ema_period)
        self._ema_n = len(h4)
        return self._ema
