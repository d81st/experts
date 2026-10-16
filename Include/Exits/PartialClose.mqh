//+------------------------------------------------------------------+
//|                                                 PartialClose.mqh |
//|                                                                  |
//|  Частичное закрытие по R: когда прибыль позиции достигла atR ×   |
//|  исходный стоп, закрыть долю fraction; по выбору перенести стоп  |
//|  остатка в безубыток. Остаток идёт до тейка позиции. Исходный    |
//|  стоп запоминается при первой встрече позиции. Если объём не     |
//|  делится (часть или остаток меньше мин. лота) — частичного       |
//|  закрытия нет, позиция идёт целиком (запись в журнал).           |
//+------------------------------------------------------------------+
#ifndef PARTIALCLOSE_MQH
#define PARTIALCLOSE_MQH

#include <Trade\Trade.mqh>

struct PartialCloseConfig
  {
   bool   enabled;
   double atR;        // порог прибыли, в долях исходного стопа
   double fraction;   // какую долю объёма закрыть
   bool   moveToBE;   // после частичного закрытия — стоп остатка в безубыток
  };

struct PartialCloseState
  {
   ulong  ticket[];
   double sd[];       // исходное расстояние до стопа
   bool   done[];
  };

int PartialClose_Find(const PartialCloseState &s, const ulong t)
  {
   for(int i = 0; i < ArraySize(s.ticket); i++)
      if(s.ticket[i] == t)
         return i;
   return -1;
  }

// Вызывать на каждом тике.
void PartialCloseManage(CTrade &tr, const long magic, const PartialCloseConfig &c, PartialCloseState &s)
  {
   if(!c.enabled)
      return;
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      const ulong t = PositionGetTicket(p);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl   = PositionGetDouble(POSITION_SL);
      int k = PartialClose_Find(s, t);
      if(k < 0)
        {
         if(sl <= 0.0)
            continue;
         k = ArraySize(s.ticket);
         ArrayResize(s.ticket, k + 1);
         ArrayResize(s.sd, k + 1);
         ArrayResize(s.done, k + 1);
         s.ticket[k] = t;
         s.sd[k]     = MathAbs(open - sl);
         s.done[k]   = false;
        }
      if(s.done[k] || s.sd[k] <= 0.0)
         continue;
      const bool   buy    = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      const double profit = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - open
                                : open - SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(profit < c.atR * s.sd[k])
         continue;
      s.done[k] = true;
      const double vol  = PositionGetDouble(POSITION_VOLUME);
      const double part = MathFloor(vol * c.fraction / step + 1e-9) * step;
      if(part < minLot - 1e-9 || vol - part < minLot - 1e-9)
        {
         PrintFormat("ℹ️ #%I64u: %.1fR, но объём %.2f не делится (мин. лот %.2f) — идёт целиком до тейка",
                     t, c.atR, vol, minLot);
         continue;
        }
      const double tp = PositionGetDouble(POSITION_TP);
      if(tr.PositionClosePartial(t, part))
        {
         PrintFormat("✂️ #%I64u: %.1fR — закрыто %.2f из %.2f", t, c.atR, part, vol);
         if(c.moveToBE && PositionSelectByTicket(t) && tr.PositionModify(t, open, tp))
            PrintFormat("🔒 #%I64u: стоп остатка в безубыток %.3f", t, open);
        }
      else
        {
         s.done[k] = false;   // повторим на следующем тике
         PrintFormat("❌ Частичное закрытие #%I64u не удалось: %u %s", t, tr.ResultRetcode(),
                     tr.ResultRetcodeDescription());
        }
     }
   // чистим записи закрытых позиций
   for(int i = ArraySize(s.ticket) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(s.ticket[i]))
        {
         const int n = ArraySize(s.ticket);
         s.ticket[i] = s.ticket[n - 1]; s.sd[i] = s.sd[n - 1]; s.done[i] = s.done[n - 1];
         ArrayResize(s.ticket, n - 1); ArrayResize(s.sd, n - 1); ArrayResize(s.done, n - 1);
        }
  }

#endif // PARTIALCLOSE_MQH
//+------------------------------------------------------------------+
