import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import itertools, pickle
import numpy as np, pandas as pd
import sim
SP = sim.SP
d = pd.read_csv(sim.BARS, usecols=['time','open','high','low','close','spread'])
d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
M = sim.build_market(d); H = sim.build_h1(M)
print('последний бар в данных:', d['time'].iloc[-1])

# сетка: размер свечи {1.5, 2} x режим {без гэпа W0, без гэпа W2, гэп W0, гэп W2} x типы
# O1/O2 — тейк на линии 0.5 (фиксирован заранее); I1/I2 — тейк линия 1 (по твоей схеме)
MODES = [(False,0),(False,2),(True,0),(True,2)]
rows, store = [], {}
for a_lo in (1.5, 2.0):
    for gap, W in MODES:
        setups = sim.find_setups(H, a_lo, gap, W)
        for typ in sim.TYPES:
            trades, skipped = sim.setup_orders(M, H, setups, typ, 0.5)
            name = f'a{a_lo}|{"gap" if gap else "nogap"}|W{W}|{typ}'
            store[name] = trades
            st = sim.stats(trades)
            row = dict(test=name, setups=len(setups))
            for p in ('2024','2025','26a','26b'):
                n,m,pf,wr = st[p]; row[f'n_{p}'],row[f'R_{p}'],row[f'wr_{p}'] = n,m,wr
            fit = np.array([t[7] for t in trades if sim.PERIODS[t[1]][0] in sim.FIT])
            row['n_fit'] = len(fit); row['R_fit'] = fit.mean() if len(fit) else np.nan
            rows.append(row)
df = pd.DataFrame(rows)
df['screen'] = ((df[['n_2024','n_2025','n_26a']] >= 20).all(axis=1) & (df[['R_2024','R_2025','R_26a']] > 0).all(axis=1))
df.to_csv(SP+'/grid2.csv', index=False); pickle.dump(store, open(SP+'/trades2.pkl','wb'))
pd.set_option('display.width',250,'display.max_columns',30,'display.max_rows',100)
print('Всего тестов (число попыток для поправки на перебор):', len(df))
print('Прошли отбор (R>0 во всех трёх периодах подбора, n>=20 в каждом):', int(df['screen'].sum()))
print(df[['test','n_2024','R_2024','n_2025','R_2025','n_26a','R_26a','n_26b','R_26b','R_fit']].round(3).to_string(index=False))
