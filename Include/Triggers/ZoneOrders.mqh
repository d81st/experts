//+------------------------------------------------------------------+
//|                                                   ZoneOrders.mqh |
//|                                                                  |
//|  Вход от зон: лимитки на ближнем краю зоны или вход по рынку     |
//|  после закрытия бара обратно из зоны. Ведёт учёт ордеров по      |
//|  слотам (одна зона — один слот), держит одну лимитку на          |
//|  направление (ближайшую к цене), двигает её изменением ордера,   |
//|  удаляет ордера вне учёта и закрывает лишние позиции. Откуда     |
//|  взялись зоны (фибо от волны, от диапазона дня…) — решает бот:   |
//|  он каждый тик передаёт массив зон FiboZone и флаги их наличия.  |
//+------------------------------------------------------------------+
#ifndef ZONEORDERS_MQH
#define ZONEORDERS_MQH

#include <Trade\Trade.mqh>
#include "../Core/BrokerAdapter.mqh"
#include "../Core/PositionGuard.mqh"
#include "../Core/TradeExecutor.mqh"
#include "../Levels/FiboZones.mqh"

#define ZONE_ORDERS_MAX_SLOTS 16

//+------------------------------------------------------------------+
//| ZoneOrdersConfig — параметры бота (заполняется в OnInit).        |
//|   slBufferPoints — стоп за дальним краем зоны + отступ, пункты   |
//|   minSLPoints    — более близкий стоп расширяется до минимума    |
//|   commentPrefix  — приставка комментария ордера (FIBO_<слот>)    |
//+------------------------------------------------------------------+
struct ZoneOrdersConfig
  {
   long            magic;
   ENUM_TIMEFRAMES tf;
   double          riskPercent;
   double          maxRiskOvershoot;
   double          maxSpreadToSL;
   double          maxSlippageToSL;
   double          slBufferPoints;
   double          minSLPoints;
   string          commentPrefix;
  };

//+------------------------------------------------------------------+
//| ZoneOrders — состояние слотов и статистика за прогон.            |
//|   used     — зона уже торговалась (до сброса диапазона)          |
//|   ticket   — тикет лимитки                                       |
//|   touched / touchExt — режим подтверждения: касание и экстремум  |
//+------------------------------------------------------------------+
struct ZoneOrders
  {
   int    n;
   bool   used[ZONE_ORDERS_MAX_SLOTS];
   ulong  ticket[ZONE_ORDERS_MAX_SLOTS];
   bool   touched[ZONE_ORDERS_MAX_SLOTS];
   double touchExt[ZONE_ORDERS_MAX_SLOTS];
   int    cntPlaced[ZONE_ORDERS_MAX_SLOTS], cntFilled[ZONE_ORDERS_MAX_SLOTS], cntPassed[ZONE_ORDERS_MAX_SLOTS];
   int    cntRisk[ZONE_ORDERS_MAX_SLOTS], cntRiskLow[ZONE_ORDERS_MAX_SLOTS];
   int    cntWidened[ZONE_ORDERS_MAX_SLOTS], cntMoved[ZONE_ORDERS_MAX_SLOTS];
   int    cntOrphans, cntExtraPos;
   double startBalance;
  };

void ZoneOrdersInit(ZoneOrders &s, const int n)
  {
   s.n = MathMin(n, ZONE_ORDERS_MAX_SLOTS);
   for(int i = 0; i < ZONE_ORDERS_MAX_SLOTS; i++)
     {
      s.used[i] = false; s.ticket[i] = 0; s.touched[i] = false; s.touchExt[i] = 0.0;
      s.cntPlaced[i] = 0; s.cntFilled[i] = 0; s.cntPassed[i] = 0; s.cntRisk[i] = 0; s.cntRiskLow[i] = 0;
      s.cntWidened[i] = 0; s.cntMoved[i] = 0;
     }
   s.cntOrphans   = 0;
   s.cntExtraPos  = 0;
   s.startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
  }

//+------------------------------------------------------------------+
//| Учёт ордеров                                                     |
//+------------------------------------------------------------------+

