"""H1: имбаланс-свеча + кастомное Фибо (схема пользователя). Симуляция по M1.

Данные: только строго до 2026-10-16 (холдаут не загружается вообще).
Исполнение — по M1-барам Bid; спред платится один раз за сделку (спред бара входа),
проскальзывание стопа SLIP, своп покупки по ночёвкам. Бар, задевший и стоп, и цель — стоп.
В баре входа проверяется только стоп (цель — со следующего бара).
"""
import sys
import types
import numpy as np
import pandas as pd

import os
# рабочая папка для промежуточных файлов (не коммитится) и путь к минуткам
SP = os.environ.get('IMBFIBO_WORK', os.path.join(os.getcwd(), 'work'))
os.makedirs(SP, exist_ok=True)
BARS = os.environ.get('BARS_M1', 'bars_XAUUSDm_M1.csv')
CUTOFF = pd.Timestamp('2026-10-16 00:00')       # исключительно
SWAP = 0.49          # USD / унция за ночь (покупка), среда ×3
SLIP = 0.20          # USD, проскальзывание по стопу
SPR_CAP = 1.5        # USD, предел спреда для расчёта издержек
MIN_RISK = 0.8       # USD, мин. расстояние вход-стоп, иначе сделка пропускается
HOLD = 7200          # минут: 5 суток, потом выход по закрытию
EXPIRY_H = 48        # часов жизни ордеров
A_HI = 6.0           # верхняя граница размера свечи в ATR
BODY = 0.6           # доля тела
PERIODS = [('2024', '2024-01-01', '2025-01-01'), ('2025', '2025-01-01', '2026-01-01'),
           ('26a', '2026-01-01', '2026-06-01'), ('26b', '2026-06-01', '2026-10-16')]
FIT = ['2024', '2025', '26a']

TYPES = {  # имя: (вход x, стоп x, тейк x или 'tp', сторона: 'out' против импульса / 'in' по импульсу)
    'O1': (1.212, 1.272, 'tp', 'out'),
    'O2': (1.618, 1.762, 'tp', 'out'),
    'I1': (0.5, 0.382, 1.0, 'in'),
    'I2': (0.382, 0.236, 1.0, 'in'),
}


def build_market(d):
    t = d['time'].to_numpy()
    M = types.SimpleNamespace()
    M.n = len(d)
    M.o = d['open'].to_numpy(float)
    M.h = d['high'].to_numpy(float)
    M.l = d['low'].to_numpy(float)
    M.c = d['close'].to_numpy(float)
    M.spr = np.minimum(d['spread'].to_numpy(float) * 0.001, SPR_CAP)
    M.t = t
    date = d['time'].dt.normalize().to_numpy()
    dow = d['time'].dt.dayofweek.to_numpy()
    ch = np.zeros(M.n)
    ch[1:] = np.where(date[1:] != date[:-1], np.where(dow[:-1] == 2, 3, 1), 0)
    M.nights = np.cumsum(ch)
    M.hour = d['time'].dt.hour.to_numpy()
    M.period = np.full(M.n, -1)
    for k, (_, a, b) in enumerate(PERIODS):
        M.period[(d['time'] >= a) & (d['time'] < b)] = k
    return M


def manage(M, j0, fill_i, dirn, entry, stop, tp, risk=None):
    """Ведём открытую позицию с бара j0 (entry — фактическая цена входа). Возвращает R."""
    j1 = min(j0 + HOLD, M.n)
    if j0 >= j1:
        return None
    lo, hi = M.l[j0:j1], M.h[j0:j1]
    if dirn > 0:
        sm, tm = lo <= stop, hi >= tp
    else:
        sm, tm = hi >= stop, lo <= tp
    s = int(np.argmax(sm)) if sm.any() else 10 ** 9
    q = int(np.argmax(tm)) if tm.any() else 10 ** 9
    if s <= q and s < 10 ** 9:
        j = j0 + s
        ex = min(stop, M.o[j]) - SLIP if dirn > 0 else max(stop, M.o[j]) + SLIP
    elif q < 10 ** 9:
        j = j0 + q
        ex = max(tp, M.o[j]) if dirn > 0 else min(tp, M.o[j])
    else:
        j = j1 - 1
        ex = M.c[j]
    if risk is None:
        risk = abs(entry - stop)
    swap = SWAP * (M.nights[j] - M.nights[fill_i]) if dirn > 0 else 0.0
    return (dirn * (ex - entry) - M.spr[fill_i] - swap) / risk


