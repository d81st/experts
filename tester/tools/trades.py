"""Сделки из HTML-отчёта тестера MT5: пары вход → выход по позиции.

Использование как модуль:
    from trades import load_trades
    tr = load_trades("report.htm")   # список dict

Поля сделки:
    open_time, close_time (datetime), dir (+1 покупка, -1 продажа), volume,
    open_price, close_price, profit (итог с комиссией и свопом, валюта счёта),
    balance (баланс перед входом), ret (profit / balance), exit ("sl", "tp", "" — по рынку),
    comment (комментарий входа).
"""
import datetime as dt
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_report import load, rows, num  # noqa: E402

CONTRACT = 100.0  # унций в лоте XAUUSD(m): 1 USD хода цены × 0.01 лота = 1 USD


def _time(s):
    return dt.datetime.strptime(s, "%Y.%m.%d %H:%M:%S")


def load_trades(path):
    table = list(rows(load(path)))
    head = [i for i, r in enumerate(table) if r and r[0] in ("Time", "Время") and len(r) == 13]
    if not head:
        return []
    h = table[head[-1]]
    deals = [r for r in table[head[-1] + 1:] if len(r) == len(h)]
    # Колонки: Time, Deal, Symbol, Type, Direction, Volume, Price, Order, Commission, Swap, Profit, Balance, Comment
    trades, open_ = [], []
    balance = None
    for d in deals:
        kind = d[4]
        if d[11]:
            try:
                bal_after = num(d[11])
            except ValueError:
                bal_after = None
        else:
            bal_after = None
        if kind in ("in", "вход"):
            open_.append({
                "open_time": _time(d[0]),
                "dir": 1 if d[3] in ("buy", "покупка") else -1,
                "volume": num(d[5]),
                "open_price": num(d[6]),
                "comm_in": num(d[8]) if d[8] else 0.0,
                "balance": balance,
                "comment": d[12],
            })
        elif kind in ("out", "выход", "in/out") and open_:
            vol = num(d[5])
            o = open_.pop(0)
            if abs(vol - o["volume"]) > 1e-9 and vol < o["volume"]:
                # частичное закрытие: остаток позиции возвращаем в очередь
                rest = dict(o)
                rest["volume"] = o["volume"] - vol
                rest["comm_in"] = 0.0
                open_.insert(0, rest)
            profit = num(d[10]) + (num(d[9]) if d[9] else 0.0) + (num(d[8]) if d[8] else 0.0) + o["comm_in"]
            c = d[12].lower()
            bal = o["balance"] if o["balance"] else (bal_after - profit if bal_after else None)
            trades.append({
                "open_time": o["open_time"], "close_time": _time(d[0]), "dir": o["dir"], "volume": vol,
                "open_price": o["open_price"], "close_price": num(d[6]), "profit": profit,
                "balance": bal, "ret": profit / bal if bal else 0.0,
                "exit": "sl" if c.startswith("sl") else ("tp" if c.startswith("tp") else ""),
                "comment": o["comment"],
            })
        if bal_after is not None:
            balance = bal_after
    return trades


if __name__ == "__main__":
    for p in sys.argv[1:]:
        tr = load_trades(p)
        gp = sum(t["profit"] for t in tr if t["profit"] > 0)
        gl = -sum(t["profit"] for t in tr if t["profit"] < 0)
        print(f"{os.path.basename(p)}: {len(tr)} сделок, PF {gp / gl if gl else float('inf'):.2f}, "
              f"итог {gp - gl:.0f}")
