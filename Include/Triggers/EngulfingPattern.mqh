//+------------------------------------------------------------------+
//|                                              EngulfingPattern.mqh |
//|                                                                  |
//|  Паттерн поглощения на двух закрытых свечах: тело r1 (последняя  |
//|  закрытая) поглощает тело r2 (предыдущая). Направление — по      |
//|  цвету r1: бычья → покупка (+1), медвежья → продажа (-1).        |
//|  Используется как сигнал (engulfing) или как подтверждение входа |
//|  в зоне (гибриды).                                               |
//+------------------------------------------------------------------+
#ifndef ENGULFINGPATTERN_MQH
#define ENGULFINGPATTERN_MQH

//+------------------------------------------------------------------+
//| EngulfingConfig — фильтры паттерна (0 — фильтр выключен).        |
//|   requireOpposite   — r2 противоположного цвета                  |
//|   requireFullBody   — тело r1 полностью перекрывает тело r2      |
//|   openCloseTolPts   — макс. |open[r1] - close[r2]|, пункты       |
//|   minBodyPts        — мин. тело r1, пункты                       |
//|   r1BodyRatio       — мин. доля тела от диапазона r1             |
//|   r2BodyRatio       — мин. доля тела от диапазона r2             |
//|   r2ToR1SizeRatio   — мин. отношение тела r2 к телу r1           |
//+------------------------------------------------------------------+
struct EngulfingConfig
  {
   bool   requireOpposite;
   bool   requireFullBody;
   double openCloseTolPts;
   double minBodyPts;
   double r1BodyRatio;
   double r2BodyRatio;
   double r2ToR1SizeRatio;
  };

//+------------------------------------------------------------------+
//| EngulfingDetect — есть ли поглощение r2 свечой r1.               |
//|   point — размер пункта для фильтров в пунктах.                  |
//|   dir   — +1 бычье (покупка), -1 медвежье (продажа).             |
//+------------------------------------------------------------------+
bool EngulfingDetect(const MqlRates &r2, const MqlRates &r1, const EngulfingConfig &c,
                     const double point, int &dir)
  {
   double body1 = MathAbs(r1.close - r1.open);
   double body2 = MathAbs(r2.close - r2.open);

   if(body1 <= 0.0 || body2 <= 0.0) return false;
   if(c.minBodyPts > 0.0 && body1 / point < c.minBodyPts) return false;

   if(c.r1BodyRatio > 0.0)
     {
      double range = r1.high - r1.low;
      if(range <= 0.0) return false;
      if(body1 / range < c.r1BodyRatio) return false;
     }

   if(c.r2BodyRatio > 0.0)
     {
      double range = r2.high - r2.low;
      if(range <= 0.0) return false;
      if(body2 / range < c.r2BodyRatio) return false;
     }

   // тело r2 не должно быть слишком маленьким относительно r1
   if(c.r2ToR1SizeRatio > 0.0 && body2 / body1 < c.r2ToR1SizeRatio) return false;

   if(body1 <= body2) return false;

   if(c.openCloseTolPts > 0.0)
     {
      double gap_pts = MathAbs(r1.open - r2.close) / point;
      if(gap_pts > c.openCloseTolPts) return false;
     }

   bool c1_bull = r1.close > r1.open;
   bool c1_bear = r1.close < r1.open;
   bool c2_bull = r2.close > r2.open;
   bool c2_bear = r2.close < r2.open;
   if(!c1_bull && !c1_bear) return false;

   if(c.requireOpposite)
     {
      if(c1_bull && !c2_bear) return false;
      if(c1_bear && !c2_bull) return false;
     }

   if(c.requireFullBody)
     {
      double r1_body_low  = MathMin(r1.open, r1.close);
      double r1_body_high = MathMax(r1.open, r1.close);
      double r2_body_low  = MathMin(r2.open, r2.close);
      double r2_body_high = MathMax(r2.open, r2.close);
      if(r1_body_low > r2_body_low || r1_body_high < r2_body_high) return false;
     }

   dir = c1_bull ? 1 : -1;
   return true;
  }

#endif // ENGULFINGPATTERN_MQH
//+------------------------------------------------------------------+
