import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pickle
import numpy as np, pandas as pd
import sim
SP = sim.SP
store = pickle.load(open(SP+'/trades2.pkl','rb'))
rng = np.random.default_rng(7)
def boot(r, n=5000):
    return np.quantile([rng.choice(r, len(r)).mean() for _ in range(n)], [0.025, 0.975])
for name in ['a2.0|gap|W2|O1', 'a2.0|nogap|W2|O1']:
    t = store[name]
    fit = np.array([x[7] for x in t if sim.PERIODS[x[1]][0] in sim.FIT])
    lo, hi = boot(fit)
    risks = np.array([abs(x[4]-x[5]) for x in t])
    wins = (fit > 0).mean()
    print(f'{name}: n={len(fit)} meanR={fit.mean():.3f} 95% бутстрэп [{lo:.2f}; {hi:.2f}] win={wins:.0%} '
          f'| медиана стопа ${np.median(risks):.2f} (квартили {np.quantile(risks,.25):.2f}-{np.quantile(risks,.75):.2f})')
    big = np.sort(fit)[-5:]
    print('   5 лучших сделок R:', np.round(big,1), '| доля прибыли от топ-5:', f'{big.sum()/fit[fit>0].sum():.0%}')
    # по периодам
    for k,(p,_,_) in enumerate(sim.PERIODS):
        r = np.array([x[7] for x in t if x[1]==k])
        print(f'   {p}: n={len(r)} meanR={r.mean():.2f} win={(r>0).mean():.0%}')