def run_limit(M, start, stop_idx, dirn, entry, stop, tp):
    """Лимитка: живёт с бара start до stop_idx (искл.). Возвращает (индекс входа, R) или None.

    Ордер ставится только если на момент постановки (закрытие бара start-1) цена ещё по «правильную»
    сторону уровня входа; иначе зона уже пройдена и ордер пропускается. Если бар открывается за
    уровнем (гэп), вход по цене открытия (лучше лимита), как у настоящей лимитки.
    """
    hi_i = min(stop_idx, M.n)
    if start >= hi_i:
        return None
    if start > 0:
        ref = M.c[start - 1]
        if (dirn > 0 and ref <= entry) or (dirn < 0 and ref >= entry):
            return None
    lo, hi = M.l[start:hi_i], M.h[start:hi_i]
    fm = (lo <= entry) if dirn > 0 else (hi >= entry)
    if not fm.any():
        return None
    fi = start + int(np.argmax(fm))
    fp = min(entry, M.o[fi]) if dirn > 0 else max(entry, M.o[fi])
    risk = abs(entry - stop)
    touched = (M.l[fi] <= stop) if dirn > 0 else (M.h[fi] >= stop)
    if touched:
        ex = min(stop, M.o[fi]) - SLIP if dirn > 0 else max(stop, M.o[fi]) + SLIP
        r = (dirn * (ex - fp) - M.spr[fi]) / risk
        return fi, r
    r = manage(M, fi + 1, fi, dirn, fp, stop, tp, risk)
    return None if r is None else (fi, r)


def run_market(M, i, dirn, rs, rt):
    entry = M.c[i]
    stop = entry - dirn * rs
    tp = entry + dirn * rt
    return manage(M, i + 1, i, dirn, entry, stop, tp, rs)


def build_h1(M):
    h = pd.to_datetime(M.t).floor('h').to_numpy()
    chg = np.r_[True, h[1:] != h[:-1]]
    st = np.flatnonzero(chg)
    en = np.r_[st[1:], M.n]
    H = types.SimpleNamespace()
    H.st, H.en = st, en
    H.t = h[st]
    H.o = M.o[st]
    H.c = M.c[en - 1]
    H.h = np.maximum.reduceat(M.h, st)
    H.l = np.minimum.reduceat(M.l, st)
    H.cnt = en - st
    pc = np.r_[H.c[0], H.c[:-1]]
    tr = np.maximum(H.h - H.l, np.maximum(np.abs(H.h - pc), np.abs(H.l - pc)))
    atr = np.full(len(st), np.nan)
    cs = np.cumsum(np.r_[0, tr])
    for i in range(14, len(st)):
        atr[i] = (cs[i] - cs[i - 14]) / 14.0
    H.atr = atr
    H.n = len(st)
    return H


