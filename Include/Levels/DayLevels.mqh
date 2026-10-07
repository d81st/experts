//+------------------------------------------------------------------+
//|                                                    DayLevels.mqh |
//|                                                                  |
//|  Дневные уровни ликвидности: максимум и минимум предыдущего дня  |
//|  и окна часов текущего дня (Азиатская сессия и т. п.).           |
//|  Время — серверное, дни — календарные (00:00 сервера).           |
//+------------------------------------------------------------------+
#ifndef DAYLEVELS_MQH
#define DAYLEVELS_MQH

//+------------------------------------------------------------------+
//| DayRange — диапазон: границы и время их образования.             |
//| hiTime/loTime заполняются, только если их просили (needTimes).    |
//+------------------------------------------------------------------+
struct DayRange
  {
   double   hi;
   double   lo;
   datetime hiTime;
   datetime loTime;
  };

// Начало календарного дня (00:00 сервера) для времени t.
datetime DayLevelsDayStart(const datetime t) { return t - (t % 86400); }

// Максимум/минимум и время их образования по минуткам на [from, to].
bool DayLevelsScanM1(const datetime from, const datetime to, DayRange &r)
  {
   MqlRates m1[];
   const int n = CopyRates(_Symbol, PERIOD_M1, from, to, m1);
   if(n <= 0)
      return false;
   int iHi = 0, iLo = 0;
   for(int i = 1; i < n; i++)
     {
      if(m1[i].high > m1[iHi].high) iHi = i;
      if(m1[i].low  < m1[iLo].low)  iLo = i;
     }
   r.hi = m1[iHi].high; r.hiTime = m1[iHi].time;
   r.lo = m1[iLo].low;  r.loTime = m1[iLo].time;
   return true;
  }

//+------------------------------------------------------------------+
//| DayLevelsPrevDay — максимум и минимум дня перед днём бара t      |
//| (дневная свеча D1). needTimes — найти и время экстремумов (M1).  |
//+------------------------------------------------------------------+
bool DayLevelsPrevDay(const datetime t, const bool needTimes, DayRange &r)
  {
   const int shift = iBarShift(_Symbol, PERIOD_D1, t) + 1;
   r.hi = iHigh(_Symbol, PERIOD_D1, shift);
   r.lo = iLow(_Symbol, PERIOD_D1, shift);
   r.hiTime = 0; r.loTime = 0;
   if(r.hi <= 0.0 || r.lo <= 0.0)
      return false;
   if(!needTimes)
      return true;
   const datetime from = iTime(_Symbol, PERIOD_D1, shift);
   DayRange m;
   if(!DayLevelsScanM1(from, from + 86399, m))
      return false;
   r.hiTime = m.hiTime;
   r.loTime = m.loTime;
   return true;
  }

//+------------------------------------------------------------------+
//| DayLevelsHours — максимум и минимум окна [startHour, endHour)    |
//| того же дня, что и t (например, Азия 0–7). false — окно ещё не   |
//| закончилось или нет данных.                                      |
//+------------------------------------------------------------------+
bool DayLevelsHours(const datetime t, const int startHour, const int endHour, DayRange &r)
  {
   const datetime dayStart = DayLevelsDayStart(t);
   const datetime from = dayStart + startHour * 3600;
   const datetime to   = dayStart + endHour * 3600 - 1;
   if(t < to)
      return false;
   return DayLevelsScanM1(from, to, r) && r.hi > 0.0 && r.lo > 0.0;
  }

#endif // DAYLEVELS_MQH
//+------------------------------------------------------------------+
