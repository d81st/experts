//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|                                                                  |
//|  TradeExecutor — унифицированная отправка сделок (market/limit). |
//|                                                                  |
//|  Champion summary:                                               |
//|   - Структура pipeline — от engulfing: validate → enforce min-SL |
//|     → normalize → dispatch → read result.                        |
//|   - Формат success-лога — crt-bot:                               |
//|     "✅ %s [%s] | Lot:%.2f | SL:%.0f pts | TP:%.0f pts | RR:%.2f"|
//|   - Fallback limit→market при пересечённой цене.                 |
//|                                                                  |
//|  Не переезжает в модуль (остаётся в EA как guard перед вызовом):  |
//|   - Trade-lock (g_last_trade_request_time) — EA-specific.        |
//|   - Spread-check — разная семантика между EA (MaxSpreadPips vs   |
//|     MaxSpread).                                                   |
//+------------------------------------------------------------------+
#ifndef TRADEEXECUTOR_MQH
#define TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include "BrokerAdapter.mqh"

//+------------------------------------------------------------------+
//| TradeOrderRequest — параметры одного торгового запроса.          |
//|                                                                  |
//| Заполняется вызывающим EA на основе сигнала стратегии и затем    |
//| передаётся в TradeExecutorSend по НЕ-const ссылке: модуль может  |
//| переключить `orderType` с лимита на market (BUY_LIMIT → BUY,     |
//| SELL_LIMIT → SELL) при пересечённой цене, что                    |
//| должно быть видимо вызывающей стороне для корректного учёта      |
//| pending-ticket'ов.                                               |
//|                                                                  |
//| Цены приходят в модуль уже рассчитанными стратегией. SL/TP к     |
//| моменту вызова уже клампятся к минимальной брокерской дистанции  |
//| и нормализуются по `_Digits` внутри TradeExecutorSend.           |
//|                                                                  |
//|   orderType — один из {ORDER_TYPE_BUY, ORDER_TYPE_SELL,          |
//|               ORDER_TYPE_BUY_LIMIT, ORDER_TYPE_SELL_LIMIT}. Иные |
//|               значения отвергаются с retcode                     |
//|               TRADE_RETCODE_INVALID.                             |
//|   price     — для market: целевая цена входа (Ask/Bid стратегией);
//|               для limit:  лимит-цена ордера. Должна быть > 0.    |
//|   sl        — цена стоп-лосса в абсолютных значениях, либо 0.0,  |
//|               если SL не используется. Должна быть >= 0.         |
//|               Может быть скорректирована модулем                 |
//|               через BrokerEnforceMinSLDist.                      |
//|   tp        — цена тейк-профита, либо 0.0. Должна быть >= 0.     |
//|               Модулем не модифицируется; пересчёт TP             |
//|               после клампа SL — ответственность caller'а         |
//|               (champion-driven рефайнинг).                       |
//|   lot       — объём в лотах. Должен быть > 0.                    |
//|   comment   — комментарий к ордеру для журнала брокера.          |
//+------------------------------------------------------------------+
struct TradeOrderRequest
  {
   ENUM_ORDER_TYPE   orderType;
   double            price;
   double            sl;
   double            tp;
   double            lot;
   string            comment;
  };

