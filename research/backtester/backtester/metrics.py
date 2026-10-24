"""Метрики закрытых сделок. Просадка приходит из движка: она посчитана по тикам.

Просадка по балансу меняется только когда меняется баланс (комиссия, своп,
закрытие). Просадка по средствам включает плавающий результат и на тиках
может быть глубже. Это разные числа, их нельзя подписывать одним словом.
"""

from __future__ import annotations

import math
import random
from typing import Iterable

from .types import Drawdown, Trade


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

    boot = {
        "n": bootstrap,
        "seed": seed,
        "alpha": alpha,
        "method": "percentile",
    }
    if bootstrap > 0 and n > 0:
        rng = random.Random(seed)
        avg_s: list[float] = []
        pfr_s: list[float] = []
        netr_s: list[float] = []
        pfm_s: list[float] = []
        win_s: list[float] = []
        for _ in range(bootstrap):
            sample = [trades[rng.randrange(n)] for _ in range(n)]
            sample_nets = [t.net_pnl for t in sample]
            sample_r = [t.r_multiple for t in sample if t.r_multiple is not None]
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