// Снять лимитку слота. Ордера уже нет — значит, исполнен: зона отработана.
// Тикет забывается только когда ордер действительно снят или исполнен.
bool ZoneOrdersDelete(ZoneOrders &s, CTrade &tr, const int slot)
  {
   if(s.ticket[slot] == 0)
      return true;
   if(!PositionGuardPendingExists(s.ticket[slot]))
     {
      s.ticket[slot] = 0;
      s.used[slot]   = true;
      s.cntFilled[slot]++;
      return true;
     }
   if(!tr.OrderDelete(s.ticket[slot]))
      return false;
   s.ticket[slot] = 0;
   return true;
  }

// Открыта сделка или торговля на паузе — лимитки снимаем (вернутся позже).
void ZoneOrdersCancelAll(ZoneOrders &s, CTrade &tr)
  {
   for(int i = 0; i < s.n; i++)
      ZoneOrdersDelete(s, tr, i);
  }

// Новый диапазон: лимитки снимаем, все зоны снова доступны.
// Не удалось снять (рынок закрыт) — подберёт ZoneOrdersSweepOrphans.
void ZoneOrdersReset(ZoneOrders &s, CTrade &tr)
  {
   for(int i = 0; i < s.n; i++)
     {
      ZoneOrdersDelete(s, tr, i);
      s.used[i] = false; s.ticket[i] = 0; s.touched[i] = false; s.touchExt[i] = 0.0;
     }
  }

// Зона слота сменилась (например, новый экстремум волны): снова доступна. Лимитку
// не снимаем — ZoneOrdersManageLimits передвинет её изменением ордера.
void ZoneOrdersRelease(ZoneOrders &s, const int slot)
  {
   s.used[slot] = false; s.touched[slot] = false; s.touchExt[slot] = 0.0;
  }

// Лимитки бота, которых нет в учёте (не снялись при закрытом рынке, остались после
// перезапуска), удаляются. Неудачные попытки повторяются не чаще раза в 10 секунд.
void ZoneOrdersSweepOrphans(ZoneOrders &s, CTrade &tr, const long magic)
  {
   static datetime lastFail = 0;
   if(lastFail > 0 && TimeCurrent() - lastFail < 10)
      return;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      bool tracked = false;
      for(int k = 0; k < s.n && !tracked; k++)
         tracked = (s.ticket[k] == t);
      if(tracked)
         continue;
      if(tr.OrderDelete(t))
        {
         s.cntOrphans++;
         PrintFormat("🧹 Удалена лимитка #%I64u вне учёта", t);
        }
      else
         lastFail = TimeCurrent();
     }
  }

// Бот держит одну сделку. Если исполнились сразу две лимитки (быстрое движение),
// лишние позиции закрываются, остаётся самая ранняя.
void ZoneOrdersCloseExtra(ZoneOrders &s, CTrade &tr, const long magic)
  {
   ulong    keep     = 0;
   datetime keepTime = 0;
   int      n        = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      n++;
      const datetime pt = (datetime)PositionGetInteger(POSITION_TIME);
      if(keep == 0 || pt < keepTime) { keep = t; keepTime = pt; }
     }
   if(n <= 1)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || t == keep || PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(tr.PositionClose(t))
        {
         s.cntExtraPos++;
         PrintFormat("⚠️ Закрыта лишняя позиция #%I64u (бот держит одну сделку)", t);
        }
     }
  }

// Отказ, который не исчезнет при повторе: зону вычёркиваем. Остальные — повторим позже.
bool ZoneOrdersPermanentReject(const uint rc)
  {
   return rc == TRADE_RETCODE_INVALID || rc == TRADE_RETCODE_INVALID_VOLUME ||
          rc == TRADE_RETCODE_INVALID_STOPS || rc == TRADE_RETCODE_NO_MONEY;
  }

//+------------------------------------------------------------------+
//| Стоп, лот, пропуски                                              |
//+------------------------------------------------------------------+

