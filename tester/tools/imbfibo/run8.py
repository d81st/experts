import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'run6.py')).read().split('store, meta')[0]
exec(src)
import numpy as np
rng = np.random.default_rng(5)
H60 = build_tf(M, 60)

def evaluate(label, a_lo=2.0, W=0, k=1.0, rr=1.0, spr_mult=1.0, slip=None, typ='O1', H=H60):
    old_s, old_spr = sim.SLIP, M.spr.copy()
    if slip is not None: sim.SLIP = slip
    M.spr = old_spr * spr_mult
    su = setups_tf(H, a_lo, W)
    tr, sk = orders(M, su, typ, ('atr', k), ('rr', rr))
    sim.SLIP, M.spr = old_s, old_spr
    out = {}
    for kk, (p, _, _) in enumerate(sim.PERIODS):
        r = np.array([t[7] for t in tr if t[1] == kk]); out[p] = (len(r), r.mean() if len(r) else np.nan)
    fit = np.array([t[7] for t in tr if sim.PERIODS[t[1]][0] in sim.FIT])
    bs = np.quantile([rng.choice(fit, len(fit)).mean() for _ in range(3000)], [.025, .975])
    print(f'{label:<38} n={len(fit):4d} R_fit={fit.mean():+.3f} [{bs[0]:+.2f};{bs[1]:+.2f}] | ' +
          ' '.join(f'{p}:{out[p][1]:+.2f}({out[p][0]})' for p in out), flush=True)
    return tr

print('БАЗА и издержки (H1, O1 = лонг/шорт против импульса из зоны 1.212, стоп 1 ATR, RR 1:1):')
base = evaluate('база')
evaluate('проскальзывание стопа 0.50 USD', slip=0.5)
evaluate('спред ×2', spr_mult=2.0)
evaluate('спред ×2 и проскальзывание 0.50', spr_mult=2.0, slip=0.5)
print('\nСоседние параметры (не подбор, а проверка плато):')
for a in (1.5, 2.5, 3.0): evaluate(f'размер свечи >= {a} ATR', a_lo=a)
for k in (0.75, 1.25, 1.5, 2.0): evaluate(f'стоп {k} ATR', k=k)
for rr in (0.75, 1.5, 2.0): evaluate(f'RR {rr}', rr=rr)
evaluate('ожидание 1 свеча (W1)', W=1)
evaluate('ожидание 2 свечи (W2)', W=2)
print('\nДругие зоны с тем же стопом/тейком (контроль):')
for typ in ('O2', 'I1', 'I2'): evaluate(f'зона {typ}', typ=typ)
print('\nРазбивка по направлению (база):')
fit = [t for t in base if sim.PERIODS[t[1]][0] in sim.FIT]
for dn, nm in ((1, 'лонги (после падающей свечи)'), (-1, 'шорты (после растущей свечи)')):
    r = np.array([t[7] for t in fit if t[3] == dn]); print(f'  {nm}: n={len(r)} R={r.mean():+.3f} win={(r>0).mean():.0%}')
