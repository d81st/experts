//+------------------------------------------------------------------+
//|                                                     TimeExit.mqh |
//|                                                                  |
//|  Выход по времени: закрыть позицию бота через N баров рабочего   |
//|  таймфрейма, если раньше не сработали SL/TP. Вместе с отключённым |
//|  тейком измеряет, есть ли у самого входа преимущество.           |
//+------------------------------------------------------------------+
#ifndef TIMEEXIT_MQH
#define TIMEEXIT_MQH

#include <Trade\Trade.mqh>

#define TIME_EXIT_RETRY_SECONDS 10   // пауза между повторами после отказа закрытия

//+------------------------------------------------------------------+
//| TimeExitManage — закрыть позиции (_Symbol, magic) старше         |
//| bars × PeriodSeconds(tf). bars <= 0 — выключено.                 |
//+------------------------------------------------------------------+
void TimeExitManage(CTrade &tr, const long magic,
                    const ENUM_TIMEFRAMES tf, const int bars)
  {
   if(bars <= 0)
      return;
   static datetime lastFail = 0;
   const datetime now = TimeCurrent();
   if(lastFail > 0 && now - lastFail < TIME_EXIT_RETRY_SECONDS)
      return;

   const long maxAge = (long)bars * PeriodSeconds(tf);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if((long)(now - (datetime)PositionGetInteger(POSITION_TIME)) < maxAge)
         continue;
      if(tr.PositionClose(ticket))
         PrintFormat("⏱ Выход по времени: #%I64u через %d бар(ов)", ticket, bars);
      else
        {
         lastFail = now;
         PrintFormat("❌ Выход по времени #%I64u не удался: %u %s",
                     ticket, tr.ResultRetcode(), tr.ResultRetcodeDescription());
        }
     }
  }

#endif // TIMEEXIT_MQH
//+------------------------------------------------------------------+
