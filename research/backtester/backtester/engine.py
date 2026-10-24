"""Событийный цикл. Один тик за раз, пачка — только одинаковая миллисекунда.

Порядок на пачке тиков с одним временем:

1. Бары: закрытые бары не содержат тиков этой пачки.
2. Своп за полночи между предыдущим тиком и этой пачкой (только уже открытые).
3. SL/TP позиций, открытых раньше. Отрезок от прошлой цены до всех цен пачки.
   Если достижимы и стоп, и тейк — стоп.
4. По каждому тику пачки: добрать заявки, которым вышел срок задержки;
   отдать стратегии закрытые бары (на первом тике) и on_tick;
   добрать заявки с нулевой задержкой по этой же котировке;
   проверить SL/TP у только что открытых — только по ценам начиная с тика входа,
   без отрезка «до позиции».
5. Просадка по средствам обновляется на каждом тике и не зависит от того,
   какие точки кривой записаны на диск.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .bars import BarBuilder
from .costs import swap_charges
from .protective import limit_hit, resolve_protective, stop_entry_hit
from .session import AlwaysOpen
from .sizing import size_by_risk
from .types import (
    BacktestResult,
    Bar,
    ConfigError,
    Drawdown,
    EquityPoint,
    SymbolSpec,
    Tick,
    Trade,
)


@dataclass
class EngineConfig:
    symbol: SymbolSpec
    deposit: float = 10_000.0
    latency_ms: int = 0
    limit_penetration: float = 0.01
    commission_per_lot_side: float = 0.0
    swap_long_per_lot: float = 0.0
    swap_short_per_lot: float = 0.0
    triple_swap_weekday: int = 2
    # 7 множителей, понедельник = 0. None — прежняя схема triple_swap_weekday.
    swap_multipliers: tuple[float, ...] | None = None
    # exness — 17:00 ET; tester — полночь UTC, как отчёт MT5.
    swap_clock: str = "exness"
    trading_from_msc: int | None = None
    close_at_end: bool = False
    check_margin: bool = True
    sample_tf: str | None = None
    bar_source: str = "ticks"

    def __post_init__(self) -> None:
        if self.deposit <= 0.0:
            raise ConfigError("deposit <= 0")
        if self.latency_ms < 0:
            raise ConfigError("latency_ms < 0")
        if self.limit_penetration < 0.0:
            raise ConfigError("limit_penetration < 0")
        if self.swap_multipliers is not None and len(self.swap_multipliers) != 7:
            raise ConfigError("swap_multipliers: нужно 7 чисел, понедельник = 0")
        if self.swap_clock not in ("exness", "tester"):
            raise ConfigError("swap_clock должен быть exness или tester")


@dataclass
class _Position:
    id: int
    side: int
    volume: float
    entry_time_msc: int
    entry_price: float
    sl: float | None
    tp: float | None
    initial_sl: float | None
    comment: str
    magic: int
    commission_entry: float
    swap: float = 0.0
    last_swap_msc: int = 0
    entry_spread: float = 0.0
    entry_batch_checked: bool = False


@dataclass
class _Order:
    id: int
    kind: str
    volume: float
    price: float
    sl: float | None
    tp: float | None
    activate_msc: int
    expiry_msc: int | None
    comment: str
    magic: int
    penetration: float
    close_pos_id: int | None = None
    close_reason: str = ""


@dataclass
class _View:
    """Позиция, которую видит стратегия. Поля только для чтения."""

    id: int
    side: int
    volume: float
    entry_time_msc: int
    entry_price: float
    sl: float | None
    tp: float | None
    comment: str


class _Context:
    def __init__(self, engine: "Engine"):
        self._engine = engine

    def now_msc(self) -> int:
        return self._engine.tick.time_msc

    def tick(self) -> Tick:
        return self._engine.tick

    def session_open(self) -> bool:
        return self._engine.session.is_open(self._engine.tick.time_msc)

    def bars(self, tf: str) -> list[Bar]:
        return self._engine.bars.closed[tf]

    def forming_open_msc(self, tf: str) -> int | None:
        return self._engine.bars.forming_open(tf)

    @property
    def position(self) -> _View | None:
        if not self._engine.positions:
            return None
        pos = self._engine.positions[0]
        return _View(pos.id, pos.side, pos.volume, pos.entry_time_msc, pos.entry_price, pos.sl, pos.tp, pos.comment)

    @property
    def balance(self) -> float:
        return self._engine.balance

    @property
    def equity(self) -> float:
        return self._engine._equity(self._engine.tick)

    def size_for_risk(
        self, stop_distance: float, risk_percent: float, basis: str = "equity", max_risk_overshoot: float | None = None,
    ) -> float:
        if basis == "equity":
            capital = self.equity
        elif basis == "balance":
            capital = self.balance
        else:
            raise ConfigError("basis должен быть equity или balance")
        spec = self._engine.spec
        overshoot = self._engine.overshoot if max_risk_overshoot is None else max_risk_overshoot
        return size_by_risk(
            capital,
            risk_percent,
            stop_distance,
            tick_size=spec.tick_size,
            tick_value=spec.tick_value,
            volume_min=spec.volume_min,
            volume_max=spec.volume_max,
            volume_step=spec.volume_step,
            max_risk_overshoot=overshoot,
        )

    def buy_market(self, volume, sl, tp, comment=""):
        return self._engine._submit("buy_market", volume, 0.0, sl, tp, None, comment, None)

    def sell_market(self, volume, sl, tp, comment=""):
        return self._engine._submit("sell_market", volume, 0.0, sl, tp, None, comment, None)

    def buy_limit(self, volume, price, sl, tp, expiry_msc=None, comment="", penetration=None):
        return self._engine._submit("buy_limit", volume, price, sl, tp, expiry_msc, comment, penetration)

    def sell_limit(self, volume, price, sl, tp, expiry_msc=None, comment="", penetration=None):
        return self._engine._submit("sell_limit", volume, price, sl, tp, expiry_msc, comment, penetration)

    def buy_stop(self, volume, price, sl, tp, expiry_msc=None, comment=""):
        return self._engine._submit("buy_stop", volume, price, sl, tp, expiry_msc, comment, None)

    def sell_stop(self, volume, price, sl, tp, expiry_msc=None, comment=""):
        return self._engine._submit("sell_stop", volume, price, sl, tp, expiry_msc, comment, None)

    def close_position(self, reason: str = "strategy") -> bool:
        if not self._engine.positions:
            return False
        pos = self._engine.positions[0]
        self._engine._submit_close(pos.id, reason)
        return True


class Engine:
    def __init__(self, config: EngineConfig, strategy, session=None, max_risk_overshoot: float = 1.5):
        self.cfg = config
        self.spec = config.symbol
        self.strategy = strategy
        self.session = session if session is not None else AlwaysOpen()
        self.overshoot = max_risk_overshoot
        tfs = list(strategy.required_timeframes())
        if config.sample_tf and config.sample_tf not in tfs:
            tfs.append(config.sample_tf)
        self.bars = BarBuilder(tfs, source=config.bar_source)
        self.balance = config.deposit
        self.positions: list[_Position] = []
        self.orders: list[_Order] = []
        self.trades: list[Trade] = []
        self.tick: Tick | None = None
        self._prev_bid: float | None = None
        self._prev_ask: float | None = None
        self._prev_time: int | None = None
        self._seq = 1
        self.reject_counts: dict[str, int] = {}
        self.dd = Drawdown(
            balance_peak=config.deposit,
            equity_peak=config.deposit,
            equity_at_trough=config.deposit,
            balance_at_equity_trough=config.deposit,
        )
        self.curve: list[EquityPoint] = [EquityPoint(0, config.deposit, config.deposit, "start")]
        self.ctx = _Context(self)
        self._last_tick: Tick | None = None
        self.tick_count = 0

    def _reject(self, reason: str) -> None:
        self.reject_counts[reason] = self.reject_counts.get(reason, 0) + 1

    def _equity(self, tick: Tick) -> float:
        mpp = self.spec.money_per_price
        floating = 0.0
        for pos in self.positions:
            if pos.side == 1:
                floating += (tick.bid - pos.entry_price) * pos.volume * mpp
            else:
                floating += (pos.entry_price - tick.ask) * pos.volume * mpp
        return self.balance + floating

    def _update_dd(self, tick: Tick, event: str = "") -> None:
        equity = self._equity(tick)
        if self.balance > self.dd.balance_peak:
            self.dd.balance_peak = self.balance
        bal_dd = self.dd.balance_peak - self.balance
        if bal_dd > self.dd.max_balance_dd_money:
            self.dd.max_balance_dd_money = bal_dd
            self.dd.balance_trough_msc = tick.time_msc
        if self.dd.balance_peak > 0.0:
            bal_pct = bal_dd / self.dd.balance_peak * 100.0
            if bal_pct > self.dd.max_balance_dd_pct:
                self.dd.max_balance_dd_pct = bal_pct
        if equity > self.dd.equity_peak:
            self.dd.equity_peak = equity
        eq_dd = self.dd.equity_peak - equity
        if eq_dd > self.dd.max_equity_dd_money:
            self.dd.max_equity_dd_money = eq_dd
            self.dd.equity_trough_msc = tick.time_msc
            self.dd.equity_at_trough = equity
            self.dd.balance_at_equity_trough = self.balance
        if self.dd.equity_peak > 0.0:
            eq_pct = eq_dd / self.dd.equity_peak * 100.0
            if eq_pct > self.dd.max_equity_dd_pct:
                self.dd.max_equity_dd_pct = eq_pct
        if event:
            self.curve.append(EquityPoint(tick.time_msc, self.balance, equity, event))

    def _submit(self, kind, volume, price, sl, tp, expiry, comment, penetration) -> int | None:
        if volume is None or volume <= 0.0:
            self._reject("volume")
            return None
        if kind.endswith("market"):
            price = self.tick.ask if kind.startswith("buy") else self.tick.bid
        elif price is None or price <= 0.0:
            self._reject("price")
            return None
        if sl is not None and sl <= 0.0:
            sl = None
        if tp is not None and tp <= 0.0:
            tp = None
        # 0 в выгрузке — ограничения нет. Ненулевой уровень отсекает слишком близкий SL/TP.
        min_dist = self.spec.stops_level * self.spec.point
        if min_dist > 0.0:
            if sl is not None and abs(price - sl) + 1e-9 < min_dist:
                self._reject("stops_level")
                return None
            if tp is not None and abs(price - tp) + 1e-9 < min_dist:
                self._reject("stops_level")
                return None
        pen = self.cfg.limit_penetration if penetration is None else penetration
        if pen < 0.0:
            raise ConfigError("penetration < 0")
        order = _Order(
            id=self._seq,
            kind=kind,
            volume=volume,
            price=price,
            sl=sl,
            tp=tp,
            activate_msc=self.tick.time_msc + self.cfg.latency_ms,
            expiry_msc=expiry,
            comment=comment,
            magic=0,
            penetration=pen,
        )
        self._seq += 1
        self.orders.append(order)
        if self.cfg.latency_ms == 0:
            self._fill_due(self.tick)
            if kind.endswith("market") and not any(pos.id == order.id for pos in self.positions):
                return None
        return order.id

    def _submit_close(self, pos_id: int, reason: str) -> None:
        order = _Order(
            id=self._seq,
            kind="close",
            volume=0.0,
            price=0.0,
            sl=None,
            tp=None,
            activate_msc=self.tick.time_msc + self.cfg.latency_ms,
            expiry_msc=None,
            comment="",
            magic=0,
            penetration=0.0,
            close_pos_id=pos_id,
            close_reason=reason,
        )
        self._seq += 1
        self.orders.append(order)
        if self.cfg.latency_ms == 0:
            self._fill_due(self.tick)

    def _find(self, pos_id: int) -> _Position | None:
        for pos in self.positions:
            if pos.id == pos_id:
                return pos
        return None

    def _open(self, side: int, order: _Order, price: float, tick: Tick) -> _Position | None:
        spec = self.spec
        if self.cfg.check_margin:
            need = order.volume * spec.contract_size * price / spec.leverage
            used = sum(p.volume * spec.contract_size * p.entry_price / spec.leverage for p in self.positions)
            if need + used > self._equity(tick) + 1e-6:
                self._reject("margin")
                return None
        commission = self.cfg.commission_per_lot_side * order.volume
        self.balance += commission
        pos = _Position(
            id=order.id,
            side=side,
            volume=order.volume,
            entry_time_msc=tick.time_msc,
            entry_price=price,
            sl=order.sl,
            tp=order.tp,
            initial_sl=order.sl,
            comment=order.comment,
            magic=order.magic,
            commission_entry=commission,
            entry_spread=tick.ask - tick.bid,
        )
        self.positions.append(pos)
        self._update_dd(tick, "entry")
        return pos

    def _close(self, pos: _Position, price: float, tick: Tick, reason: str, ambiguous: bool) -> None:
        mpp = self.spec.money_per_price
        gross = (price - pos.entry_price) * pos.side * pos.volume * mpp
        exit_comm = self.cfg.commission_per_lot_side * pos.volume
        self.balance += gross + exit_comm
        net = gross + pos.commission_entry + exit_comm + pos.swap
        risk = None
        r_mult = None
        if pos.initial_sl is not None and pos.initial_sl > 0.0:
            dist = abs(pos.entry_price - pos.initial_sl)
            if dist > 0.0:
                risk = dist * pos.volume * mpp
                r_mult = net / risk
        self.trades.append(
            Trade(
                id=pos.id,
                side=pos.side,
                volume=pos.volume,
                entry_time_msc=pos.entry_time_msc,
                exit_time_msc=tick.time_msc,
                entry_price=pos.entry_price,
                exit_price=price,
                sl=pos.sl,
                tp=pos.tp,
                initial_sl=pos.initial_sl,
                exit_reason=reason,
                gross_pnl=gross,
                commission=pos.commission_entry + exit_comm,
                swap=pos.swap,
                net_pnl=net,
                initial_risk=risk,
                r_multiple=r_mult,
                entry_spread=pos.entry_spread,
                exit_spread=tick.ask - tick.bid,
                comment=pos.comment,
                ambiguous_sl_tp=ambiguous,
                magic=pos.magic,
            )
        )
        self.positions.remove(pos)
        self.orders = [o for o in self.orders if o.close_pos_id != pos.id]
        self._update_dd(tick, reason)

    def _fill_due(self, tick: Tick) -> None:
        kept: list[_Order] = []
        for order in self.orders:
            if order.expiry_msc is not None and tick.time_msc >= order.expiry_msc:
                self._reject("expired")
                continue
            if tick.time_msc < order.activate_msc:
                kept.append(order)
                continue
            if order.close_pos_id is not None:
                pos = self._find(order.close_pos_id)
                if pos is None:
                    continue
                price = tick.bid if pos.side == 1 else tick.ask
                self._close(pos, price, tick, order.close_reason, False)
                continue
            if self._fill_entry(order, tick):
                continue
            kept.append(order)
        self.orders = kept

    def _fill_entry(self, order: _Order, tick: Tick) -> bool:
        kind = order.kind
        if kind == "buy_market":
            self._open(1, order, tick.ask, tick)
            return True
        if kind == "sell_market":
            self._open(-1, order, tick.bid, tick)
            return True
        if kind == "buy_limit":
            if limit_hit(1, tick.ask, order.price, order.penetration):
                self._open(1, order, order.price, tick)
                return True
            return False
        if kind == "sell_limit":
            if limit_hit(-1, tick.bid, order.price, order.penetration):
                self._open(-1, order, order.price, tick)
                return True
            return False
        if kind == "buy_stop":
            if stop_entry_hit(1, tick.ask, order.price):
                fill = tick.ask if tick.ask > order.price else order.price
                self._open(1, order, fill, tick)
                return True
            return False
        if kind == "sell_stop":
            if stop_entry_hit(-1, tick.bid, order.price):
                fill = tick.bid if tick.bid < order.price else order.price
                self._open(-1, order, fill, tick)
                return True
            return False
        self._reject("kind")
        return True

    def _protect(self, positions: list[_Position], prev_bid, prev_ask, ticks: list[Tick]) -> None:
        if not ticks or not positions:
            return
        bids = [t.bid for t in ticks]
        asks = [t.ask for t in ticks]
        for pos in positions:
            if pos.side == 1:
                hit = resolve_protective(1, prev_bid, bids, pos.sl, pos.tp)
            else:
                hit = resolve_protective(-1, prev_ask, asks, pos.sl, pos.tp)
            if hit is None:
                continue
            reason, price, ambiguous = hit
            if pos in self.positions:
                self._close(pos, price, ticks[0], reason, ambiguous)

    def _swaps(self, prev_time: int, now: int, tick: Tick) -> None:
        charged = False
        for pos in self.positions:
            charges = swap_charges(
                prev_time,
                now,
                pos.entry_time_msc,
                pos.last_swap_msc,
                triple_weekday=self.cfg.triple_swap_weekday,
                multipliers=self.cfg.swap_multipliers,
                clock=self.cfg.swap_clock,
            )
            if not charges:
                continue
            rate = self.cfg.swap_long_per_lot if pos.side == 1 else self.cfg.swap_short_per_lot
            for midnight, mult in charges:
                amount = rate * pos.volume * mult
                pos.swap += amount
                self.balance += amount
                pos.last_swap_msc = midnight
                charged = True
        if charged:
            self._update_dd(tick, "swap")

    def _process_batch(self, batch: list[Tick]) -> None:
        closed: list[Bar] = []
        for tick in batch:
            closed.extend(self.bars.add(tick))
        if self._prev_time is not None and self.positions:
            self._swaps(self._prev_time, batch[-1].time_msc, batch[0])
        before = list(self.positions)
        self._protect(before, self._prev_bid, self._prev_ask, batch)
        for i, tick in enumerate(batch):
            self.tick = tick
            self._fill_due(tick)
            if i == 0 and self.strategy is not None:
                for bar in closed:
                    self.strategy.on_bar_close(self.ctx, bar)
            if self.strategy is not None:
                self.strategy.on_tick(self.ctx, tick)
            self._fill_due(tick)
            born = [p for p in self.positions if p.entry_time_msc == tick.time_msc and not p.entry_batch_checked]
            for pos in born:
                pos.entry_batch_checked = True
            self._protect(born, None, None, batch[i:])
            sample = ""
            if i == 0 and self.cfg.sample_tf:
                if any(bar.tf == self.cfg.sample_tf for bar in closed):
                    sample = "bar"
            self._update_dd(tick, sample)
        last = batch[-1]
        self._prev_bid = last.bid
        self._prev_ask = last.ask
        self._prev_time = last.time_msc
        self._last_tick = last

    def run(self, ticks) -> BacktestResult:
        if self.strategy is not None:
            self.strategy.on_start(self.ctx)
        trading_from = self.cfg.trading_from_msc
        batch: list[Tick] = []

        def flush() -> None:
            if batch:
                self._process_batch(batch)
                batch.clear()

        for tick in ticks:
            self.tick_count += 1
            if trading_from is not None and tick.time_msc < trading_from:
                self.bars.add(tick)
                self._prev_bid = tick.bid
                self._prev_ask = tick.ask
                self._prev_time = tick.time_msc
                self._last_tick = tick
                continue
            if batch and tick.time_msc != batch[0].time_msc:
                flush()
            batch.append(tick)
        flush()
        if self.cfg.close_at_end and self._last_tick is not None:
            self.tick = self._last_tick
            for pos in list(self.positions):
                price = self._last_tick.bid if pos.side == 1 else self._last_tick.ask
                self._close(pos, price, self._last_tick, "eod", False)
        if self.dd.equity_trough_msc:
            self.curve.append(
                EquityPoint(
                    self.dd.equity_trough_msc,
                    self.dd.balance_at_equity_trough,
                    self.dd.equity_at_trough,
                    "equity_trough",
                )
            )
        self.curve.sort(key=lambda point: (point.time_msc, point.event))
        counts = {}
        if self.strategy is not None and hasattr(self.strategy, "counts"):
            counts = dict(self.strategy.counts)
        open_positions = []
        if self._last_tick is not None:
            mpp = self.spec.money_per_price
            for pos in self.positions:
                if pos.side == 1:
                    floating = (self._last_tick.bid - pos.entry_price) * pos.volume * mpp
                else:
                    floating = (pos.entry_price - self._last_tick.ask) * pos.volume * mpp
                open_positions.append(
                    {
                        "id": pos.id,
                        "side": pos.side,
                        "volume": pos.volume,
                        "entry_time_msc": pos.entry_time_msc,
                        "entry_price": pos.entry_price,
                        "sl": pos.sl,
                        "tp": pos.tp,
                        "swap": pos.swap,
                        "floating": floating,
                    }
                )
        return BacktestResult(
            trades=self.trades,
            equity_curve=self.curve,
            drawdown=self.dd,
            rejected=[f"{k}:{v}" for k, v in sorted(self.reject_counts.items())],
            open_positions=open_positions,
            last_time_msc=None if self._last_tick is None else self._last_tick.time_msc,
            tick_count=self.tick_count,
            strategy_counts=counts,
        )