// Стоп за точкой farP + отступ; ближе minSLPoints — расширяется до минимума.
double ZoneOrdersSL(const ZoneOrdersConfig &c, const BrokerContext &b, const FiboZone &z,
                    const double entry, const double farP, bool &widened)
  {
   const double pt = b.adjustedPoint;
   double sl = farP - z.dir * c.slBufferPoints * pt;
   widened = MathAbs(entry - sl) < c.minSLPoints * pt;
   if(widened)
      sl = entry - z.dir * c.minSLPoints * pt;
   return NormalizeDouble(sl, _Digits);
  }

double ZoneOrdersLot(const ZoneOrdersConfig &c, const BrokerContext &b, const double entry, const double sl)
  {
   return BrokerCalcLot(b, c.riskPercent, MathAbs(entry - sl) / b.adjustedPoint,
                        LOT_BY_TICK_VALUE, c.maxRiskOvershoot);
  }

// Пропуск из-за риска: отдельно считаем случаи, когда счёт уже просел вдвое.
void ZoneOrdersRiskSkip(ZoneOrders &s, const ZoneOrdersConfig &c, const int slot,
                        const FiboZone &z, const double entry, const double sl)
  {
   if(AccountInfoDouble(ACCOUNT_BALANCE) < 0.5 * s.startBalance)
     {
      s.cntRiskLow[slot]++;
      return;
     }
   s.cntRisk[slot]++;
   PrintFormat("⏭ Зона %s пропущена: стоп %.2f USD — мин. лот рискует > %.1f%% баланса",
               z.name, MathAbs(entry - sl), c.riskPercent * c.maxRiskOvershoot);
  }

//+------------------------------------------------------------------+
//| Лимитки                                                          |
//+------------------------------------------------------------------+

// Выставить лимитку зоны или привести существующую к нужным цене / стопу / тейку.
void ZoneOrdersEnsureLimit(ZoneOrders &s, CTrade &tr, const BrokerContext &b, const ZoneOrdersConfig &c,
                           const int slot, const FiboZone &z, const int rangeId)
  {
   const double entry = NormalizeDouble(z.nearP, _Digits);
   bool widened;
   const double sl  = ZoneOrdersSL(c, b, z, entry, z.farP, widened);
   const double tp  = NormalizeDouble(z.tp, _Digits);
   const double lot = ZoneOrdersLot(c, b, entry, sl);
   if(lot <= 0.0)
     {
      s.used[slot] = true;
      ZoneOrdersRiskSkip(s, c, slot, z, entry, sl);
      ZoneOrdersDelete(s, tr, slot);
      return;
     }

   if(s.ticket[slot] != 0)
     {
      if(!OrderSelect(s.ticket[slot]))
         return;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - entry) < _Point &&
         MathAbs(OrderGetDouble(ORDER_SL) - sl) < _Point &&
         MathAbs(OrderGetDouble(ORDER_TP) - tp) < _Point)
         return;
      // Объём ордера не меняется — при другом лоте ордер выставляется заново.
      if(MathAbs(OrderGetDouble(ORDER_VOLUME_INITIAL) - lot) > 1e-8)
        {
         ZoneOrdersDelete(s, tr, slot);
         return;
        }
      if(tr.OrderModify(s.ticket[slot], entry, sl, tp, ORDER_TIME_GTC, 0))
        {
         s.cntMoved[slot]++;
         if(widened)
            s.cntWidened[slot]++;
        }
      else
         ZoneOrdersDelete(s, tr, slot);   // не сдвинулась (например, цена слишком близко) — выставим заново
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (z.dir == 1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = tp;
   req.lot             = lot;
   req.comment         = StringFormat("%s_%d #%d", c.commentPrefix, slot, rangeId);
   req.maxSpreadToSL   = c.maxSpreadToSL;
   req.maxSlippageToSL = c.maxSlippageToSL;

   const TradeResult res = TradeExecutorSend(tr, b, req);
   if(!res.success)
     {
      if(!res.skipped && ZoneOrdersPermanentReject(res.retcode))
        {
         s.used[slot] = true;
         PrintFormat("❌ Лимитка зоны %s не выставлена: %u %s", z.name, res.retcode, res.description);
        }
      return;   // временный отказ или фильтр — повторим на следующих тиках
     }
   s.cntPlaced[slot]++;
   if(widened)
      s.cntWidened[slot]++;
   // Лимитка могла сразу исполниться по рынку (цена ушла за уровень) — тогда тикета ордера нет.
   if(req.orderType == ORDER_TYPE_BUY || req.orderType == ORDER_TYPE_SELL)
     {
      s.used[slot] = true;
      s.cntFilled[slot]++;
     }
   else
      s.ticket[slot] = res.ticket;
   PrintFormat("📌 %s зона %s | вход %.3f SL %.3f (%.2f USD) TP %.3f | диапазон #%d",
               z.dir == 1 ? "BUY LIMIT" : "SELL LIMIT", z.name, entry, sl, MathAbs(entry - sl),
               tp, rangeId);
  }

