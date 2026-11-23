"""Метрики закрытых сделок. Просадка приходит из движка: она посчитана по тикам.

Просадка по балансу меняется только когда меняется баланс (комиссия, своп,
закрытие). Просадка по средствам включает плавающий результат и на тиках
может быть глубже. Это разные числа, их нельзя подписывать одним словом.
"""

from __future__ import annotations

import math
import random
from typing import Iterable

from .types import Drawdown, EquityPoint, Trade


def _pf(values: list[float]) -> float | None:
    gross_profit = sum(v for v in values if v > 0.0)
    gross_loss = -sum(v for v in values if v < 0.0)
    if gross_loss > 0.0:
        return gross_profit / gross_loss
    if gross_profit > 0.0:
        return math.inf
    if not values:
        return None
    return 0.0


def _percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * p
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return ordered[int(rank)]
    weight = rank - lo
    return ordered[lo] * (1.0 - weight) + ordered[hi] * weight


def _json_num(value: float | None) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return None
    return float(value)


def longest_losing_streak(trades: Iterable[Trade]) -> int:
    best = 0
    current = 0
    for trade in sorted(trades, key=lambda item: (item.exit_time_msc, item.id)):
        if trade.net_pnl < 0.0:
            current += 1
            best = max(best, current)
        else:
            current = 0
    return best


def _ci(samples: list[float], alpha: float) -> tuple[float | None, float | None]:
    if not samples:
        return None, None
    return _percentile(samples, alpha / 2.0), _percentile(samples, 1.0 - alpha / 2.0)


def compute_metrics(
    trades: list[Trade],
    drawdown: Drawdown,
    *,
    deposit: float,
    bootstrap: int = 2000,
    seed: int = 1,
    alpha: float = 0.05,
) -> dict:
    nets = [t.net_pnl for t in trades]
    rs = [t.r_multiple for t in trades if t.r_multiple is not None]
    n = len(trades)
    wins = sum(1 for value in nets if value > 0.0)
    gross_profit = sum(v for v in nets if v > 0.0)
    gross_loss = -sum(v for v in nets if v < 0.0)
    pf_money = _pf(nets)
    pf_r = _pf(rs) if rs else None
    avg_r = sum(rs) / len(rs) if rs else None
    net_r = sum(rs) if rs else None
    avg_net = sum(nets) / n if n else None

    boot = {
        "n": bootstrap,
        "seed": seed,
        "alpha": alpha,
        "method": "percentile",
    }
    if bootstrap > 0 and n > 0:
        rng = random.Random(seed)
        avg_s: list[float] = []
        avg_net_s: list[float] = []
        pfr_s: list[float] = []
        netr_s: list[float] = []
        pfm_s: list[float] = []
        win_s: list[float] = []
        for _ in range(bootstrap):
            sample = [trades[rng.randrange(n)] for _ in range(n)]
            sample_nets = [t.net_pnl for t in sample]
            sample_r = [t.r_multiple for t in sample if t.r_multiple is not None]
            avg_net_s.append(sum(sample_nets) / n)
            if sample_r:
                avg_s.append(sum(sample_r) / len(sample_r))
                netr_s.append(sum(sample_r))
                pfr = _pf(sample_r)
                if pfr is not None:
                    pfr_s.append(pfr)
            pfm = _pf(sample_nets)
            if pfm is not None:
                pfm_s.append(pfm)
            win_s.append(sum(1 for v in sample_nets if v > 0.0) / n)
        boot["avg_r_ci"] = _ci(avg_s, alpha)
        boot["avg_net_ci"] = _ci(avg_net_s, alpha)
        boot["net_r_ci"] = _ci(netr_s, alpha)
        boot["profit_factor_r_ci"] = _ci(pfr_s, alpha)
        boot["profit_factor_money_ci"] = _ci(pfm_s, alpha)
        boot["win_rate_ci"] = _ci(win_s, alpha)

    def pack_ci(pair: tuple[float | None, float | None] | None) -> dict:
        if pair is None:
            return {"low": None, "high": None}
        low, high = pair
        return {
            "low": _json_num(low),
            "high": _json_num(high),
            "low_infinite": bool(low is not None and math.isinf(low)),
            "high_infinite": bool(high is not None and math.isinf(high)),
        }

    return {
        "trades": n,
        "wins": wins,
        "win_rate": (wins / n) if n else None,
        "net_money": sum(nets) if n else 0.0,
        "gross_profit_money": gross_profit,
        "gross_loss_money": gross_loss,
        "profit_factor_money": _json_num(pf_money),
        "profit_factor_money_infinite": bool(pf_money is not None and math.isinf(pf_money)),
        "avg_net_money": avg_net,
        "avg_r": avg_r,
        "net_r": net_r,
        "profit_factor_r": _json_num(pf_r),
        "profit_factor_r_infinite": bool(pf_r is not None and math.isinf(pf_r)),
        "r_undefined": n - len(rs),
        "longest_losing_streak": longest_losing_streak(trades),
        "deposit": deposit,
        "max_drawdown_balance_money": drawdown.max_balance_dd_money,
        "max_drawdown_balance_pct": drawdown.max_balance_dd_pct,
        "max_drawdown_equity_money": drawdown.max_equity_dd_money,
        "max_drawdown_equity_pct": drawdown.max_equity_dd_pct,
        "drawdown_labels": {
            "max_drawdown_balance_money": "просадка по балансу, деньги от пика баланса",
            "max_drawdown_balance_pct": "просадка по балансу, % от пика баланса",
            "max_drawdown_equity_money": "просадка по средствам, деньги от пика equity, по каждому тику",
            "max_drawdown_equity_pct": "просадка по средствам, % от пика equity, по каждому тику",
        },
        "bootstrap": {
            **{k: v for k, v in boot.items() if not k.endswith("_ci")},
            "avg_net_ci95": pack_ci(boot.get("avg_net_ci")),
            "avg_r_ci95": pack_ci(boot.get("avg_r_ci")),
            "net_r_ci95": pack_ci(boot.get("net_r_ci")),
            "profit_factor_r_ci95": pack_ci(boot.get("profit_factor_r_ci")),
            "profit_factor_money_ci95": pack_ci(boot.get("profit_factor_money_ci")),
            "win_rate_ci95": pack_ci(boot.get("win_rate_ci")),
        },
    }


