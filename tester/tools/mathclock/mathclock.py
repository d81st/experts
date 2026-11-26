"""H1 золото: «часы» (каждые N свечей) и математические условия входа. Исполнение по M1 (ядро — ../imbfibo/sim.py).

Сигнал — по закрытой H1-свече k; вход по рынку на закрытии k (минута после неё), спред и своп — как в sim.py.
Выходы без трейлинга:  E1 — стоп 1 ATR, тейк 1 ATR;  E2 — стоп 1 ATR, тейк 2 ATR;  E3 — стоп 1 ATR, выход по времени через 6 свечей.
Данные строго до 2026-10-15 (холдаут не загружается).
Запуск:  BARS_M1=... IMBFIBO_WORK=... python3 -I mathclock.py [--year2023]
"""
import sys, os, types, pickle, time, zlib
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'imbfibo'))
import numpy as np, pandas as pd
from multiprocessing import Pool
import sim

SP = sim.SP
EXITS = {'E1': (1.0, 1.0, None), 'E2': (1.0, 2.0, None), 'E3': (1.0, None, 360)}   # (стоп ATR, тейк ATR, удержание в минутах)
HOLD_DEFAULT = sim.HOLD
RUNS, SUBSET = 100, 4000


def load(year2023=False):
    if year2023:
        sim.PERIODS = [('2023', '2023-01-01', '2024-01-01')] + sim.PERIODS
    d = pd.read_csv(sim.BARS, usecols=['time', 'open', 'high', 'low', 'close', 'spread'])
    d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
    d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
    assert d['time'].iloc[-1] < pd.Timestamp('2026-10-16')
    return sim.build_market(d)


def build_h1(M):
    h = pd.to_datetime(M.t).floor('60min').to_numpy()
    chg = np.r_[True, h[1:] != h[:-1]]
    st = np.flatnonzero(chg); en = np.r_[st[1:], M.n]
    H = types.SimpleNamespace(st=st, en=en, n=len(st))
    H.o = M.o[st]; H.c = M.c[en - 1]
    H.h = np.maximum.reduceat(M.h, st); H.l = np.minimum.reduceat(M.l, st); H.cnt = en - st
    pc = np.r_[H.c[0], H.c[:-1]]
    tr = np.maximum(H.h - H.l, np.maximum(abs(H.h - pc), abs(H.l - pc)))
    cs = np.cumsum(np.r_[0, tr]); atr = np.full(H.n, np.nan)
    atr[14:] = (cs[14:H.n] - cs[0:H.n - 14]) / 14.0
    H.atr = atr
    r = np.r_[0.0, np.diff(np.log(H.c))]
    H.r = r
    # z-score доходности последней свечи к предыдущим 100
    z = np.full(H.n, np.nan)
    for k in range(101, H.n):
        w = r[k - 100:k]; s = w.std()
        if s > 0: z[k] = (r[k] - w.mean()) / s
    H.z = z
    # автокорреляция lag-1 по окну 200 (включая k)
    ac = np.full(H.n, np.nan)
    for k in range(201, H.n):
        w = r[k - 199:k + 1]; a, b = w[1:], w[:-1]
        sa, sb = a.std(), b.std()
        if sa > 0 and sb > 0: ac[k] = np.mean((a - a.mean()) * (b - b.mean())) / (sa * sb)
    H.ac = ac
    return H


def make_trades(M, H, sig, ex):
    """sig: список (k, dirn). Возвращает сделки (fi, период, час, dirn, entry, stop, tp, R)."""
    rs_k, rt_k, hold = EXITS[ex]
    old = sim.HOLD; sim.HOLD = hold if hold else HOLD_DEFAULT
    out = []
    for k, dirn in sig:
        i = H.en[k] - 1
        if i + 2 >= M.n or M.period[i] < 0 or not (H.atr[k] > 0): continue
        rs = rs_k * H.atr[k]
        rt = rt_k * H.atr[k] if rt_k else 1e6
        r = sim.run_market(M, i, dirn, rs, rt)
        if r is None: continue
        out.append((i, int(M.period[i]), int(M.hour[i]), dirn, M.c[i], M.c[i] - dirn * rs, M.c[i] + dirn * rt, r))
    sim.HOLD = old
    return out, (hold if hold else HOLD_DEFAULT)