//+------------------------------------------------------------------+
//| ZoneOrdersManageLimits — лимитки по зонам zs[] (ok[i] — зона i   |
//| есть). Держим ордер только у ближайшей к цене зоны в каждом      |
//| направлении: дальняя зона того же направления исполнится лишь    |
//| после ближней, а лишние ордера — это лишние запросы к брокеру и  |
//| риск двух сделок сразу.                                          |
//+------------------------------------------------------------------+
void ZoneOrdersManageLimits(ZoneOrders &s, CTrade &tr, const BrokerContext &b, const ZoneOrdersConfig &c,
                            const FiboZone &zs[], const bool &ok[], const int rangeId)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool   want[ZONE_ORDERS_MAX_SLOTS];
   int    bestBuy = -1, bestSell = -1;
   double dBuy = DBL_MAX, dSell = DBL_MAX;

   for(int i = 0; i < s.n; i++)
     {
      want[i] = false;
      if(s.ticket[i] != 0 && !PositionGuardPendingExists(s.ticket[i]))
        {
         s.ticket[i] = 0;   // исполнена
         s.used[i]   = true;
         s.cntFilled[i]++;
         continue;
        }
      if(s.used[i] || !ok[i])
        {
         ZoneOrdersDelete(s, tr, i);
         continue;
        }
      const double entry = NormalizeDouble(zs[i].nearP, _Digits);
      // Цена уже на зоне или за ней: без ордера — зону пропускаем, с ордером — он исполняется.
      if((zs[i].dir == 1 && ask <= entry) || (zs[i].dir == -1 && bid >= entry))
        {
         if(s.ticket[i] == 0)
           {
            s.used[i] = true;
            s.cntPassed[i]++;
           }
         continue;
        }
      want[i] = true;
      const double d = (zs[i].dir == 1) ? ask - entry : entry - bid;
      if(zs[i].dir == 1 && d < dBuy)   { dBuy = d;  bestBuy = i; }
      if(zs[i].dir == -1 && d < dSell) { dSell = d; bestSell = i; }
     }

   for(int i = 0; i < s.n; i++)
     {
      if(!want[i])
         continue;
      if(i == bestBuy || i == bestSell)
         ZoneOrdersEnsureLimit(s, tr, b, c, i, zs[i], rangeId);
      else
         ZoneOrdersDelete(s, tr, i);
     }
  }

//+------------------------------------------------------------------+
//| ZoneOrdersConfirm — вход по подтверждению на закрытом баре c.tf: |
//| касание зоны, затем закрытие бара обратно из неё → вход по       |
//| рынку; стоп — за дальним краем зоны или экстремумом касания.     |
//| Вызывать на новом баре. canEnter = false — открыта сделка.       |
//+------------------------------------------------------------------+
void ZoneOrdersConfirmSlot(ZoneOrders &s, CTrade &tr, const BrokerContext &b, const ZoneOrdersConfig &c,
                           const int slot, const FiboZone &z, const bool canEnter, const int rangeId)
  {
   const double h1 = iHigh(_Symbol, c.tf, 1);
   const double l1 = iLow(_Symbol, c.tf, 1);
   const double c1 = iClose(_Symbol, c.tf, 1);

   if(z.dir == -1 ? (h1 >= z.nearP) : (l1 <= z.nearP))
     {
      if(!s.touched[slot])
         s.touchExt[slot] = (z.dir == -1) ? h1 : l1;
      s.touched[slot]  = true;
      s.touchExt[slot] = (z.dir == -1) ? MathMax(s.touchExt[slot], h1) : MathMin(s.touchExt[slot], l1);
     }
   if(!s.touched[slot])
      return;
   if(z.dir == -1 ? (c1 >= z.nearP) : (c1 <= z.nearP))
      return;   // бар ещё не закрылся обратно из зоны
   if(!canEnter)
     {
      s.touched[slot] = false;   // подтверждение пришлось на открытую сделку — ждём нового касания
      return;
     }

   const double farP = (z.dir == -1) ? MathMax(z.farP, s.touchExt[slot]) : MathMin(z.farP, s.touchExt[slot]);
   ZoneOrdersEnterMarket(s, tr, b, c, slot, z, farP, rangeId, "подтверждению");
  }

