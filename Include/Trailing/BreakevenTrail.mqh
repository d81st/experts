//+------------------------------------------------------------------+
//|                                              BreakevenTrail.mqh  |
//|                                                                  |
//|  Однократный перевод SL в безубыток с настраиваемым смещением.   |
//|  Champion: ManageBreakevenTrailing() из crt-bot_v4.2.            |
//|                                                                  |
//|  Изоляция: уникальный include-guard, никаких input-объявлений,   |
//|  никакого состояния модуля между вызовами.                       |
//+------------------------------------------------------------------+
#ifndef BREAKEVENTRAIL_MQH
#define BREAKEVENTRAIL_MQH

#include "../TradeAdapter.mqh"
#include "../BrokerAdapter.mqh"

//+------------------------------------------------------------------+
//| BreakevenTrailManage — публичный API.                            |
//|                                                                  |
//| Однократный перевод SL в безубыток + смещение для всех открытых  |
//| позиций с POSITION_SYMBOL == _Symbol И POSITION_MAGIC == magic.  |
//|                                                                  |
//| Параметры:                                                       |
//|   adapter      — ITradeAdapter (используется только для          |
//|                  PositionModify(ticket, sl, tp)).                |
//|   broker       — заполненный BrokerContext (нужны adjustedPoint  |
//|                  и minBrokerDistance).                            |
//|   magic        — magic фильтр (Req 12.5). При magic <= 0 —       |
//|                  ранний выход без побочных эффектов.             |
//|   startFactor  — порог активации, доля от изначальной SL-        |
//|                  дистанции: profitPts >= startFactor*slDistPts.  |
//|                  Должен быть > 0.                                |
//|   offsetPoints — смещение целевого SL от openPrice в пунктах:    |
//|                  BUY  → targetSL = open + offset * adjustedPoint |
//|                  SELL → targetSL = open - offset * adjustedPoint |
//|                  Должен быть >= 0.                                |
//|                                                                  |
//| Контракт (см. requirements.md §7):                               |
//|   - Req 7.1: currentPrice (BID для BUY / ASK для SELL).          |
//|   - Req 7.2: нет подходящих позиций → возврат без побочных      |
//|     эффектов.                                                    |
//|   - Req 7.3: невалидные параметры → Print + return.              |
//|   - Req 7.4: profitPoints < startFactor * slDistPoints → пропуск.|
//|   - Req 7.5: при активации — ровно один PositionModify за тик.   |
//|   - Req 7.6: нарушение minBrokerDistance → пропуск + Print.      |
//|   - Req 7.7 / Req 13.4: |currentSL - targetSL| <= 0.5 * point    |
//|     → пропуск (анти-спам / fp-tolerance).                        |
//|   - Req 7.8: PositionSelectByTicket → false → пропуск.           |
//|   - Req 7.9: PositionModify → false → Print + continue.          |
//|                                                                  |
//| Cross-magic protection (Req 12.5, 12.6, 12.8, 12.9):             |
//|   _Symbol + magic guard перед каждым PositionModify.             |
//|                                                                  |
//| Trailing safety — монотонность SL (Req 13.1, 13.2, 13.5):        |
//|   BUY: targetSL < currentSL запрещён; SELL: targetSL > currentSL |
//|   запрещён. Нарушение → пропуск тикета с Print.                  |
//+------------------------------------------------------------------+
void BreakevenTrailManage(ITradeAdapter      *adapter,
                          const BrokerContext &broker,
                          const long           magic,
                          const double         startFactor,
                          const double         offsetPoints);

