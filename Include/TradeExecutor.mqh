//+------------------------------------------------------------------+
//|                                                TradeExecutor.mqh |
//|                                                                  |
//|  TradeExecutor — унифицированная отправка сделок (market/limit). |
//|                                                                  |
//|  Кратко:                                                         |
//|   - Pipeline: validate → enforce min-SL                          |
//|     → normalize → dispatch → read result.                        |
//|   - Формат success-лога:                                         |
//|     "✅ %s [%s] | Lot:%.2f | SL:%.0f pts | TP:%.0f pts | RR:%.2f" |
//|   - Fallback limit→market при пересечённой цене.                 |
//|   - Market: фильтр спреда относительно SL, повтор при временных  |
//|     ошибках брокера, лимит проскальзывания, OrderCheck.          |
//|   - Пауза отправки после серии отказов брокера.                  |
//|                                                                  |
//|  Остаётся в EA (guard перед вызовом):                            |
//|   - Trade-lock (g_last_trade_request_time) — EA-specific.        |
//+------------------------------------------------------------------+
#ifndef TRADEEXECUTOR_MQH
#define TRADEEXECUTOR_MQH

#include <Trade\Trade.mqh>
#include "BrokerAdapter.mqh"
#include "TradeJournal.mqh"

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
//|               после клампа SL — ответственность caller'а.        |
//|   lot       — объём в лотах. Должен быть > 0.                    |
//|   comment   — комментарий к ордеру для журнала брокера.          |
//|   maxSpreadToSL   — market: макс. спред как доля расстояния до SL |
//|                     (0.10 = 10%); 0 — фильтр выключен.            |
//|   maxSlippageToSL — market: макс. отклонение цены исполнения от   |
//|                     запрошенной как доля расстояния до SL;        |
//|                     0 — без ограничения.                          |
//+------------------------------------------------------------------+
struct TradeOrderRequest
  {
   ENUM_ORDER_TYPE   orderType;
   double            price;
   double            sl;
   double            tp;
   double            lot;
   string            comment;
   double            maxSpreadToSL;
   double            maxSlippageToSL;

                     TradeOrderRequest(void)
     {
      orderType       = ORDER_TYPE_BUY;
      price           = 0.0;
      sl              = 0.0;
      tp              = 0.0;
      lot             = 0.0;
      comment         = "";
      maxSpreadToSL   = 0.0;
      maxSlippageToSL = 0.0;
     }
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
//|   skipped     — true: запрос не отправлялся из-за фильтра        |
//|                 (спред, закрытый рынок, пауза после отказов).    |
//|                 Модуль уже записал причину в журнал; EA может     |
//|                 не печатать ошибку повторно и подождать.          |
//+------------------------------------------------------------------+
struct TradeResult
  {
   bool              success;
   ulong             ticket;
   uint              retcode;
   string            description;
   bool              skipped;
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
//      7. Market: торговля разрешена, спред ≤ maxSpreadToSL × SL,
//         OrderCheck (маржа, объём). Пауза после серии отказов.
//      8. Dispatch по итоговому orderType: trade.Buy/Sell/BuyLimit/SellLimit.
//         Market: до 2 повторов при временных ошибках с новой ценой,
//         если она не ушла дальше maxSlippageToSL × SL.
//      9. Чтение результата: DONE → ticket, иначе retcode/desc.
//     10. При success — Print с фактическим проскальзыванием.
//
//    Изоляция: модуль не трогает глобалов EA; trade-lock — на стороне EA.
//    Единственное состояние модуля — счётчик отказов брокера для паузы.
//
//    Параметры:
//      tr     — CTrade EA (ссылка, т.к. tr.* меняет result-state).
//      broker — заполненный BrokerContext (const &).
//      req    — входной запрос, НЕ-const: модуль может переключить
//               orderType из лимита в market на шаге 6.
TradeResult TradeExecutorSend(CTrade              &tr,
                              const BrokerContext &broker,
                              TradeOrderRequest   &req);

//--- Пауза после серии отказов брокера.
#define TRADE_EXECUTOR_FAIL_STREAK   5
#define TRADE_EXECUTOR_PAUSE_SEC     900

int      g_tradeExecutorFailStreak  = 0;
datetime g_tradeExecutorPausedUntil = 0;

//+------------------------------------------------------------------+
//| TradeExecutor_IsRetryable — временная ошибка, повтор имеет смысл. |
//+------------------------------------------------------------------+
bool TradeExecutor_IsRetryable(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE       ||
           rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_PRICE_OFF     ||
           rc == TRADE_RETCODE_TIMEOUT       ||
           rc == TRADE_RETCODE_CONNECTION    ||
           rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
  }

//+------------------------------------------------------------------+
//| TradeExecutor_Skip — запрос не отправлен из-за фильтра.          |
//| Одна и та же причина (rc) печатается не чаще раза в минуту.      |
//+------------------------------------------------------------------+
TradeResult TradeExecutor_Skip(const uint rc, const string why)
  {
   static uint     s_lastRc   = 0;
   static datetime s_lastTime = 0;
   if(rc != s_lastRc || TimeCurrent() - s_lastTime >= 60)
     {
      PrintFormat("⏸️ Ордер не отправлен: %s", why);
      TradeJournalWrite(StringFormat("SKIP;;;;;;;;;;;;;;%u;%s", rc, why));
      s_lastRc   = rc;
      s_lastTime = TimeCurrent();
     }

   TradeResult result;
   result.success     = false;
   result.ticket      = 0;
   result.retcode     = rc;
   result.description = why;
   result.skipped     = true;
   return result;
  }

//+------------------------------------------------------------------+
//| TradeExecutor_PreflightMarket — проверки перед market-ордером.   |
//| Возвращает "" если можно отправлять, иначе причину отказа.       |
//+------------------------------------------------------------------+
string TradeExecutor_PreflightMarket(const TradeOrderRequest &req, uint &rc)
  {
   const bool isBuy = (req.orderType == ORDER_TYPE_BUY);

   //--- торговля по символу разрешена в нужную сторону
   const ENUM_SYMBOL_TRADE_MODE mode =
      (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (isBuy  && mode == SYMBOL_TRADE_MODE_SHORTONLY) ||
      (!isBuy && mode == SYMBOL_TRADE_MODE_LONGONLY))
     {
      rc = TRADE_RETCODE_TRADE_DISABLED;
      return "торговля по символу запрещена брокером";
     }

   //--- спред относительно расстояния до SL
   const double slDist = MathAbs(req.price - req.sl);
   if(req.maxSpreadToSL > 0.0 && req.sl > 0.0 && slDist > 0.0)
     {
      const double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(spread > req.maxSpreadToSL * slDist)
        {
         rc = TRADE_RETCODE_PRICE_OFF;
         return StringFormat("спред %s > %.0f%% от SL %s",
                             DoubleToString(spread, _Digits), req.maxSpreadToSL * 100.0,
                             DoubleToString(slDist, _Digits));
        }
     }

   //--- маржа и объём (остальные замечания OrderCheck не блокируют отправку)
   MqlTradeRequest     chk = {};
   MqlTradeCheckResult res = {};
   chk.action = TRADE_ACTION_DEAL;
   chk.symbol = _Symbol;
   chk.volume = req.lot;
   chk.type   = req.orderType;
   chk.price  = req.price;
   chk.sl     = req.sl;
   chk.tp     = req.tp;
   if(!OrderCheck(chk, res) &&
      (res.retcode == TRADE_RETCODE_NO_MONEY       ||
       res.retcode == TRADE_RETCODE_MARKET_CLOSED  ||
       res.retcode == TRADE_RETCODE_TRADE_DISABLED ||
       res.retcode == TRADE_RETCODE_INVALID_VOLUME ||
       res.retcode == TRADE_RETCODE_LIMIT_VOLUME))
     {
      rc = res.retcode;
      return StringFormat("OrderCheck: %u %s", res.retcode, res.comment);
     }
   return "";
  }

//+------------------------------------------------------------------+
//| TradeExecutorSend — реализация. См. doc-comment над прототипом.  |
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
   result.skipped     = false;

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

   const bool isMarket = (req.orderType == ORDER_TYPE_BUY || req.orderType == ORDER_TYPE_SELL);

   //--- STEP 7: Пауза после серии отказов + проверки market-ордера
   if(TimeCurrent() < g_tradeExecutorPausedUntil)
      return TradeExecutor_Skip(TRADE_RETCODE_REJECT,
                                StringFormat("пауза после %d отказов брокера до %s",
                                             TRADE_EXECUTOR_FAIL_STREAK,
                                             TimeToString(g_tradeExecutorPausedUntil, TIME_MINUTES)));
   if(isMarket)
     {
      uint pre_rc = 0;
      const string why = TradeExecutor_PreflightMarket(req, pre_rc);
      if(why != "")
         return TradeExecutor_Skip(pre_rc, why);
     }

   //--- STEP 8: Dispatch (market: до 2 повторов при временных ошибках)
   const double requested = req.price;
   const double slDist    = MathAbs(req.price - req.sl);
   const double maxSlip   = (req.maxSlippageToSL > 0.0 && slDist > 0.0)
                            ? req.maxSlippageToSL * slDist : 0.0;
   if(isMarket && maxSlip > 0.0)
      tr.SetDeviationInPoints((ulong)MathCeil(maxSlip / _Point));

   const int attempts = isMarket ? 3 : 1;
   bool sent = false;
   uint rc   = 0;
   int  used = 0;   // сколько раз реально отправляли
   const double spreadAtSend = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const ulong  t0           = GetMicrosecondCount();
   for(int attempt = 0; attempt < attempts; attempt++)
     {
      if(attempt > 0)
        {
         //--- новая цена; если ушла дальше допустимого — вход отменяем
         const double fresh = NormalizeDouble(SymbolInfoDouble(_Symbol,
                              req.orderType == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID), _Digits);
         if(maxSlip > 0.0 && MathAbs(fresh - requested) > maxSlip)
           {
            PrintFormat("⚠️ Повтор отменён: цена %s ушла от %s дальше допустимого",
                        DoubleToString(fresh, _Digits), DoubleToString(requested, _Digits));
            break;
           }
         if((req.sl > 0.0 && MathAbs(fresh - req.sl) < broker.minBrokerDistance) ||
            (req.tp > 0.0 && MathAbs(fresh - req.tp) < broker.minBrokerDistance))
            break;
         req.price = fresh;
         PrintFormat("🔁 Повтор %d/%d после %u (%s) по цене %s",
                     attempt, attempts - 1, rc, tr.ResultRetcodeDescription(),
                     DoubleToString(fresh, _Digits));
         Sleep(100 * attempt);
        }

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
      used++;
      rc = tr.ResultRetcode();
      if(sent && rc == TRADE_RETCODE_DONE)
         break;
      if(!TradeExecutor_IsRetryable(rc))
         break;
     }

   //--- STEP 9: Read result
   const string rd        = tr.ResultRetcodeDescription();
   const double latencyMs = (double)(GetMicrosecondCount() - t0) / 1000.0;
   if(sent && rc == TRADE_RETCODE_DONE)
     {
      g_tradeExecutorFailStreak = 0;
      result.success     = true;
      result.ticket      = tr.ResultOrder();
      result.retcode     = rc;
      result.description = rd;

      //--- STEP 10: Success log (market: с фактическим проскальзыванием)
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
      const double tpPoints = (broker.adjustedPoint > 0.0 && req.tp > 0.0)
                              ? MathAbs(req.tp - req.price) / broker.adjustedPoint
                              : 0.0;
      const double slDist   = MathAbs(req.price - req.sl);
      const double rr       = (slDist > 0.0 && req.tp > 0.0)
                              ? MathAbs(req.tp - req.price) / slDist
                              : 0.0;
      string slipStr = "";
      if(isMarket && tr.ResultPrice() > 0.0)
        {
         // > 0 — исполнение хуже запрошенной цены
         const double slip = (req.orderType == ORDER_TYPE_BUY)
                             ? tr.ResultPrice() - requested
                             : requested - tr.ResultPrice();
         slipStr = " | Slip:" + DoubleToString(slip, _Digits);
        }
      PrintFormat("✅ %s [%s] | Lot:%.2f | SL:%.0f pts | TP:%.0f pts | RR:%.2f%s",
                  dirLabel, _Symbol, req.lot, slPoints, tpPoints, rr, slipStr);

      const double fill = (isMarket && tr.ResultPrice() > 0.0) ? tr.ResultPrice() : req.price;
      const double slip = (req.orderType == ORDER_TYPE_BUY || req.orderType == ORDER_TYPE_BUY_LIMIT)
                          ? fill - requested : requested - fill;
      TradeJournalWrite(StringFormat("ENTRY;%I64d;%I64d;%s;%.2f;%s;%s;%s;%s;%s;%s;%.1f;%d;;%u;%s",
                                     (long)tr.RequestMagic(), (long)result.ticket, dirLabel, req.lot,
                                     TradeJournal_D(requested), TradeJournal_D(fill), TradeJournal_D(slip),
                                     TradeJournal_D(spreadAtSend), TradeJournal_D(req.sl), TradeJournal_D(req.tp),
                                     latencyMs, used, rc, req.comment));
     }
   else
     {
      result.success     = false;
      result.ticket      = 0;
      result.retcode     = rc;
      result.description = rd;
      TradeJournalWrite(StringFormat("REJECT;%I64d;;%s;%.2f;%s;;;%s;%s;%s;%.1f;%d;;%u;%s",
                                     (long)tr.RequestMagic(), EnumToString(req.orderType), req.lot,
                                     TradeJournal_D(requested), TradeJournal_D(spreadAtSend),
                                     TradeJournal_D(req.sl), TradeJournal_D(req.tp), latencyMs, used, rc, rd));

      //--- серия отказов брокера → пауза отправки
      g_tradeExecutorFailStreak++;
      if(g_tradeExecutorFailStreak >= TRADE_EXECUTOR_FAIL_STREAK)
        {
         g_tradeExecutorPausedUntil = TimeCurrent() + TRADE_EXECUTOR_PAUSE_SEC;
         g_tradeExecutorFailStreak  = 0;
         PrintFormat("⛔ %d отказов брокера подряд (последний: %u %s) — пауза до %s",
                     TRADE_EXECUTOR_FAIL_STREAK, rc, rd,
                     TimeToString(g_tradeExecutorPausedUntil, TIME_MINUTES));
        }
     }
   return result;
  }

#endif // TRADEEXECUTOR_MQH
//+------------------------------------------------------------------+