def signals(H):
    full = H.cnt >= 30
    bull = H.c > H.o; bear = H.c < H.o
    ks = np.arange(H.n)
    base = full & (bull | bear) & (ks > 210) & (ks < H.n - 3) & np.isfinite(H.atr)
    fade = np.where(bull, -1, 1)     # против последней свечи
    S = {}
    for N in (1, 3, 6, 12, 24):
        sel = np.flatnonzero(base & (ks % N == 0))
        S[f'clk|fade|N{N}'] = [(int(k), int(fade[k])) for k in sel]
        S[f'clk|follow|N{N}'] = [(int(k), -int(fade[k])) for k in sel]
    for zt in (1.0, 1.5, 2.0):
        sel = np.flatnonzero(base & np.isfinite(H.z) & (np.abs(H.z) >= zt))
        S[f'z|fade|z{zt}'] = [(int(k), int(fade[k])) for k in sel]
        S[f'z|follow|z{zt}'] = [(int(k), -int(fade[k])) for k in sel]
    for th in (0.05, 0.10):
        sel = np.flatnonzero(base & np.isfinite(H.ac) & (np.abs(H.ac) >= th))
        S[f'ac|regime|th{th}'] = [(int(k), int(fade[k]) if H.ac[k] < 0 else -int(fade[k])) for k in sel]
    return S


def kelly(r):
    w, l = r[r > 0], -r[r < 0]
    if len(w) == 0 or len(l) == 0: return np.nan
    p, b = len(w) / len(r), w.mean() / l.mean()
    return p - (1 - p) / b


_G = {}
def work(name):
    hold, tr = _G['S'][name]
    fit = [t for t in tr if sim.PERIODS[t[1]][0] in sim.FIT]
    if len(fit) < 20: return name, np.nan, np.nan, np.nan, None
    rng = np.random.default_rng(zlib.crc32(name.encode()))
    sub = fit if len(fit) <= SUBSET else [fit[i] for i in rng.choice(len(fit), SUBSET, replace=False)]
    sim.HOLD = hold
    m = float(np.mean([t[7] for t in sub]))
    rb = sim.random_baseline(_G['M'], sub, RUNS, rng, _G['POOL'])
    sim.HOLD = HOLD_DEFAULT
    mu, sd = float(rb.mean()), float(rb.std())
    return name, m, mu, sd, (rb - mu) / sd


def main():
    t0 = time.time()
    M = load('--year2023' in sys.argv)
    H = build_h1(M)
    S = signals(H)
    store = {}
    for sname, sig in S.items():
        for ex in EXITS:
            name = f'{sname}|{ex}'
            store[name] = make_trades(M, H, sig, ex)[::-1]  # (hold, trades)
    print(f'тестов: {len(store)}; сделки построены за {time.time()-t0:.0f}с', flush=True)
    rows = []
    for name, (hold, tr) in store.items():
        st = sim.stats(tr)
        fit = np.array([t[7] for t in tr if sim.PERIODS[t[1]][0] in sim.FIT])
        row = dict(test=name, n_fit=len(fit), R_fit=fit.mean() if len(fit) else np.nan,
                   win_fit=(fit > 0).mean() if len(fit) else np.nan, kelly=kelly(fit) if len(fit) else np.nan)
        for p, _, _ in sim.PERIODS:
            n, m, pf, wr = st[p]; row[f'n_{p}'], row[f'R_{p}'] = n, m
        rows.append(row)
    df = pd.DataFrame(rows)
    if '--year2023' not in sys.argv:
        _G['S'], _G['M'], _G['POOL'] = store, M, sim.make_pool(M)
        with Pool(2) as p: res = p.map(work, list(store), chunksize=1)
        rd = pd.DataFrame([dict(test=n, R_sub=m, rand=mu, sd=sd, z=(m - mu) / sd) for n, m, mu, sd, _ in res])
        ok = [r[4] for r in res if r[4] is not None]
        maxz = np.vstack(ok).max(axis=0)
        df = df.merge(rd, on='test')
        df['p_adj'] = [(np.sum(maxz >= z) + 1) / (len(maxz) + 1) if np.isfinite(z) else np.nan for z in df.z]
        df['screen'] = ((df[['n_2024', 'n_2025', 'n_26a']] >= 20).all(axis=1) & (df[['R_2024', 'R_2025', 'R_26a']] > 0).all(axis=1))
        print(f'максимум z случайных входов по {len(ok)} тестам: медиана {np.median(maxz):.2f}, 95-й процентиль {np.quantile(maxz, .95):.2f}')
        df.to_csv(os.path.join(SP, 'mathclock_grid.csv'), index=False)
        pickle.dump({k: v for k, v in store.items()}, open(os.path.join(SP, 'mathclock_trades.pkl'), 'wb'))
    else:
        df.to_csv(os.path.join(SP, 'mathclock_2023.csv'), index=False)
    pd.set_option('display.width', 250, 'display.max_rows', 200, 'display.max_columns', 40)
    print(df.round(3).to_string(index=False))
    print(f'готово за {time.time()-t0:.0f}с')


if __name__ == '__main__':
    main()
