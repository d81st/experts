//+------------------------------------------------------------------+
//|                                             SyncTrailManager.mqh |
//|                                                                  |
//|  Синхронный трейлинг блока SL/TP: после активации SL и TP        |
//|  сдвигаются вместе, расстояние между ними (блок) сохраняется,    |
//|  SL не опускается ниже безубытка.                                |
//|                                                                  |
//|  Состояние по тикетам хранится в модуле (g_syncTrailStates);     |
//|  чистые формулы — в SyncTrail.mqh. Вызывается через              |
//|  TrailingManage (режим TRAILING_SYNC_EX).                        |
//+------------------------------------------------------------------+
#ifndef SYNCTRAILMANAGER_MQH
#define SYNCTRAILMANAGER_MQH

#include "../TradeAdapter.mqh"
#include "../BrokerAdapter.mqh"
#include "SyncTrail.mqh"

// Состояние SyncTrail по тикетам (поиск линейный).
SyncTrailState g_syncTrailStates[];

//+------------------------------------------------------------------+
//| ТРЕЙЛИНГ — синхронный блок SL/TP                                 |
//+------------------------------------------------------------------+

// Удалить осиротевшие записи (тикет закрыт или не принадлежит боту).
// Вызывается в начале каждого SyncTrailManage.
void SyncTrail_Gc(const long magic)
{
   const int n = ArraySize(g_syncTrailStates);
   // Идём с конца, чтобы удаление через ArrayRemove не сбило индексы.
   for(int i = n - 1; i >= 0; i--)
   {
      const ulong ticket = g_syncTrailStates[i].ticket;
      bool alive = PositionSelectByTicket(ticket);
      if(alive && PositionGetInteger(POSITION_MAGIC) != magic)
         alive = false;
      if(!alive)
         ArrayRemove(g_syncTrailStates, i, 1);
   }
}

//+------------------------------------------------------------------+
//| Найти/создать состояние SyncTrail по тикету. Возвращает индекс   |
//| в g_syncTrailStates[]. Поля initialSL/openPrice/dir фиксируются      |
//| только при создании (block invariants).                          |
//+------------------------------------------------------------------+
int SyncTrail_FindOrCreate(const ulong  ticket,
                      const int    dir,
                      const double openPrice,
                      const double currentSL)
{
   const int n = ArraySize(g_syncTrailStates);
   for(int i = 0; i < n; i++)
      if(g_syncTrailStates[i].ticket == ticket)
         return i;

   const int newIdx = n;
   ArrayResize(g_syncTrailStates, n + 1);
   g_syncTrailStates[newIdx].ticket              = ticket;
   g_syncTrailStates[newIdx].dir                 = dir;
   g_syncTrailStates[newIdx].openPrice           = openPrice;
   g_syncTrailStates[newIdx].initialSL           = currentSL;
   g_syncTrailStates[newIdx].activated           = false;
   g_syncTrailStates[newIdx].blockSize           = 0.0;
   g_syncTrailStates[newIdx].lastSL              = 0.0;
   g_syncTrailStates[newIdx].modificationSkipped = false;
   g_syncTrailStates[newIdx].warnedNoStops       = false;
   return newIdx;
}

