import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim
sim.PERIODS = [('2023', '2023-01-01', '2024-01-01')] + sim.PERIODS      # добавляем 2023 как внешний период
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'run6.py')).read().split('store, meta')[0]
exec(src)
import numpy as np
print('Первый бар данных:', d['time'].iloc[0])
H = build_tf(M, 60)
# правило зафиксировано ДО этой проверки: H1, свеча >= 2 ATR (тело >= 60%, настоящий имбаланс), вход 1.212 против импульса,
# стоп 1 ATR, тейк RR 1:1, ожидание 0 свечей
for label, k, rr in (('база: стоп 1 ATR, RR 1', 1.0, 1.0), ('RR 2', 1.0, 2.0), ('стоп 1.5 ATR, RR 1', 1.5, 1.0)):
    su = setups_tf(H, 2.0, 0)
    tr, sk = orders(M, su, 'O1', ('atr', k), ('rr', rr))
    r = np.array([t[7] for t in tr if t[1] == 0])      # период 2023
    rng = np.random.default_rng(1)
    bs = np.quantile([rng.choice(r, len(r)).mean() for _ in range(4000)], [.025, .975]) if len(r) else (np.nan, np.nan)
    print(f'{label:<26} 2023: n={len(r)} R={r.mean():+.3f} [{bs[0]:+.2f};{bs[1]:+.2f}] win={(r>0).mean():.0%}')
    if label.startswith('база'):
        for dn, nm in ((1,'лонги'), (-1,'шорты')):
            q = np.array([t[7] for t in tr if t[1]==0 and t[3]==dn]); print(f'    {nm}: n={len(q)} R={q.mean():+.3f}')
# контроль: остальные зоны на 2023
for typ in ('O2', 'I1', 'I2'):
    tr, sk = orders(M, setups_tf(H, 2.0, 0), typ, ('atr', 1.0), ('rr', 1.0))
    r = np.array([t[7] for t in tr if t[1] == 0]); print(f'контроль зона {typ} 2023: n={len(r)} R={r.mean():+.3f}')