//+------------------------------------------------------------------+
//| TradeResult — структурированный результат отправки.              |
//|                                                                  |
//| Возвращается TradeExecutorSend всегда (success или нет): caller  |
//| смотрит `success` для дальнейшей логики, а при failure читает    |
//| `retcode` и `description` для логирования или восстановления.    |
//|                                                                  |
//|   success     — true ⇔ брокер подтвердил операцию с              |
//|                 retcode = TRADE_RETCODE_DONE.                    |
//|                 При success = false поле `ticket` гарантированно |
//|                 равно 0 (инвариант модуля).                      |
//|   ticket      — тикет открытой позиции или pending-ордера,       |
//|                 полученный через `trade.ResultOrder()` при       |
//|                 успехе; 0 при failure.                           |
//|   retcode     — `trade.ResultRetcode()` при провале вызова       |
//|                 `trade.*` или TRADE_RETCODE_DONE при успехе.     |
//|                 Для невалидных входных данных модуль возвращает  |
//|                 синтетический код: TRADE_RETCODE_INVALID,        |
//|                 TRADE_RETCODE_INVALID_VOLUME,                    |
//|                 TRADE_RETCODE_INVALID_PRICE,                     |
//|                 TRADE_RETCODE_INVALID_STOPS.                     |
//|   description — `trade.ResultRetcodeDescription()` либо текст,   |
//|                 идентифицирующий нарушенный инвариант (например, |
//|                 «SL violates min broker distance»).              |
//+------------------------------------------------------------------+
struct TradeResult
  {
   bool              success;
   ulong             ticket;
   uint              retcode;
   string            description;
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс — прототип TradeExecutorSend.                |
//+------------------------------------------------------------------+

//--- Унифицированная отправка торгового запроса (market или limit).
//
//    Пайплайн (9 шагов):
//      1. Валидация входа: orderType из supported,
//         lot>0, price>0, sl/tp/minBrokerDistance >= 0. Провал → INVALID*.
//      2. trade.SetTypeFilling(broker.fillType).
//      3. BrokerEnforceMinSLDist. TP модулем не корректируется.
//      4. Нормализация price/sl/tp до _Digits. 0.0→0.0.
//      5. Post-condition guard min-distance после нормализации:
//         INVALID_STOPS при нарушении.
//      6. Fallback limit→market:
//         BUY_LIMIT + Ask<=price → BUY; SELL_LIMIT + Bid>=price → SELL.
//         Переключение видимо caller'у (req — не-const ref).
//      7. Dispatch по итоговому orderType: trade.Buy/Sell/BuyLimit/SellLimit.
//      8. Чтение результата: DONE → ticket, иначе retcode/desc.
//      9. При success — Print формата crt-bot.
//
//    Изоляция: модуль не трогает глобалов EA;
//    spread-check и trade-lock — на стороне EA как guard перед вызовом.
//
//    Параметры:
//      tr     — CTrade EA (ссылка, т.к. tr.* меняет result-state).
//      broker — заполненный BrokerContext (const &).
//      req    — входной запрос, НЕ-const: модуль может переключить
//               orderType из лимита в market на шаге 6.
TradeResult TradeExecutorSend(CTrade              &tr,
                              const BrokerContext &broker,
                              TradeOrderRequest   &req);

//+------------------------------------------------------------------+
//| TradeExecutorSend — реализация. См. doc-comment над прототипом. |
//+------------------------------------------------------------------+
TradeResult TradeExecutorSend(CTrade              &tr,
                              const BrokerContext &broker,
                              TradeOrderRequest   &req)
  {
   TradeResult result;
   result.success     = false;
   result.ticket      = 0;
   result.retcode     = TRADE_RETCODE_ERROR;
   result.description = "";

   //--- === STEP 1: input validation / pre-flight === ---
   //    Ранний выход БЕЗ вызова tr.* и БЕЗ success-лога.

   //--- 1.1 orderType из supported-set.
   if(req.orderType != ORDER_TYPE_BUY        &&
      req.orderType != ORDER_TYPE_SELL       &&
      req.orderType != ORDER_TYPE_BUY_LIMIT  &&
      req.orderType != ORDER_TYPE_SELL_LIMIT)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID;
      result.description = "Unsupported order type";
      return result;
     }

   //--- 1.2 lot > 0. Покрывает и lot < 0, и lot == 0.
   if(req.lot <= 0.0)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID_VOLUME;
      result.description = "Invalid lot: must be > 0";
      return result;
     }

   //--- 1.3 price > 0. Покрывает и price < 0, и price == 0.
   if(req.price <= 0.0)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID_PRICE;
      result.description = "Invalid price: must be > 0";
      return result;
     }

   //--- 1.4 Запрет отрицательных значений у остальных входов.
   if(req.price < 0.0 ||
      req.sl    < 0.0 ||
      req.tp    < 0.0 ||
      broker.minBrokerDistance < 0.0)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID;
      result.description = "Invalid negative input";
      return result;
     }

   //--- STEP 2: SetTypeFilling
   tr.SetTypeFilling(broker.fillType);

   //--- STEP 3: Enforce min broker distance on SL
   BrokerEnforceMinSLDist(broker, req.orderType, req.price, req.sl);

   //--- STEP 4: Normalize prices
   req.price = NormalizeDouble(req.price, _Digits);
   req.sl    = NormalizeDouble(req.sl,    _Digits);
   req.tp    = NormalizeDouble(req.tp,    _Digits);

   //--- STEP 5: Post-condition guard for min broker distance
   //    После нормализации стопы могут уйти под порог за счёт округления — fail fast.
   if(req.sl > 0.0 &&
      MathAbs(req.price - req.sl) < broker.minBrokerDistance)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID_STOPS;
      result.description = "SL violates min broker distance after normalization";
      return result;
     }
   if(req.tp > 0.0 &&
      MathAbs(req.price - req.tp) < broker.minBrokerDistance)
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = TRADE_RETCODE_INVALID_STOPS;
      result.description = "TP violates min broker distance after normalization";
      return result;
     }

   //--- STEP 6: Fallback limit → market
   if(req.orderType == ORDER_TYPE_BUY_LIMIT)
     {
      const double askN   = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits);
      const double priceN = req.price; // already normalized
      if(askN <= priceN) req.orderType = ORDER_TYPE_BUY; // switch to market
     }
   else if(req.orderType == ORDER_TYPE_SELL_LIMIT)
     {
      const double bidN   = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits);
      const double priceN = req.price;
      if(bidN >= priceN) req.orderType = ORDER_TYPE_SELL;
     }

   //--- STEP 7: Dispatch
   bool sent = false;
   switch(req.orderType)
     {
      case ORDER_TYPE_BUY:
         sent = tr.Buy(req.lot, _Symbol, req.price, req.sl, req.tp, req.comment);
         break;
      case ORDER_TYPE_SELL:
         sent = tr.Sell(req.lot, _Symbol, req.price, req.sl, req.tp, req.comment);
         break;
      case ORDER_TYPE_BUY_LIMIT:
         sent = tr.BuyLimit(req.lot, req.price, _Symbol, req.sl, req.tp,
                            ORDER_TIME_GTC, 0, req.comment);
         break;
      case ORDER_TYPE_SELL_LIMIT:
         sent = tr.SellLimit(req.lot, req.price, _Symbol, req.sl, req.tp,
                             ORDER_TIME_GTC, 0, req.comment);
         break;
      default:
         // unreachable (STEP 1 validates), but be defensive
         result.success     = false;
         result.ticket      = 0;
         result.retcode     = TRADE_RETCODE_INVALID;
         result.description = "Unsupported order type after fallback";
         return result;
     }

   //--- STEP 8: Read result
   const uint   rc = tr.ResultRetcode();
   const string rd = tr.ResultRetcodeDescription();
   if(sent && rc == TRADE_RETCODE_DONE)
     {
      result.success     = true;
      result.ticket      = tr.ResultOrder();
      result.retcode     = rc;
      result.description = rd;

      //--- STEP 9: Success log in crt-bot format
      // Direction label string
      string dirLabel;
      switch(req.orderType)
        {
         case ORDER_TYPE_BUY:        dirLabel = "BUY";        break;
         case ORDER_TYPE_SELL:       dirLabel = "SELL";       break;
         case ORDER_TYPE_BUY_LIMIT:  dirLabel = "BUY_LIMIT";  break;
         case ORDER_TYPE_SELL_LIMIT: dirLabel = "SELL_LIMIT"; break;
         default:                    dirLabel = "?";          break;
        }
      const double slPoints = (broker.adjustedPoint > 0.0)
                              ? MathAbs(req.price - req.sl) / broker.adjustedPoint
                              : 0.0;
      const double tpPoints = (broker.adjustedPoint > 0.0)
                              ? MathAbs(req.tp - req.price) / broker.adjustedPoint
                              : 0.0;
      const double slDist   = MathAbs(req.price - req.sl);
      const double rr       = (slDist > 0.0)
                              ? MathAbs(req.tp - req.price) / slDist
                              : 0.0;
      PrintFormat("✅ %s [%s] | Lot:%.2f | SL:%.0f pts | TP:%.0f pts | RR:%.2f",
                  dirLabel, _Symbol, req.lot, slPoints, tpPoints, rr);
     }
   else
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = rc;
      result.description = rd;
     }
   return result;
  }

#endif // TRADEEXECUTOR_MQH
//+------------------------------------------------------------------+
