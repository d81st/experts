//+------------------------------------------------------------------+
//|                                              ChannelBreakout.mqh |
//|                                                                  |
//|  Пробой канала (Дончиан): закрытие бара за максимумом/минимумом  |
//|  N предыдущих баров — вход по тренду; закрытие за противоположной|
//|  границей более короткого канала — выход. Всё по закрытым барам. |
//+------------------------------------------------------------------+
#ifndef CHANNELBREAKOUT_MQH
#define CHANNELBREAKOUT_MQH

// Максимум и минимум баров shift … shift+period-1.
bool ChannelRange(const ENUM_TIMEFRAMES tf, const int shift, const int period, double &hi, double &lo)
  {
   if(period < 1)
      return false;
   const int ih = iHighest(_Symbol, tf, MODE_HIGH, period, shift);
   const int il = iLowest(_Symbol, tf, MODE_LOW, period, shift);
   if(ih < 0 || il < 0)
      return false;
   hi = iHigh(_Symbol, tf, ih);
   lo = iLow(_Symbol, tf, il);
   return hi > 0.0 && lo > 0.0;
  }

// Сигнал на закрытом баре 1: +1 — закрытие выше максимума period баров до него,
// -1 — ниже минимума, 0 — нет.
int ChannelBreakoutSignal(const ENUM_TIMEFRAMES tf, const int period)
  {
   double hi, lo;
   if(!ChannelRange(tf, 2, period, hi, lo))
      return 0;
   const double c1 = iClose(_Symbol, tf, 1);
   if(c1 > hi)
      return 1;
   if(c1 < lo)
      return -1;
   return 0;
  }

// Выход позиции направления dir: закрытие бара 1 за противоположной границей
// канала period баров до него.
bool ChannelExitSignal(const ENUM_TIMEFRAMES tf, const int period, const int dir)
  {
   double hi, lo;
   if(!ChannelRange(tf, 2, period, hi, lo))
      return false;
   const double c1 = iClose(_Symbol, tf, 1);
   return (dir == 1) ? (c1 < lo) : (c1 > hi);
  }

#endif // CHANNELBREAKOUT_MQH
//+------------------------------------------------------------------+
