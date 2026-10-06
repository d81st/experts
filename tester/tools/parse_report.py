"""Сводка по HTML-отчёту тестера MT5.

Использование:
    python3 tester/tools/parse_report.py <report.htm>

Отчёт MT5 сохраняется в UTF-16; скрипт сам определяет кодировку.
Печатает блок Results и разбивку закрытых сделок по исходам
(стоп-лосс / безубыток / тейк-профит).
"""
import html
import re
import sys


def load(path):
    raw = open(path, "rb").read()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    return raw.decode(enc).replace("\r", "")


def rows(text):
    for r in re.findall(r"<tr[^>]*>(.*?)</tr>", text, re.S):
        cells = re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S)
        yield [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in cells]


def num(s):
    return float(s.replace(" ", "") or 0)


def main(path):
    table = list(rows(load(path)))

    in_results = False
    for r in table:
        cells = [c for c in r if c]
        if not cells:
            continue
        if cells[0] in ("Results", "Результаты"):
            in_results = True
            continue
        if in_results and cells[0] in ("Orders", "Ордера"):
            break
        if in_results:
            print(" | ".join(cells))

    head = [i for i, r in enumerate(table) if r and r[0] in ("Time", "Время") and len(r) == 13]
    if not head:
        return
    h = table[head[-1]]
    deals = [r for r in table[head[-1] + 1:] if len(r) == len(h)]
    i_dir, i_profit = 4, 10
    outs = [num(d[i_profit]) for d in deals if d[i_dir] in ("out", "выход")]
    losses = [p for p in outs if p < 0]
    breakeven = [p for p in outs if 0 <= p < 0.5]
    other = [p for p in outs if p >= 0.5]
    # PF и итог по годам — для проверки стабильности на длинной истории
    by_year = {}
    for d in deals:
        if d[i_dir] not in ("out", "выход") or not d[i_profit]:
            continue
        y = d[0][:4]
        w = by_year.setdefault(y, [0.0, 0.0, 0])
        p = num(d[i_profit])
        if p >= 0: w[0] += p
        else:      w[1] -= p
        w[2] += 1
    if len(by_year) > 1:
        print()
        print("По годам:")
        for y in sorted(by_year):
            gp, gl, n = by_year[y]
            pf = gp / gl if gl > 0 else float("inf")
            print(f"  {y}: сделок {n:4d}  PF {pf:5.2f}  итог {gp - gl:10.2f}")

    print()
    print(f"Закрытых сделок: {len(outs)}")
    print(f"  убыточные:            {len(losses):5d}  {sum(losses):10.2f}")
    print(f"  безубыток (0..0.5$):  {len(breakeven):5d}  {sum(breakeven):10.2f}")
    print(f"  прибыльные (>=0.5$):  {len(other):5d}  {sum(other):10.2f}")


if __name__ == "__main__":
    main(sys.argv[1])
