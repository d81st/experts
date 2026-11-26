# imbfibo — проверка схемы «имбаланс-свеча + кастомное фибо» по минуткам

Результаты и выводы — `tester/results/h1-imbalance-fibo.md`, таблицы — `tester/results/imbfibo-data/`.

## Файлы

| Файл | Что делает | Читает | Пишет (в `IMBFIBO_WORK`) |
|---|---|---|---|
| `sim.py` | общее ядро: исполнение лимиток по M1, спред/своп, случайные входы; `python3 -I sim.py` — синтетические проверки | — | — |
| `run2.py` | H1: 32 варианта исходной схемы (размер свечи × гэп × W × зоны) | минутки | `grid2.csv`, `trades2.pkl` |
| `run3.py` | те же 32 варианта против случайных входов, поправка на перебор | `trades2.pkl` | `random_cmp.csv` |
| `run4.py` | бутстрэп и разбор двух лучших вариантов из `run2` | `trades2.pkl` | — |
| `run5.py` | RR 1:1 на M5/M15/M30/H1 (64 варианта) | минутки | `grid_rr1.csv`, `trades_rr1.pkl` |
| `run6.py` | вариант 1 (широкий стоп, M30/H1) и вариант 2 (H4/D1) — 128 тестов | минутки | `grid_v12.csv`, `trades_v12.pkl` |
| `run7.py` | все 224 теста против случайных входов, общая поправка на перебор | три `trades*.pkl` | `random_all.csv`, `maxz.npy` |
| `run8.py` | устойчивость лучшего: издержки, соседние параметры, направление | минутки | — |
| `run9.py` | внешняя проверка на 2023 | минутки | — |

Первый прогон (`run1`) сделан до исправления ошибки исполнения и в репозиторий не входит
(подробности — в `tester/results/h1-imbalance-fibo.md`).

## Запуск

```
export BARS_M1=путь/к/bars_XAUUSDm_M1.csv     # run-38913123748/data/bars_XAUUSDm_M1.zip, ветка tester-results
export IMBFIBO_WORK=/путь/к/рабочей/папке       # по умолчанию ./work
python3 -I tester/tools/imbfibo/sim.py
python3 -I tester/tools/imbfibo/run2.py
python3 -I tester/tools/imbfibo/run5.py
python3 -I tester/tools/imbfibo/run6.py
python3 -I tester/tools/imbfibo/run7.py         # ≈ 1.5 мин, 2 процесса
python3 -I tester/tools/imbfibo/run9.py
```

`run3.py` и `run4.py` — после `run2.py`; `run7.py` — после `run2.py`, `run5.py`, `run6.py`. Нужны numpy
и pandas. Результаты детерминированы (фиксированные зёрна), повторный прогон даёт те же таблицы.

## Важное

- Данные режутся по `CUTOFF = 2026-10-16`: холдаут не загружается, в скриптах стоит `assert`.
- В `run9.py` в список периодов добавляется 2023; остальные скрипты 2023 не используют.
- Промежуточные файлы (`*.pkl`, `*.npy`) в репозиторий не коммитятся.