//+------------------------------------------------------------------+
//| BreakevenTrailManage — реализация (порт из crt-bot_v4.2).        |
//+------------------------------------------------------------------+
void BreakevenTrailManage(ITradeAdapter      *adapter,
                          const BrokerContext &broker,
                          const long           magic,
                          const double         startFactor,
                          const double         offsetPoints)
  {
   //--- Ранние выходы (Req 7.3, 12.8)
   if(adapter == NULL)             { Print("BreakevenTrailManage: adapter == NULL"); return; }
   if(magic <= 0)                  { Print("BreakevenTrailManage: magic <= 0"); return; }
   if(startFactor <= 0.0)          { Print("BreakevenTrailManage: startFactor <= 0"); return; }
   if(offsetPoints < 0.0)          { Print("BreakevenTrailManage: offsetPoints < 0"); return; }
   if(broker.adjustedPoint <= 0.0) { Print("BreakevenTrailManage: broker.adjustedPoint <= 0"); return; }

   //--- Req 7.2: нет позиций — выход без побочных эффектов
   if(PositionsTotal() == 0) return;

   const double min_dist = broker.minBrokerDistance;
   const double point    = broker.adjustedPoint;

   //--- Обход позиций (Req 12.5, 12.6: фильтр по _Symbol + magic)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                    continue;  // Req 7.8
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;  // Req 12.5
      if(PositionGetInteger(POSITION_MAGIC)  != magic)       continue;  // Req 12.5, 12.6

      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);

      //--- Req 7.1: текущая цена для типа позиции
      const double currentPrice = (ptype == POSITION_TYPE_BUY)
                                  ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- Req 7.1: профит и дистанция SL в пунктах
      const double profitPoints = (ptype == POSITION_TYPE_BUY)
                                  ? (currentPrice - openPrice) / point
                                  : (openPrice - currentPrice) / point;
      const double slDistPoints = MathAbs(openPrice - currentSL) / point;

      //--- Req 7.4: порог активации ещё не достигнут (или SL не выставлен)
      if(slDistPoints == 0.0) continue;
      if(profitPoints < startFactor * slDistPoints) continue;

      //--- Req 7.5: целевой SL
      const double targetSL = (ptype == POSITION_TYPE_BUY)
                              ? (openPrice + offsetPoints * point)
                              : (openPrice - offsetPoints * point);

      //--- Req 7.7 / Req 13.4: SL уже в зоне безубытка (fp-tolerance)
      if(MathAbs(currentSL - targetSL) <= 0.5 * point) continue;

      //--- Req 13.1, 13.2, 13.5: монотонность SL (belt-and-suspenders;
      //    targetSL детерминирован, но явная проверка защищает от
      //    регрессий и аномальных currentSL у тикетов под другим EA).
      if(currentSL > 0.0)
        {
         if(ptype == POSITION_TYPE_BUY  && targetSL < currentSL)
           {
            PrintFormat("BreakevenTrailManage: skip #%I64u — targetSL %.5f < currentSL %.5f (BUY, non-monotonic)",
                        ticket, targetSL, currentSL);
            continue;
           }
         if(ptype == POSITION_TYPE_SELL && targetSL > currentSL)
           {
            PrintFormat("BreakevenTrailManage: skip #%I64u — targetSL %.5f > currentSL %.5f (SELL, non-monotonic)",
                        ticket, targetSL, currentSL);
            continue;
           }
        }

      //--- Req 7.6: брокерская дистанция
      if(MathAbs(currentPrice - targetSL) < min_dist)
        {
         PrintFormat("BreakevenTrailManage: skip #%I64u — |%.5f - %.5f| < minBrokerDistance %.5f",
                     ticket, currentPrice, targetSL, min_dist);
         continue;
        }

      const double newSL = NormalizeDouble(targetSL, _Digits);

      //--- Req 7.8: re-select перед модификацией (защита от race
      //    между обнаружением и вызовом PositionModify).
      if(!PositionSelectByTicket(ticket)) continue;

      if(adapter.PositionModify(ticket, newSL, currentTP))
        {
         PrintFormat("🛡️ Безубыток активирован #%I64u | SL→%.5f | Profit:%.0f pts",
                     ticket, newSL, profitPoints);
        }
      else
        {
         //--- Req 7.9: лог + продолжение обхода
         PrintFormat("❌ BreakevenTrailManage #%I64u: PositionModify rc=%u (%s)",
                     ticket, adapter.ResultRetcode(), adapter.ResultComment());
        }
     }
  }

#endif // BREAKEVENTRAIL_MQH
//+------------------------------------------------------------------+