def find_setups(H, a_lo, gap, W):
    """gap=False: ключевая свеча по размеру/телу, известна после её закрытия.
    gap=True: ещё и настоящий имбаланс (low[k+1] > high[k-1] или зеркально), известен после закрытия k+1.
    W — сколько ещё закрытых свечей ждать после этого момента."""
    out = []
    for k in range(15, H.n - 6):
        R = H.h[k] - H.l[k]
        atr = H.atr[k]
        if not (R > 0 and atr > 0) or H.cnt[k] < 30:
            continue
        x = R / atr
        if x < a_lo or x > A_HI:
            continue
        if abs(H.c[k] - H.o[k]) / R < BODY:
            continue
        bear = H.c[k] < H.o[k]
        base = k
        if gap:
            if H.cnt[k + 1] < 30:
                continue
            if bear and not (H.h[k + 1] < H.l[k - 1]):
                continue
            if (not bear) and not (H.l[k + 1] > H.h[k - 1]):
                continue
            base = k + 1
        a = base + W
        S, E = (H.h[k], H.l[k]) if bear else (H.l[k], H.h[k])
        out.append((H.en[a], S, E))
    out.sort()
    return out


def setup_orders(M, H, setups, typ, xtp):
    """Возвращает список сделок: (индекс входа, период, час, dirn, entry, stop, tp, R)."""
    ex, sx, tx, side = TYPES[typ]
    trades = []
    skipped = 0
    for q, (arm, S, E) in enumerate(setups):
        D = E - S
        P = lambda x: S + x * D
        dirn = int(np.sign(D)) * (1 if side == 'in' else -1)
        entry, stop = P(ex), P(sx)
        tp = P(xtp if tx == 'tp' else tx)
        if abs(entry - stop) < MIN_RISK:
            skipped += 1
            continue
        nxt = setups[q + 1][0] if q + 1 < len(setups) else M.n
        stop_idx = min(arm + EXPIRY_H * 60, nxt)
        r = run_limit(M, arm, stop_idx, dirn, entry, stop, tp)
        if r is None:
            continue
        fi, R = r
        if M.period[fi] < 0:
            continue
        trades.append((fi, int(M.period[fi]), int(M.hour[fi]), dirn, entry, stop, tp, R))
    return trades, skipped


def stats(trades):
    out = {}
    for k, (name, _, _) in enumerate(PERIODS):
        r = np.array([t[7] for t in trades if t[1] == k])
        if len(r) == 0:
            out[name] = (0, np.nan, np.nan, np.nan)
            continue
        w, l = r[r > 0].sum(), -r[r < 0].sum()
        out[name] = (len(r), r.mean(), (w / l) if l > 0 else np.inf, (r > 0).mean())
    return out


def random_baseline(M, trades, runs, rng, idx_pool):
    """Средний R случайных входов: то же направление, расстояние стопа и тейка в USD, период и час."""
    fit = [t for t in trades if PERIODS[t[1]][0] in FIT]
    if not fit:
        return np.array([])
    res = np.empty(runs)
    for u in range(runs):
        rs_ = []
        for (fi, per, hr, dirn, entry, stop, tp, R) in fit:
            pool = idx_pool[(per, hr)]
            i = pool[rng.integers(len(pool))]
            r = run_market(M, i, dirn, abs(entry - stop), abs(tp - entry))
            if r is not None:
                rs_.append(r)
        res[u] = np.mean(rs_)
    return res


def make_pool(M):
    pool = {}
    ok = np.flatnonzero((M.period >= 0) & (np.arange(M.n) < M.n - HOLD - 5))
    for per in range(len(PERIODS)):
        for hr in range(24):
            sel = ok[(M.period[ok] == per) & (M.hour[ok] == hr)]
            if len(sel):
                pool[(per, hr)] = sel
    return pool


# ── самопроверка логики на синтетике ──────────────────────────────────

