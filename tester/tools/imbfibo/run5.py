import sys, types, pickle, time
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pandas as pd
import sim
SP = sim.SP
d = pd.read_csv(sim.BARS, usecols=['time','open','high','low','close','spread'])
d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
M = sim.build_market(d)
assert d['time'].iloc[-1] < pd.Timestamp('2026-10-16')

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
    """Настоящий имбаланс (FVG по трём свечам), известен после закрытия свечи k+1; затем ждём W свечей."""
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
        out.append((H.en[k+1+W], S, E))
    out.sort(); return out

def orders_rr(M, setups, typ, rr):
    ex, sx, _, side = sim.TYPES[typ]
    trades, skipped = [], 0
    for q, (arm, S, E) in enumerate(setups):
        D = E - S
        dirn = int(np.sign(D)) * (1 if side == 'in' else -1)
        entry, stop = S + ex*D, S + sx*D
        risk = abs(entry - stop)
        if risk < sim.MIN_RISK: skipped += 1; continue
        tp = entry + dirn * rr * risk
        nxt = setups[q+1][0] if q+1 < len(setups) else M.n
        r = sim.run_limit(M, arm, min(arm + sim.EXPIRY_H*60, nxt), dirn, entry, stop, tp)
        if r is None: continue
        fi, R = r
        if M.period[fi] < 0: continue
        trades.append((fi, int(M.period[fi]), int(M.hour[fi]), dirn, entry, stop, tp, R))
    return trades, skipped

RR = 1.0
rows, store = [], {}
t0 = time.time()
for tf in (5, 15, 30, 60):
    H = build_tf(M, tf)
    for a_lo in (1.5, 2.0):
        for W in (0, 2):
            setups = setups_tf(H, a_lo, W)
            for typ in sim.TYPES:
                trades, sk = orders_rr(M, setups, typ, RR)
                name = f'M{tf}|a{a_lo}|W{W}|{typ}'
                store[name] = trades
                st = sim.stats(trades)
                row = dict(test=name, setups=len(setups), skipped=sk)
                for p in ('2024','2025','26a','26b'):
                    n, m, pf, wr = st[p]; row[f'n_{p}'], row[f'R_{p}'], row[f'wr_{p}'] = n, m, wr
                fit = np.array([x[7] for x in trades if sim.PERIODS[x[1]][0] in sim.FIT])
                row['n_fit'] = len(fit); row['R_fit'] = fit.mean() if len(fit) else np.nan
                row['wr_fit'] = (fit > 0).mean() if len(fit) else np.nan
                rows.append(row)
df = pd.DataFrame(rows)
df['screen'] = ((df[['n_2024','n_2025','n_26a']] >= 20).all(axis=1) & (df[['R_2024','R_2025','R_26a']] > 0).all(axis=1))
df.to_csv(SP+'/grid_rr1.csv', index=False); pickle.dump(store, open(SP+'/trades_rr1.pkl','wb'))
pd.set_option('display.width',250,'display.max_rows',200,'display.max_columns',30)
print(f'Тестов: {len(df)} (время {time.time()-t0:.0f}с). Прошли отбор: {int(df.screen.sum())}')
print(df[['test','setups','skipped','n_fit','R_fit','wr_fit','R_2024','R_2025','R_26a','R_26b']].round(3).to_string(index=False))
