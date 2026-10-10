//+------------------------------------------------------------------+
//|                                               LiquiditySweep.mqh |
//|                                                                  |
//|  Снятие ликвидности (из liq-grab):                               |
//|   • StreakSweepSignal — тренд по цепочке экстремумов: «настоящие» |
//|     свечи (обновили максимум или минимум соседней) подряд дают    |
//|     всё более низкие максимумы (медвежий) или высокие минимумы    |
//|     (бычий); уровень — экстремум свечи цепочки; сигнал — свеча    |
//|     `sig` прокалывает уровень и закрывается обратно (по тренду).  |
//|   • RangeSweepSignal — снятие максимума/минимума диапазона (день, |
//|     Азия) с закрытием обратно: против прокола, одна сделка на     |
//|     сторону диапазона в день.                                     |
//|   • SweepOppositeTarget — противоположный экстремум (цель).       |
//|  rates[] — серия (0 — формирующийся бар).                        |
//+------------------------------------------------------------------+
#ifndef LIQUIDITYSWEEP_MQH
#define LIQUIDITYSWEEP_MQH

//+------------------------------------------------------------------+
//| StreakSweepConfig                                                |
//|   historyDepth    — баров в rates[]                              |
//|   trendLookback   — сколько «настоящих» свечей брать в цепочку   |
//|   minStreak       — мин. длина цепочки для тренда                |
//|   signalShift     — какая свеча цепочки даёт уровень (0 — ближняя)|
//|   trendMaxAgeBars — забыть тренд без подтверждения N баров (0 —  |
//|                     никогда)                                     |
//+------------------------------------------------------------------+
struct StreakSweepConfig
  {
   ENUM_TIMEFRAMES tf;
   int             historyDepth;
   int             trendLookback;
   int             minStreak;
   int             signalShift;
   int             trendMaxAgeBars;
  };

struct StreakSweepState
  {
   int      trend;       // 0 — нет, 1 — бычий, 2 — медвежий
   datetime confirmed;   // бар последнего подтверждения тренда
  };

void StreakSweepReset(StreakSweepState &s)
  {
   s.trend     = 0;
   s.confirmed = 0;
  }

// Сигнал на свече sig: +1 — покупка (снят минимум в бычьем тренде), −1 — продажа, 0 — нет.
// level — снятый уровень. Состояние тренда обновляется на каждом вызове.
int StreakSweepSignal(const StreakSweepConfig &c, StreakSweepState &s, const MqlRates &rates[],
                      const int sig, double &level)
  {
   int idx[];
   ArrayResize(idx, c.trendLookback);
   int count = 0;
   for(int i = 1 + sig; i < c.historyDepth - 1 && count < c.trendLookback; i++)
      if(rates[i].high > rates[i + 1].high || rates[i].low < rates[i + 1].low)
         idx[count++] = i;
   if(count < c.minStreak)
      return 0;
   if(c.signalShift < 0 || c.signalShift >= count)
      return 0;

   int streakHigh = 1;
   for(int k = 1; k < count; k++)
     {
      if(rates[idx[k - 1]].high > rates[idx[k]].high) streakHigh++;
      else break;
     }
   int streakLow = 1;
   for(int k = 1; k < count; k++)
     {
      if(rates[idx[k - 1]].low < rates[idx[k]].low) streakLow++;
      else break;
     }

   int proposed = 0;
   if(streakHigh >= c.minStreak && streakLow < c.minStreak) proposed = 1;
   else if(streakLow >= c.minStreak && streakHigh < c.minStreak) proposed = 2;

   if(proposed != 0)
     {
      s.trend     = proposed;
      s.confirmed = rates[0].time;
     }
   else if(c.trendMaxAgeBars > 0 && s.trend != 0 &&
           rates[0].time - s.confirmed > (datetime)c.trendMaxAgeBars * PeriodSeconds(c.tf))
      s.trend = 0;   // тренд устарел
   if(s.trend == 0)
      return 0;

   const int lv = idx[c.signalShift];
   if(s.trend == 1)
     {
      level = rates[lv].low;
      if(rates[sig].low < level && rates[sig].close > level)
         return 1;
     }
   else
     {
      level = rates[lv].high;
      if(rates[sig].high > level && rates[sig].close < level)
         return -1;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| RangeSweep — снятие границы диапазона на закрытой свече bar.      |
//+------------------------------------------------------------------+
struct RangeSweepState
  {
   datetime highDay;   // день, в который уже торговали снятие максимума
   datetime lowDay;
  };

void RangeSweepReset(RangeSweepState &s)
  {
   s.highDay = 0;
   s.lowDay  = 0;
  }

// −1 — продажа (снят максимум hi, закрытие ниже), +1 — покупка (снят минимум lo), 0 — нет.
// level — снятая граница, opposite — противоположная (цель). dayStart — день свечи.
int RangeSweepSignal(RangeSweepState &s, const MqlRates &bar, const double hi, const double lo,
                     const datetime dayStart, double &level, double &opposite)
  {
   if(bar.high > hi && bar.close < hi && s.highDay != dayStart)
     {
      s.highDay = dayStart;
      level     = hi;
      opposite  = lo;
      return -1;
     }
   if(bar.low < lo && bar.close > lo && s.lowDay != dayStart)
     {
      s.lowDay = dayStart;
      level    = lo;
      opposite = hi;
      return 1;
     }
   return 0;
  }

// Ближайшая ликвидность с той стороны: максимум (покупка) / минимум (продажа) баров sig+1 … depth−1.
double SweepOppositeTarget(const MqlRates &rates[], const int sig, const int depth, const int dir)
  {
   double target = (dir == 1) ? rates[sig + 1].high : rates[sig + 1].low;
   for(int i = sig + 2; i < depth; i++)
      target = (dir == 1) ? MathMax(target, rates[i].high) : MathMin(target, rates[i].low);
   return target;
  }

#endif // LIQUIDITYSWEEP_MQH
//+------------------------------------------------------------------+
