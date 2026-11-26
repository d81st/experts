import sys, types, pickle, time, os
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pandas as pd
import sim
SP = sim.SP
d = pd.read_csv(sim.BARS, usecols=['time','open','high','low','close','spread'])
d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
assert d['time'].iloc[-1] < pd.Timestamp('2026-10-16')
M = sim.build_market(d)

def build_tf(M, tfmin):
    h = pd.to_datetime(M.t).floor(f'{tfmin}min').to_numpy()
    chg = np.r_[True, h[1:] != h[:-1]]
    st = np.flatnonzero(chg); en = np.r_[st[1:], M.n]
    H = types.SimpleNamespace(st=st, en=en, n=len(st), tf=tfmin)
    H.o = M.o[st]; H.c = M.c[en-1]
    H.h = np.maximum.reduceat(M.h, st); H.l = np.minimum.reduceat(M.l, st); H.cnt = en - st
    pc = np.r_[H.c[0], H.c[:-1]]
    tr = np.maximum(H.h-H.l, np.maximum(abs(H.h-pc), abs(H.l-pc)))
    cs = np.cumsum(np.r_[0, tr]); atr = np.full(H.n, np.nan)
    atr[14:] = (cs[14:H.n] - cs[0:H.n-14]) / 14.0
    H.atr = atr
    return H

def setups_tf(H, a_lo, W):
    out = []; need = 0.5 * H.tf
    for k in range(15, H.n - 6):
        R = H.h[k]-H.l[k]; atr = H.atr[k]
        if not (R > 0 and atr > 0) or H.cnt[k] < need or H.cnt[k+1] < need: continue
        x = R/atr
        if x < a_lo or x > sim.A_HI: continue
        if abs(H.c[k]-H.o[k])/R < sim.BODY: continue
        bear = H.c[k] < H.o[k]
        if bear and not (H.h[k+1] < H.l[k-1]): continue
        if (not bear) and not (H.l[k+1] > H.h[k-1]): continue
        S, E = (H.h[k], H.l[k]) if bear else (H.l[k], H.h[k])
        out.append((H.en[k+1+W], S, E, atr))
    out.sort(key=lambda z: z[0]); return out

def orders(M, setups, typ, stop_mode, exit_mode):
    """stop_mode: 'tbl' (по таблице пользователя) или ('atr', k); exit_mode: 'tbl' или ('rr', x)."""
    ex, sx, tx, side = sim.TYPES[typ]
    trades, skipped = [], 0
    for q, (arm, S, E, atr) in enumerate(setups):
        D = E - S
        dirn = int(np.sign(D)) * (1 if side == 'in' else -1)
        entry = S + ex*D
        stop = S + sx*D if stop_mode == 'tbl' else entry - dirn * stop_mode[1] * atr
        risk = abs(entry - stop)
        if risk < sim.MIN_RISK: skipped += 1; continue
        if exit_mode == 'tbl':
            tp = S + (0.5 if tx == 'tp' else tx) * D
        else:
            tp = entry + dirn * exit_mode[1] * risk
        if (dirn > 0 and tp <= entry) or (dirn < 0 and tp >= entry): skipped += 1; continue
        nxt = setups[q+1][0] if q+1 < len(setups) else M.n
        r = sim.run_limit(M, arm, min(arm + sim.EXPIRY_H*60, nxt), dirn, entry, stop, tp)
        if r is None: continue
        fi, R = r
        if M.period[fi] < 0: continue
        trades.append((fi, int(M.period[fi]), int(M.hour[fi]), dirn, entry, stop, tp, R))
    return trades, skipped

store, meta = {}, []
t0 = time.time()
# Вариант 1: широкий стоп (1 / 1.5 ATR), тейк RR 1 / 2; M30, H1; свеча >= 2 ATR
for tf in (30, 60):
    H = build_tf(M, tf)
    for W in (0, 2):
        su = setups_tf(H, 2.0, W)
        for typ in sim.TYPES:
            for k in (1.0, 1.5):
                for rr in (1.0, 2.0):
                    name = f'V1|M{tf}|W{W}|{typ}|stop{k}ATR|RR{rr:g}'
                    tr, sk = orders(M, su, typ, ('atr', k), ('rr', rr))
                    store[name] = tr; meta.append((name, len(su), sk))
# Вариант 2: старшие ТФ, стопы/тейки по таблице и RR 1:1
for tf in (240, 1440):
    H = build_tf(M, tf)
    for a_lo in (1.5, 2.0):
        for W in (0, 2):
            su = setups_tf(H, a_lo, W)
            for typ in sim.TYPES:
                for em in ('tbl', ('rr', 1.0)):
                    name = f'V2|{"H4" if tf==240 else "D1"}|a{a_lo}|W{W}|{typ}|' + ('tbl' if em=='tbl' else 'RR1')
                    tr, sk = orders(M, su, typ, 'tbl', em)
                    store[name] = tr; meta.append((name, len(su), sk))
print(f'Новых тестов: {len(store)}  ({time.time()-t0:.0f}с)', flush=True)

rows = []
for (name, nsu, sk) in meta:
    tr = store[name]; st = sim.stats(tr)
    row = dict(test=name, setups=nsu, skipped=sk)
    for p in ('2024','2025','26a','26b'):
        n, m, pf, wr = st[p]; row[f'n_{p}'], row[f'R_{p}'], row[f'wr_{p}'] = n, m, wr
    fit = np.array([x[7] for x in tr if sim.PERIODS[x[1]][0] in sim.FIT])
    row['n_fit'] = len(fit); row['R_fit'] = fit.mean() if len(fit) else np.nan
    rows.append(row)
df = pd.DataFrame(rows)
df['screen'] = ((df[['n_2024','n_2025','n_26a']] >= 20).all(axis=1) & (df[['R_2024','R_2025','R_26a']] > 0).all(axis=1))
df.to_csv(SP+'/grid_v12.csv', index=False)
pickle.dump(store, open(SP+'/trades_v12.pkl','wb'))
print('Прошли отбор (R>0 во всех трёх периодах, n>=20 в каждом):', int(df.screen.sum()), 'из', len(df), flush=True)
