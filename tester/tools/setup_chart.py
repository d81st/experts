"""Картинка сетапа для разбора: H1 за 3 дня и M15 за 16 часов до входа (плюс 4 часа после),
с линиями входа, стопа и заданными уровнями, а также максимумом/минимумом прошлого дня и Азии.

Использование:
    python3 tester/tools/setup_chart.py --bars bars.csv --setups setups.csv --out папка
    setups.csv: id,time,dir,entry,sl,lines   (lines — цены через ';', можно пусто)
"""
import argparse
import os

import pandas as pd
from PIL import Image, ImageDraw, ImageFont

W, H, PAD = 1100, 520, 60
FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"   # шрифт с кириллицей
FONT = ImageFont.truetype(FONT_PATH, 11) if os.path.exists(FONT_PATH) else ImageFont.load_default()


def load(path):
    d = pd.read_csv(path)
    d["time"] = pd.to_datetime(d["time"], format="%Y.%m.%d %H:%M")
    return d.set_index("time")[["open", "high", "low", "close"]]


def ohlc(m, rule):
    r = m.resample(rule, label="left", closed="left")
    return pd.DataFrame({"open": r["open"].first(), "high": r["high"].max(), "low": r["low"].min(),
                         "close": r["close"].last()}).dropna()


def panel(img, top, bars, T, title, hlines):
    dr = ImageDraw.Draw(img)
    lo = min(bars["low"].min(), *(p for p, *_ in hlines)) - 1
    hi = max(bars["high"].max(), *(p for p, *_ in hlines)) + 1
    y = lambda p: top + PAD / 2 + (hi - p) / (hi - lo) * (H - PAD)
    n = len(bars)
    cw = (W - 2 * PAD) / max(n, 1)
    x = lambda i: PAD + (i + 0.5) * cw
    dr.text((PAD, top + 5), title, fill="black", font=FONT)
    for p, color, label in hlines:
        dr.line([(PAD, y(p)), (W - PAD, y(p))], fill=color, width=1)
        dr.text((W - PAD + 3, y(p) - 6), f"{p:.2f} {label}", fill=color, font=FONT)
    for i, (t, b) in enumerate(bars.iterrows()):
        col = (0, 120, 70) if b.close >= b.open else (200, 40, 40)
        dr.line([(x(i), y(b.high)), (x(i), y(b.low))], fill=col)
        y0, y1 = sorted((y(b.open), y(b.close)))
        dr.rectangle([x(i) - cw * 0.35, y0, x(i) + cw * 0.35, max(y1, y0 + 1)], fill=col)
        if t <= T < t + (bars.index[1] - bars.index[0]):
            dr.line([(x(i), top + 20), (x(i), top + H - 10)], fill=(120, 120, 120))
    for i in range(0, n, max(1, n // 8)):
        dr.text((x(i) - 20, top + H - 12), f"{bars.index[i]:%d.%m %H:%M}", fill="gray", font=FONT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", required=True)
    ap.add_argument("--setups", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    m1 = load(args.bars)
    os.makedirs(args.out, exist_ok=True)
    for _, s in pd.read_csv(args.setups, dtype={"lines": str}).iterrows():
        T = pd.Timestamp(s.time)
        past = m1[m1.index < T]
        day0 = T.normalize()
        D1 = ohlc(past, "1D")
        prev = D1[D1.index < day0].iloc[-1]
        asia = past[(past.index >= day0) & (past.index < day0 + pd.Timedelta(hours=7))]
        hl = [(float(s.entry), (0, 0, 255) if s.dir == "buy" else (200, 0, 0), "вход"),
              (float(s.sl), (255, 120, 0), "стоп"),
              (prev.high, (120, 0, 160), "макс. вчера"), (prev.low, (120, 0, 160), "мин. вчера")]
        if len(asia):
            hl += [(asia.high.max(), (0, 140, 140), "макс. Азии"), (asia.low.min(), (0, 140, 140), "мин. Азии")]
        if isinstance(s.lines, str) and s.lines.strip():
            hl += [(float(p), (255, 0, 0), "его линия") for p in s.lines.split(";")]
        img = Image.new("RGB", (W + 150, 2 * H + 20), "white")
        h1 = ohlc(m1[(m1.index >= T - pd.Timedelta(hours=72)) & (m1.index < T + pd.Timedelta(hours=4))], "60min")
        m15 = ohlc(m1[(m1.index >= T - pd.Timedelta(hours=16)) & (m1.index < T + pd.Timedelta(hours=4))], "15min")
        near = [h for h in hl if abs(h[0] - float(s.entry)) < 60]
        panel(img, 0, h1, T, f"{s.id}  H1, 3 дня до входа и 4 часа после", near)
        panel(img, H + 20, m15, T, f"{s.id}  M15, 16 часов до входа и 4 часа после", near)
        img.save(os.path.join(args.out, f"{s.id.split()[0]}.png"))
        print("ok", s.id)


if __name__ == "__main__":
    main()