def format_metrics_ru(metrics: dict) -> str:
    b = metrics["bootstrap"]

    def ci(name: str) -> str:
        block = b.get(name) or {}
        low = block.get("low")
        high = block.get("high")
        if block.get("low_infinite"):
            low = "inf"
        if block.get("high_infinite"):
            high = "inf"
        if low is None and high is None:
            return "—"
        return f"[{low}, {high}]"

    pf_r = "inf" if metrics.get("profit_factor_r_infinite") else metrics.get("profit_factor_r")
    pf_m = "inf" if metrics.get("profit_factor_money_infinite") else metrics.get("profit_factor_money")
    lines = [
        f"Сделок: {metrics['trades']}",
        f"Чистыми, деньги: {metrics['net_money']:.2f}",
        f"Профит-фактор, деньги: {pf_m}",
        f"Профит-фактор, R: {pf_r}   95% ДИ {ci('profit_factor_r_ci95')}",
        f"Винрейт: {metrics['win_rate']}",
        f"Средняя сделка, деньги: {metrics.get('avg_net_money')}   95% ДИ {ci('avg_net_ci95')}",
        f"Средний R: {metrics['avg_r']}   95% ДИ {ci('avg_r_ci95')}",
        f"Сумма R: {metrics['net_r']}   95% ДИ {ci('net_r_ci95')}",
        f"Просадка по балансу: {metrics['max_drawdown_balance_money']:.2f} "
        f"({metrics['max_drawdown_balance_pct']:.2f}% от пика баланса)",
        f"Просадка по средствам: {metrics['max_drawdown_equity_money']:.2f} "
        f"({metrics['max_drawdown_equity_pct']:.2f}% от пика equity), по тикам",
        f"Самая длинная серия убытков: {metrics['longest_losing_streak']}",
        f"Сделок без R (нет стопа): {metrics['r_undefined']}",
        f"Бутстрэп: {b.get('n')} выборок, seed {b.get('seed')}, метод percentile",
    ]
    return "\n".join(lines) + "\n"


