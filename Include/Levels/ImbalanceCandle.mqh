//+------------------------------------------------------------------+
//|                                              ImbalanceCandle.mqh |
//|                                                                  |
//|  Имбаланс-свеча: длинная свеча с сильным телом, закрывшаяся за   |
//|  экстремумом предыдущей — между ними остаётся гэп (FVG). Свеча   |
//|  определяется сразу после закрытия, третью свечу не ждём: гэп    |
//|  считается от закрытия свечи до экстремума предыдущей (столько   |
//|  FVG останется, если следующая свеча не вернётся за закрытие).   |
//|  От свечи строятся фибо-зоны: 0 — начало свечи, 1 — её конец     |
//|  (у покупной 0 = минимум, 1 = максимум; у продажной наоборот).   |
//+------------------------------------------------------------------+
#ifndef IMBALANCECANDLE_MQH
#define IMBALANCECANDLE_MQH

#include "FiboZones.mqh"

//+------------------------------------------------------------------+
//| ImbalanceConfig — условия свечи (доли ATR предыдущих свечей).    |
//|   minRangeAtr  — длина свечи (тень к тени) ≥ N × ATR             |
//|   minBodyRatio — тело ≥ доли всей свечи                          |
//|   minGapAtr    — гэп ≥ N × ATR                                   |
//+------------------------------------------------------------------+
struct ImbalanceConfig
  {
   double minRangeAtr;
   double minBodyRatio;
   double minGapAtr;
  };

//+------------------------------------------------------------------+
//| ImbalanceDetect — r1 — закрытая свеча, r2 — предыдущая, atr —    |
//| ATR до свечи r1. dir: +1 покупная (закрытие выше открытия),      |
//| -1 продажная.                                                    |
//+------------------------------------------------------------------+
bool ImbalanceDetect(const MqlRates &r2, const MqlRates &r1, const double atr,
                     const ImbalanceConfig &c, int &dir)
  {
   const double range = r1.high - r1.low;
   if(range <= 0.0 || atr <= 0.0 || r1.close == r1.open)
      return false;
   if(range < c.minRangeAtr * atr || MathAbs(r1.close - r1.open) < c.minBodyRatio * range)
      return false;
   dir = (r1.close > r1.open) ? 1 : -1;
   const double gap = (dir == 1) ? r1.close - r2.high : r2.low - r1.close;
   return gap > 0.0 && gap >= c.minGapAtr * atr;
  }

//+------------------------------------------------------------------+
//| Зоны от свечи [lo, hi] направления dir. Уровни — как на графике  |
//| фибо, натянутом от начала свечи (0) к концу (1).                 |
//+------------------------------------------------------------------+

// Откат внутрь свечи между уровнями nearLvl и farLvl (0.5 и 0.382): сделка по
// направлению свечи, цель — конец свечи (линия 1).
void ImbalanceRetraceZone(const double hi, const double lo, const int dir,
                          const double nearLvl, const double farLvl, FiboZone &z)
  {
   const double start = (dir == 1) ? lo : hi;
   const double end   = (dir == 1) ? hi : lo;
   FiboRetraceZone(start, end, 1.0 - nearLvl, 1.0 - farLvl, z);
  }

// Зона за свечей на разворот: beyondEnd — за концом свечи (уровни 1.212, 1.618 …,
// цель — конец свечи, линия 1), иначе — зеркально за её началом (цель — линия 0).
void ImbalanceExtZone(const double hi, const double lo, const int dir, const bool beyondEnd,
                      const double nearLvl, const double farLvl, FiboZone &z)
  {
   const bool above = (dir == 1) == beyondEnd;
   FiboExtZone(hi, lo, above, nearLvl, farLvl, z);
  }

#endif // IMBALANCECANDLE_MQH
//+------------------------------------------------------------------+