//+------------------------------------------------------------------+
//| ZoneOrdersEnterMarket — вход по рынку от зоны: стоп за точкой    |
//| farP (дальний край зоны или экстремум касания) + отступ, цель —  |
//| z.tp. Зона помечается отработанной. reason — для журнала         |
//| («подтверждению», «свече CRT» …).                                |
//+------------------------------------------------------------------+
void ZoneOrdersEnterMarket(ZoneOrders &s, CTrade &tr, const BrokerContext &b, const ZoneOrdersConfig &c,
                           const int slot, const FiboZone &z, const double farP, const int rangeId,
                           const string reason)
  {
   const double entry = (z.dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool widened;
   const double sl    = ZoneOrdersSL(c, b, z, entry, farP, widened);
   const double lot   = ZoneOrdersLot(c, b, entry, sl);
   s.used[slot] = true;
   if(lot <= 0.0)
     {
      ZoneOrdersRiskSkip(s, c, slot, z, entry, sl);
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (z.dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = NormalizeDouble(z.tp, _Digits);
   req.lot             = lot;
   req.comment         = StringFormat("%s_%d #%d", c.commentPrefix, slot, rangeId);
   req.maxSpreadToSL   = c.maxSpreadToSL;
   req.maxSlippageToSL = c.maxSlippageToSL;

   const TradeResult res = TradeExecutorSend(tr, b, req);
   if(res.success)
     {
      s.cntPlaced[slot]++;
      s.cntFilled[slot]++;
      if(widened)
         s.cntWidened[slot]++;
      PrintFormat("✅ %s по %s, зона %s | SL %.3f (%.2f USD) TP %.3f | диапазон #%d",
                  z.dir == 1 ? "BUY" : "SELL", reason, z.name, sl, MathAbs(entry - sl), req.tp, rangeId);
     }
   else if(!res.skipped)
      PrintFormat("❌ Вход в зоне %s не удался: %u %s", z.name, res.retcode, res.description);
  }

void ZoneOrdersConfirm(ZoneOrders &s, CTrade &tr, const BrokerContext &b, const ZoneOrdersConfig &c,
                       const FiboZone &zs[], const bool &ok[], const bool canEnter, const int rangeId)
  {
   for(int i = 0; i < s.n; i++)
      if(!s.used[i] && ok[i])
         ZoneOrdersConfirmSlot(s, tr, b, c, i, zs[i], canEnter, rangeId);
  }

// Итог по слоту для журнала в OnDeinit.
void ZoneOrdersPrintSlot(const ZoneOrders &s, const int i, const string name)
  {
   PrintFormat("📊 Зона %s: выставлений %d | сдвигов %d | исполнено %d | цена уже за зоной %d | "
               "стоп велик %d (+%d при балансе < 50%%) | стоп расширен до мин. %d",
               name, s.cntPlaced[i], s.cntMoved[i], s.cntFilled[i], s.cntPassed[i],
               s.cntRisk[i], s.cntRiskLow[i], s.cntWidened[i]);
  }

void ZoneOrdersPrintTotals(const ZoneOrders &s)
  {
   PrintFormat("📊 Удалено лимиток вне учёта: %d | закрыто лишних позиций: %d", s.cntOrphans, s.cntExtraPos);
  }

#endif // ZONEORDERS_MQH
//+------------------------------------------------------------------+