def _window_drawdown(points: list[EquityPoint], start_msc: int, end_msc: int, deposit: float) -> Drawdown:
    """Просадка внутри окна по записанной кривой, не по каждому тику.

    Пик считается заново от баланса и средств на входе в окно.
    """
    prior = [point for point in points if 0 < point.time_msc < start_msc]
    start_bal = prior[-1].balance if prior else deposit
    start_eq = prior[-1].equity if prior else deposit
    dd = Drawdown(
        balance_peak=start_bal,
        equity_peak=start_eq,
        equity_at_trough=start_eq,
        balance_at_equity_trough=start_bal,
    )
    seq = [EquityPoint(start_msc, start_bal, start_eq, "open")]
    seq.extend(point for point in points if start_msc <= point.time_msc < end_msc)
    for point in seq:
        if point.balance > dd.balance_peak:
            dd.balance_peak = point.balance
        bal_dd = dd.balance_peak - point.balance
        if bal_dd > dd.max_balance_dd_money:
            dd.max_balance_dd_money = bal_dd
            dd.balance_trough_msc = point.time_msc
        if dd.balance_peak > 0.0:
            bal_pct = bal_dd / dd.balance_peak * 100.0
            if bal_pct > dd.max_balance_dd_pct:
                dd.max_balance_dd_pct = bal_pct
        if point.equity > dd.equity_peak:
            dd.equity_peak = point.equity
        eq_dd = dd.equity_peak - point.equity
        if eq_dd > dd.max_equity_dd_money:
            dd.max_equity_dd_money = eq_dd
            dd.equity_trough_msc = point.time_msc
            dd.equity_at_trough = point.equity
            dd.balance_at_equity_trough = point.balance
        if dd.equity_peak > 0.0:
            eq_pct = eq_dd / dd.equity_peak * 100.0
            if eq_pct > dd.max_equity_dd_pct:
                dd.max_equity_dd_pct = eq_pct
    return dd


def _period_bounds(year: int, quarter: int | None) -> tuple[int, int, str]:
    from datetime import datetime, timezone

    if quarter is None:
        start = datetime(year, 1, 1, tzinfo=timezone.utc)
        end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
        label = str(year)
    else:
        month = (quarter - 1) * 3 + 1
        start = datetime(year, month, 1, tzinfo=timezone.utc)
        if quarter == 4:
            end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
        else:
            end = datetime(year, month + 3, 1, tzinfo=timezone.utc)
        label = f"{year}-Q{quarter}"
    return int(start.timestamp() * 1000), int(end.timestamp() * 1000), label


def period_metrics(
    trades: list[Trade],
    points: list[EquityPoint],
    *,
    deposit: float,
    years: list[int],
    bootstrap: int = 2000,
    seed: int = 1,
) -> list[dict]:
    """Год и квартал по времени выхода. Просадка окна — по записанной кривой."""
    rows = []
    for year in years:
        slots: list[tuple[int, int, str]] = [_period_bounds(year, None)]
        slots.extend(_period_bounds(year, quarter) for quarter in (1, 2, 3, 4))
        for start, end, label in slots:
            chosen = [trade for trade in trades if start <= trade.exit_time_msc < end]
            dd = _window_drawdown(points, start, end, deposit)
            metrics = compute_metrics(chosen, dd, deposit=deposit, bootstrap=bootstrap, seed=seed)
            rs = [trade.r_multiple for trade in chosen if trade.r_multiple is not None]
            metrics["label"] = label
            metrics["start_msc"] = start
            metrics["end_msc"] = end
            metrics["drawdown_resolution"] = "sampled_curve"
            metrics["median_r"] = _percentile(rs, 0.5)
            rows.append(metrics)
    return rows
