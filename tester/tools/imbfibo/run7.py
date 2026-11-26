import sys, pickle, time
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np, pandas as pd
from multiprocessing import Pool
import sim
SP = sim.SP
d = pd.read_csv(sim.BARS, usecols=['time','open','high','low','close','spread'])
d['time'] = pd.to_datetime(d['time'], format='%Y.%m.%d %H:%M')
d = d[d['time'] < sim.CUTOFF].sort_values('time').drop_duplicates('time').reset_index(drop=True)
M = sim.build_market(d); POOL = sim.make_pool(M)
S = {}
for f, tag in (('trades2.pkl','A'), ('trades_rr1.pkl','B'), ('trades_v12.pkl','C')):
    for k, v in pickle.load(open(SP+'/'+f, 'rb')).items(): S[f'{tag}:{k}'] = v
NAMES = list(S)
RUNS = 150
def work(i):
    name = NAMES[i]; tr = S[name]
    fit = [t for t in tr if sim.PERIODS[t[1]][0] in sim.FIT]
    if len(fit) < 5: return name, len(fit), np.nan, np.nan, np.nan, None
    rng = np.random.default_rng(1000 + i)
    m = float(np.mean([t[7] for t in fit]))
    rb = sim.random_baseline(M, tr, RUNS, rng, POOL)
    mu, sd = float(rb.mean()), float(rb.std())
    return name, len(fit), m, mu, sd, ((rb - mu) / sd)
if __name__ == '__main__':
    t0 = time.time()
    with Pool(2) as p: res = p.map(work, range(len(NAMES)), chunksize=1)
    rows = [dict(test=n, n=nf, meanR=m, rand_meanR=mu, rand_sd=sd, z=(m-mu)/sd if sd and sd==sd else np.nan) for n,nf,m,mu,sd,_ in res]
    df = pd.DataFrame(rows)
    ok = [r[5] for r in res if r[5] is not None and len(r[5]) == RUNS and r[1] >= 20]
    maxz = np.vstack(ok).max(axis=0)
    df.to_csv(SP+'/random_all.csv', index=False); np.save(SP+'/maxz.npy', maxz)
    print(f'готово за {time.time()-t0:.0f}с; тестов с n>=20: {len(ok)} из {len(NAMES)}')
