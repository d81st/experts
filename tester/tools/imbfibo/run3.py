import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pickle
import numpy as np, pandas as pd
import sim
SP = sim.SP
d = pd.read_csv(sim.BARS, usecols=['time','open','high','low','close','spread'])
d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
M = sim.build_market(d)
store = pickle.load(open(SP+'/trades2.pkl','rb'))
pool = sim.make_pool(M)
RUNS = 300
rng = np.random.default_rng(12345)
rows, Z = [], {}
for name, trades in store.items():
    fit = [t for t in trades if sim.PERIODS[t[1]][0] in sim.FIT]
    m = np.mean([t[7] for t in fit])
    rb = sim.random_baseline(M, trades, RUNS, rng, pool)
    mu, sd = rb.mean(), rb.std()
    z = (m - mu) / sd
    p = (np.sum(rb >= m) + 1) / (RUNS + 1)
    Z[name] = (rb - mu) / sd
    rows.append(dict(test=name, n=len(fit), meanR=m, rand_meanR=mu, rand_sd=sd, z=z, p=p))
df = pd.DataFrame(rows).sort_values('z', ascending=False)
# поправка на перебор: распределение максимума z среди всех 32 тестов при случайных входах
zmat = np.vstack([Z[n] for n in store])          # тесты x прогоны
maxz = zmat.max(axis=0)
best = df['z'].max()
p_max = (np.sum(maxz >= best) + 1) / (RUNS + 1)
pd.set_option('display.width',200,'display.max_rows',100)
print(df.round(3).to_string(index=False))
print(f'\nЛучший z = {best:.2f}. Медиана максимума z у случайных входов по 32 тестам = {np.median(maxz):.2f}; '
      f'доля случайных прогонов, где максимум z не хуже лучшего: p_max = {p_max:.3f}')
print('Средний R случайных входов (по тестам): от', round(df.rand_meanR.min(),3), 'до', round(df.rand_meanR.max(),3))
df.to_csv(SP+'/random_cmp.csv', index=False)