def selftest():
    def mk(rows, spr=0.0):
        n = len(rows)
        M = types.SimpleNamespace()
        M.n = n
        M.o = np.array([r[0] for r in rows], float)
        M.h = np.array([r[1] for r in rows], float)
        M.l = np.array([r[2] for r in rows], float)
        M.c = np.array([r[3] for r in rows], float)
        M.spr = np.full(n, spr)
        M.nights = np.zeros(n)
        return M
    global SLIP
    old = SLIP
    SLIP = 0.0
    # лонг: вход 100, стоп 99, тейк 103
    M = mk([(101, 101, 100.5, 101), (100.5, 100.6, 99.9, 100.2), (100.2, 101, 99.5, 100.5),
            (100.5, 103.5, 100.4, 103)])
    fi, r = run_limit(M, 0, 4, +1, 100.0, 99.0, 103.0)
    assert fi == 1 and abs(r - 3.0) < 1e-9, (fi, r)
    # лонг: бар входа задел стоп -> -1
    M = mk([(101, 101, 100.5, 101), (100.5, 100.6, 98.9, 99.5), (99.5, 105, 99.4, 104)])
    fi, r = run_limit(M, 0, 3, +1, 100.0, 99.0, 103.0)
    assert fi == 1 and abs(r + 1.0) < 1e-9, (fi, r)
    # лонг: один бар задел и стоп и тейк -> стоп
    M = mk([(101, 101, 100.5, 101), (100.5, 100.6, 99.9, 100.2), (100.2, 103.5, 98.5, 101)])
    fi, r = run_limit(M, 0, 3, +1, 100.0, 99.0, 103.0)
    assert abs(r + 1.0) < 1e-9, r
    # шорт: вход 100, стоп 101, тейк 97
    M = mk([(99, 99.5, 99, 99), (99.5, 100.1, 99.4, 99.8), (99.8, 100.5, 96.5, 97)])
    fi, r = run_limit(M, 0, 3, -1, 100.0, 101.0, 97.0)
    assert fi == 1 and abs(r - 3.0) < 1e-9, (fi, r)
    # шорт: стоп с гэпом -> хуже -1
    M = mk([(99, 99.5, 99, 99), (99.5, 100.1, 99.4, 99.8), (102, 102.5, 101.5, 102)])
    fi, r = run_limit(M, 0, 3, -1, 100.0, 101.0, 97.0)
    assert abs(r + 2.0) < 1e-9, r
    # спред вычитается один раз
    M = mk([(101, 101, 100.5, 101), (100.5, 100.6, 99.9, 100.2), (100.2, 103.5, 100.4, 103)], spr=0.5)
    fi, r = run_limit(M, 0, 3, +1, 100.0, 99.0, 103.0)
    assert abs(r - 2.5) < 1e-9, r
    # ордер не исполняется
    M = mk([(101, 101, 100.5, 101), (101, 102, 100.5, 101)])
    assert run_limit(M, 0, 2, +1, 100.0, 99.0, 103.0) is None
    # зона уже пройдена в момент постановки (закрытие бара start-1 ниже входа лонга) -> пропуск
    M = mk([(99.5, 99.8, 99.0, 99.2), (99.2, 101, 99.1, 100.5), (100.5, 104, 100.2, 103.5)])
    assert run_limit(M, 1, 3, +1, 100.0, 98.0, 103.0) is None
    # гэп вниз через вход, но выше стопа: вход по открытию (лучше лимита)
    M = mk([(101, 101, 100.5, 101), (99.5, 99.8, 99.4, 99.6), (99.6, 103.5, 99.5, 103)])
    fi, r = run_limit(M, 0, 3, +1, 100.0, 99.0, 103.0)
    assert fi == 1 and abs(r - 3.5) < 1e-9, (fi, r)   # вход 99.5, выход 103 -> +3.5 при риске 1
    # гэп вниз через вход И стоп: вход по открытию, сразу стоп, потеря = проскальзывание + спред
    SLIP = 0.2
    M = mk([(101, 101, 100.5, 101), (98.0, 98.2, 97.5, 97.8)], spr=0.1)
    fi, r = run_limit(M, 0, 2, +1, 100.0, 99.0, 103.0)
    assert fi == 1 and abs(r - (-0.3) / 1.0) < 1e-9, (fi, r)
    SLIP = old
    print('selftest OK')


if __name__ == '__main__':
    selftest()