void SyncTrailManage(ITradeAdapter       *adapter,
                     const BrokerContext &broker,
                     const long           magic,
                     const double         startFactor,
                     const double         stepPoints)
{
   SyncTrail_Gc(magic);

   const double point             = broker.adjustedPoint;
   const double minBrokerDistance = broker.minBrokerDistance;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                    continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != magic) continue;

      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const int    dir       = (ptype == POSITION_TYPE_BUY) ? 1 : -1;
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);
      const double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      const int sIdx = SyncTrail_FindOrCreate(ticket, dir, openPrice, currentSL);

      // Позиция без стопов — активация невозможна; лог один раз.
      if(currentSL == 0.0 || currentTP == 0.0)
      {
         if(!g_syncTrailStates[sIdx].warnedNoStops)
         {
            PrintFormat("⚠️  SyncTrail #%I64u: нет SL/TP, активация пропущена", ticket);
            g_syncTrailStates[sIdx].warnedNoStops = true;
         }
         continue;
      }

      // Активация трейлинга по достижении порога startFactor.
      if(!g_syncTrailStates[sIdx].activated)
      {
         const double profitPts = (dir == 1)
                                  ? (bid - openPrice) / point
                                  : (openPrice - ask) / point;
         const double slDistPts = MathAbs(openPrice - g_syncTrailStates[sIdx].initialSL) / point;
         const double threshold = slDistPts * startFactor;

         if(profitPts < threshold)
            continue;

         g_syncTrailStates[sIdx].activated = true;
         g_syncTrailStates[sIdx].blockSize = MathAbs(currentTP - currentSL);

         const double blockPts = g_syncTrailStates[sIdx].blockSize / point;
         PrintFormat("🟢 SyncTrail #%I64u %s: активирован | open=%.5f initSL=%.5f initTP=%.5f "
                     "block=%.1f profit=%.1f thr=%.1f",
                     ticket, (dir == 1 ? "BUY" : "SELL"),
                     openPrice, g_syncTrailStates[sIdx].initialSL, currentTP,
                     blockPts, profitPts, threshold);
      }

      double cand = ComputeCandidateSL(dir, bid, ask, openPrice, g_syncTrailStates[sIdx].initialSL);
      cand = ClampToBreakeven(dir, cand, openPrice);

      // Строгое улучшение SL
      if(!IsStrictImprovement(dir, cand, currentSL))
      {
         g_syncTrailStates[sIdx].modificationSkipped = false;
         continue;
      }

      // Шаговый порог (при stepPoints==0 всегда true)
      if(!ImprovementMeetsStep(dir, cand, currentSL, point, stepPoints))
      {
         g_syncTrailStates[sIdx].modificationSkipped = false;
         continue;
      }

      const double newSL = NormalizeDouble(cand, _Digits);
      const double newTP = NormalizeDouble(ComputeNewTP(dir, newSL, g_syncTrailStates[sIdx].blockSize), _Digits);

      // Проверка брокерской дистанции с анти-спамом
      if(!BrokerDistanceOk(dir, bid, ask, newSL, newTP, minBrokerDistance))
      {
         if(!g_syncTrailStates[sIdx].modificationSkipped)
         {
            PrintFormat("⏸️ SyncTrail #%I64u: отложено (MinBrokerDistance) | candSL=%.5f newTP=%.5f bid=%.5f ask=%.5f minDist=%.5f",
                        ticket, newSL, newTP, bid, ask, minBrokerDistance);
            g_syncTrailStates[sIdx].modificationSkipped = true;
         }
         continue;
      }

      if(!adapter.PositionModify(ticket, newSL, newTP))
      {
         // Гонка: позиция могла закрыться между селектом и модификацией.
         if(!PositionSelectByTicket(ticket))
            continue;
         PrintFormat("❌ SyncTrail #%I64u: PositionModify rc=%u (%s) newSL=%.5f newTP=%.5f",
                     ticket, adapter.ResultRetcode(),
                     adapter.ResultComment(), newSL, newTP);
         continue;
      }

      const double prevSL  = (g_syncTrailStates[sIdx].lastSL == 0.0)
                             ? g_syncTrailStates[sIdx].initialSL
                             : g_syncTrailStates[sIdx].lastSL;
      const double deltaPts = MathAbs(newSL - prevSL) / point;
      PrintFormat("📈 SyncTrail #%I64u %s: SL→%.5f TP→%.5f Δ=%.1f pts",
                  ticket, (dir == 1 ? "BUY" : "SELL"), newSL, newTP, deltaPts);
      g_syncTrailStates[sIdx].lastSL              = newSL;
      g_syncTrailStates[sIdx].modificationSkipped = false;
   }
}

#endif // SYNCTRAILMANAGER_MQH
//+------------------------------------------------------------------+
