//+------------------------------------------------------------------+
//|                                                 crt-bot_v4.2.mq5 |
//|  CRT Trade Bot v4.2: TrueRB, InsideWick, ghostTrueRB,            |
//|  ghostInsideWick | 3 режима входа | EMA/ADX фильтр               |
//+------------------------------------------------------------------+
#property strict
#property description "CRT Trade Bot v4.2 | TrueRB, InsideWick, ghostTrueRB, ghostInsideWick | 3 режима входа | EMA/ADX фильтр"

#include <Trade\Trade.mqh>
#include "Include/TradeAdapter.mqh"
#include "Include/BrokerAdapter.mqh"
#include "Include/SessionFilter.mqh"
#include "Include/TrendFilter.mqh"
#include "Include/PositionGuard.mqh"
#include "Include/TradeExecutor.mqh"
#include "Include/Trailing/SyncTrail.mqh"
#include "Include/Trailing/BreakevenTrail.mqh"
#include "Include/Trailing/TrailingDispatcher.mqh"
#include "Include/CrtDetector.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;

// Per-ticket состояние SyncTrailing (ключ — state.ticket, поиск линейный).
SyncTrailState g_sync_states[];

//+------------------------------------------------------------------+
//| Enum: режим входа                                                |
//+------------------------------------------------------------------+

enum ENUM_ENTRY_MODE
{
   ENTRY_SWEEP_RECLAIM = 0,  // Sweep + Reclaim   (двухфазное подтверждение)
   ENTRY_MARKET        = 1,  // Рыночный вход      (касание уровня → сразу открыть)
   ENTRY_LIMIT         = 2   // Лимитный ордер     (BUY/SELL LIMIT на уровне)
};

//+------------------------------------------------------------------+
//| Входные параметры                                                |
//+------------------------------------------------------------------+

input group "── Анализ CRT ──"
input double ImbBodyRatio        = 0.40;
input double DojiThreshold       = 0.35;
input double DojiToImbSizeRatio  = 0.40;
input double DojiToImbRangeRatio = 1.00;
input double OpenTolerance       = 0.01;
input double BareImbWickTolerance = 0.05;

input group "── Паттерны (классика — с пробоем) ──"
input bool   TradeTrueRB        = true;
input bool   TradeInsideWick    = true;
input bool   TradeBareImbalance = true;

input group "── Паттерны (ghost — без пробоя) ──"
input bool   TradeGhostTrueRB     = true;
input bool   TradeGhostInsideWick = true;

input group "── Точка входа InsideWick ──"
enum ENUM_IW_ENTRY_MODE
{
   IW_ENTRY_IMB_EXTREME = 0,
   IW_ENTRY_RB_LINE     = 1
};
input ENUM_IW_ENTRY_MODE InsideWickEntryMode = IW_ENTRY_IMB_EXTREME;

input group "── Режим входа ──"
input ENUM_ENTRY_MODE EntryMode   = ENTRY_SWEEP_RECLAIM;
// ↑ SWEEP_RECLAIM — Sweep за уровень, затем Reclaim обратно
// ↑ MARKET        — открыть по рынку при первом касании уровня
// ↑ LIMIT         — разместить BUY/SELL LIMIT сразу после сигнала

input group "── Ожидание входа ──"
input int MaxBarsToWait = 2;   // Макс. баров до отмены сигнала/ордера (0 = без ограничения)

input group "── Управление капиталом ──"
input int    MagicNumber  = 71002;   // Магический номер (уникальный для каждого бота)
input double RiskPercent  = 3.0;
input double MaxRiskOvershoot = 1.5;  // Пропуск сделки, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL   = 0.10; // Макс. спред как доля расстояния до SL (0.10 = 10%; 0 = выкл)
input double MaxSlippageToSL = 0.10; // Макс. проскальзывание как доля расстояния до SL (0 = без ограничения)

input group "── Параметры входа ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M1;

input group "── Stop Loss ──"
input double BufferPips = 200;
input double MinSLPips  = 1525;
input double MaxSLPips  = 3175;

input group "── Трейлинг ──"
input ENUM_TRAILING_MODE TrailingMode          = TRAILING_OFF;
input double             TrailingStartFactor   = 0.5;
input double             BreakevenOffsetPoints = 175;
input double             SyncTrailStepPoints   = 0;

input group "── Сессионный фильтр ──"
input bool UseSessionFilter     = true;
input int  AmericanCloseHour    = 21;
input int  AmericanCloseMinute  = 0;
input int  AsianOpenHour        = 0;
input int  AsianOpenMinute      = 0;
input int  SessionWindowMinutes = 1;

input group "── Selected Sessions Filter ──"
// Опциональный фильтр выбора торговых сессий (Asian/London/NewYork) в
// UTC-координатах. При UseSelectedSessions=false работает только
// legacy Session Filter.
input bool          UseSelectedSessions         = true; // Включить выбор сессий
input bool          UseAsianSession             = false; // Торговать в Asian
input bool          UseLondonSession            = true; // Торговать в London
input bool          UseNewYorkSession           = false; // Торговать в NewYork

input int           AsianStartHour              = 0;   // Asian start UTC [0,23]
input int           AsianStartMinute            = 0;   // Asian start UTC [0,59]
input int           AsianEndHour                = 9;   // Asian end   UTC [0,23]
input int           AsianEndMinute              = 0;   // Asian end   UTC [0,59]

input int           LondonStartHour             = 7;   // London start UTC [0,23]
input int           LondonStartMinute           = 0;   // London start UTC [0,59]
input int           LondonEndHour               = 16;  // London end   UTC [0,23]
input int           LondonEndMinute             = 0;   // London end   UTC [0,59]

input int           NYStartHour                 = 12;  // NewYork start UTC [0,23]
input int           NYStartMinute               = 0;   // NewYork start UTC [0,59]
input int           NYEndHour                   = 21;  // NewYork end   UTC [0,23]
input int           NYEndMinute                 = 0;   // NewYork end   UTC [0,59]

input int           SessionGmtOffsetHours       = 0;        // GMT offset, ч [-12,14]
input ENUM_DST_MODE SessionDstMode              = DST_AUTO; // Режим DST

input bool          CloseOnSessionExit          = true; // Закрывать позиции на выходе
input bool          UseBrokerSessionsAsFallback = false; // Брокерские сессии как fallback

input group "── Фильтр тренда (HTF) ──"
input bool            UseTrendFilter = true;
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_M15;
input int             TrendFastEMA   = 50;
input int             TrendSlowEMA   = 200;

input group "── ADX фильтр (опционально) ──"
input bool   UseADXFilter = false;
input int    ADXPeriod    = 14;
input double ADXMin       = 20.0;

//+------------------------------------------------------------------+
//| Структура ожидающего сигнала                                     |
//+------------------------------------------------------------------+

struct PendingSignal
{
   bool     active;
   string   patternName;
   int      imbDir;         // 1 = bull IMB → SELL, -1 = bear IMB → BUY
   double   entryLevel;
   double   sl;
   double   tp;
   bool     isFVG;
   bool     swept;          // только для SWEEP_RECLAIM: фаза 1 пройдена
   datetime expireTime;     // 0 = без ограничения
   ulong    limitTicket;    // только для ENTRY_LIMIT: тикет лимитного ордера

   void Reset()
   {
      active      = false;
      swept       = false;
      expireTime  = 0;
      patternName = "";
      entryLevel  = 0.0;
      sl          = 0.0;
      tp          = 0.0;
      isFVG       = false;
      imbDir      = 0;
      limitTicket = 0;
   }
};

//+------------------------------------------------------------------+
//| Глобальные переменные                                            |
//+------------------------------------------------------------------+

BrokerContext g_broker;
SessionConfig g_session_cfg;
SessionState  g_session_state;

//── Selected Sessions Filter (новый API, ортогонален legacy SessionFilter) ──
SelectedSessionsConfig g_selected_cfg;
SelectedSessionsState  g_selected_state;

datetime      g_last_signal_doji = 0;
PendingSignal g_pending;

datetime      g_last_bar_time    = 0;
MqlRates      g_rates[];

//── Trend filter state ────────────────────────────────────────────
TrendConfig  g_trend_cfg;
TrendHandles g_trend_h;

//+------------------------------------------------------------------+
//| ДЕТЕКЦИЯ НОВОГО БАРА                                             |
//+------------------------------------------------------------------+

// note: TrendIsAllowed возвращает чистое bool и не логирует отказы —
// решение о Print-трассировке принимает EA.

bool IsNewBar()
{
   datetime current_bar = iTime(_Symbol, TradingTimeframe, 0);
   if(current_bar == 0 || current_bar == g_last_bar_time)
      return false;

   if(CopyRates(_Symbol, TradingTimeframe, 0, 4, g_rates) < 4)
   {
      Print("⚠️ CopyRates failed в IsNewBar()");
      return false;
   }

   if(g_rates[1].tick_volume == 0)
      return false;

   g_last_bar_time = current_bar;
   return true;
}

//+------------------------------------------------------------------+
//| УПРАВЛЕНИЕ ЛИМИТНЫМИ ОРДЕРАМИ                                    |
//+------------------------------------------------------------------+

void CancelLimitOrder()
{
   if(g_pending.limitTicket == 0) return;
   if(!PositionGuardPendingExists(g_pending.limitTicket))
   {
      g_pending.limitTicket = 0;
      return;
   }
   if(trade.OrderDelete(g_pending.limitTicket))
      PrintFormat("🚫 Лимитный ордер #%I64u отменён", g_pending.limitTicket);
   else
      PrintFormat("❌ Ошибка отмены ордера #%I64u: %d | %s",
                  g_pending.limitTicket, trade.ResultRetcode(), trade.ResultComment());
   g_pending.limitTicket = 0;
}

void CloseAllOpenPositions()
{
   Print("🔒 Закрытие позиций перед границей сессии");

   // EA-prelude: сброс паттерна и отмена единичного лимита (модуль про g_pending не знает).
   if(g_pending.active)
   {
      if(EntryMode == ENTRY_LIMIT && g_pending.limitTicket != 0)
         CancelLimitOrder();
      PrintFormat("🚫 Pending [%s] отменён (граница сессии)", g_pending.patternName);
      g_pending.Reset();
   }

   PositionGuardCloseAll(trade, MagicNumber);
}

//+------------------------------------------------------------------+
//| HandleSessionExitClose — Session_Exit_Event для Selected Sessions|
//|                                                                  |
//| Вызывается из OnTick prelude ровно один раз на                   |
//| переход inside→outside, когда CloseOnSessionExit = true.         |
//| Edge-trigger гарантируется SelectedSessionsDetectExit.           |
//|                                                                  |
//| 1) PositionGuardCloseAll(trade, MagicNumber)                     |
//| 2) PositionGuardCancelAllPending(trade, MagicNumber)             |
//| 3) g_pending.Reset() — сбрасывает active/swept/limitTicket и     |
//|    прочие поля EA-pending.                                       |
//| 4) Один Print с UTC-временем выхода + counts.                    |
//+------------------------------------------------------------------+
void HandleSessionExitClose()
{
   const int closed    = PositionGuardCloseAll(trade, MagicNumber);
   const int cancelled = PositionGuardCancelAllPending(trade, MagicNumber);

   // EA-pending reset: сбрасываем g_pending целиком (включая limitTicket),
   // pending-ордер уже отменён модулем PositionGuard выше.
   g_pending.Reset();

   // UTC-время выхода: берём из state, обновлённого DetectExit на текущем
   // тике (lastEvaluatedUtcSec — секунды суток UTC, [0, 86399]).
   const long utcSec = g_selected_state.lastEvaluatedUtcSec;
   const int  hh     = (int)(utcSec / 3600);
   const int  mm     = (int)((utcSec % 3600) / 60);
   const int  ss     = (int)(utcSec % 60);

   PrintFormat("⏰ Session exit @ %02d:%02d:%02d UTC | closed=%d | cancelled=%d",
               hh, mm, ss, closed, cancelled);
}

//+------------------------------------------------------------------+
//| ОТКРЫТИЕ РЫНОЧНОГО ОРДЕРА                                        |
//+------------------------------------------------------------------+

void OpenCRTTrade(ENUM_ORDER_TYPE orderType, double entry, double sl, double tp,
                  const string label)
{
   // Пересчёт TP с сохранением implicit-RR при подтяжке SL до мин. дистанции
   // (caller-side; TradeExecutorSend повторно вызовет BrokerEnforceMinSLDist — идемпотентно).
   const double sl_dist_old = MathAbs(entry - sl);
   const double tp_dist_old = MathAbs(entry - tp);
   const double rr_old      = (sl_dist_old > 0.0) ? tp_dist_old / sl_dist_old : 0.0;

   double sl_predicted = sl;
   BrokerEnforceMinSLDist(g_broker, orderType, entry, sl_predicted);
   if(MathAbs(entry - sl_predicted) > sl_dist_old && rr_old > 0.0)
   {
      const int tp_sign = (tp > entry) ? +1 : ((tp < entry) ? -1 : 0);
      tp = entry + (double)tp_sign * MathAbs(entry - sl_predicted) * rr_old;
      sl = sl_predicted;
      PrintFormat("⚠️ SL→min: %.5f | TP→RR=%.2f: %.5f", sl, rr_old, tp);
   }

   // Лот от расстояния до SL: риск сделки = RiskPercent от баланса.
   const double lot = BrokerCalcLot(g_broker, RiskPercent,
                                    MathAbs(entry - sl) / g_broker.adjustedPoint,
                                    LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(lot <= 0.0) return;   // минимальный лот слишком рискованный — причина уже в журнале

   const string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   TradeOrderRequest req;
   req.orderType = orderType;
   req.price     = entry;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = lot;
   req.comment   = StringFormat("CRT_%s_%s TF:%s", label, dir, EnumToString(TradingTimeframe));
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   TradeResult result = TradeExecutorSend(trade, g_broker, req);

   if(result.success)
   {
      // HUD на стороне EA (используем нормализованные req.* для корректного RR после клампа SL).
      const double sl_pts = (g_broker.adjustedPoint > 0.0)
                            ? MathAbs(req.price - req.sl) / g_broker.adjustedPoint
                            : 0.0;
      const double tp_pts = (g_broker.adjustedPoint > 0.0)
                            ? MathAbs(req.tp - req.price) / g_broker.adjustedPoint
                            : 0.0;
      const double rr     = (sl_pts > 0.0) ? tp_pts / sl_pts : 0.0;
      Comment(StringFormat("CRT Bot | %s %s | SL: %.0f pts | TP: %.0f pts | RR: %.2f",
                           label, dir, sl_pts, tp_pts, rr));
   }
   else if(!result.skipped)   // пропуск по фильтру модуль уже записал в журнал
   {
      PrintFormat("❌ Ошибка открытия [%s]: %u | %s",
                  label, result.retcode, result.description);
   }
}

//+------------------------------------------------------------------+
//| РАЗМЕЩЕНИЕ ЛИМИТНОГО ОРДЕРА (ENTRY_LIMIT)                        |
//+------------------------------------------------------------------+

void PlaceCRTLimitOrder(ENUM_ORDER_TYPE orderType, double price,
                        double sl, double tp, const string label)
{
   // Тот же TP-пересчёт, что в OpenCRTTrade (см. там).
   const double sl_dist_old = MathAbs(price - sl);
   const double tp_dist_old = MathAbs(price - tp);
   const double rr_old      = (sl_dist_old > 0.0) ? tp_dist_old / sl_dist_old : 0.0;

   double sl_predicted = sl;
   BrokerEnforceMinSLDist(g_broker, orderType, price, sl_predicted);
   if(MathAbs(price - sl_predicted) > sl_dist_old && rr_old > 0.0)
   {
      const int tp_sign = (tp > price) ? +1 : ((tp < price) ? -1 : 0);
      tp = price + (double)tp_sign * MathAbs(price - sl_predicted) * rr_old;
      sl = sl_predicted;
      PrintFormat("⚠️ SL→min: %.5f | TP→RR=%.2f: %.5f", sl, rr_old, tp);
   }

   // Fallback limit→market выполняется внутри TradeExecutorSend; детектируем по сравнению originalType ↔ req.orderType.
   // Лот от расстояния до SL: риск сделки = RiskPercent от баланса.
   const double lot = BrokerCalcLot(g_broker, RiskPercent,
                                    MathAbs(price - sl) / g_broker.adjustedPoint,
                                    LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(lot <= 0.0)
   {
      g_pending.Reset();   // минимальный лот слишком рискованный — сигнал отбрасываем
      return;
   }

   const ENUM_ORDER_TYPE originalType = orderType;
   const string dir = (orderType == ORDER_TYPE_BUY_LIMIT ? "BUY LIMIT" : "SELL LIMIT");

   TradeOrderRequest req;
   req.orderType = orderType;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = lot;
   req.comment   = StringFormat("CRT_%s TF:%s", label, EnumToString(TradingTimeframe));

   TradeResult result = TradeExecutorSend(trade, g_broker, req);

   if(result.success)
   {
      const double sl_pts = (g_broker.adjustedPoint > 0.0)
                            ? MathAbs(req.price - req.sl) / g_broker.adjustedPoint
                            : 0.0;
      const double tp_pts = (g_broker.adjustedPoint > 0.0)
                            ? MathAbs(req.tp - req.price) / g_broker.adjustedPoint
                            : 0.0;
      const double rr     = (sl_pts > 0.0) ? tp_pts / sl_pts : 0.0;

      // Если модуль переключил лимит на market — pending-ордера нет, ведём себя как при market-входе.
      const bool switched_to_market =
         (originalType == ORDER_TYPE_BUY_LIMIT  && req.orderType == ORDER_TYPE_BUY)  ||
         (originalType == ORDER_TYPE_SELL_LIMIT && req.orderType == ORDER_TYPE_SELL);

      if(switched_to_market)
      {
         g_pending.limitTicket = 0;
         g_pending.Reset();
         const string marketDir = (req.orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
         Comment(StringFormat("CRT Bot | %s %s | SL: %.0f pts | TP: %.0f pts | RR: %.2f",
                              label, marketDir, sl_pts, tp_pts, rr));
      }
      else
      {
         g_pending.limitTicket = result.ticket;
         Comment(StringFormat("CRT Bot | %s [%s] | Price:%.5f | SL:%.0f pts | TP:%.0f pts | RR:%.2f",
                              dir, label, req.price, sl_pts, tp_pts, rr));
      }
   }
   else
   {
      PrintFormat("❌ Ошибка %s [%s]: %u | %s",
                  dir, label, result.retcode, result.description);
      g_pending.Reset();
   }
}

//+------------------------------------------------------------------+
//| ТРЕЙЛИНГ — диспетчер по TrailingMode                             |
//| OFF/BREAKEVEN через модульный TrailingManage; SYNC пока в EA     |
//| (модуль SyncTrail не экспортирует state-машину).                 |
//+------------------------------------------------------------------+

void ManageTrailing()
{
   switch(TrailingMode)
   {
      case TRAILING_OFF:
      {
         TrailingConfig cfg;
         cfg.mode            = TRAILING_OFF_EX;
         cfg.startFactor     = 0.0;
         cfg.breakevenOffset = 0.0;
         cfg.trailStep       = 0.0;
         TrailingManage(g_trade_adapter, g_broker, MagicNumber, cfg);
         return;
      }
      case TRAILING_BREAKEVEN:
      {
         TrailingConfig cfg;
         cfg.mode            = TRAILING_BREAKEVEN_EX;
         cfg.startFactor     = TrailingStartFactor;
         cfg.breakevenOffset = BreakevenOffsetPoints;
         cfg.trailStep       = 0.0;
         TrailingManage(g_trade_adapter, g_broker, MagicNumber, cfg);
         return;
      }
      case TRAILING_SYNC:
         ManageSyncTrailing();
         return;
   }
}

//+------------------------------------------------------------------+
//| ТРЕЙЛИНГ — синхронный блок SL/TP                                 |
//+------------------------------------------------------------------+

// Удалить осиротевшие записи (тикет закрыт или не принадлежит боту).
// Вызывается в начале каждого ManageSyncTrailing.
void GcSyncState()
{
   const int n = ArraySize(g_sync_states);
   // Идём с конца, чтобы удаление через ArrayRemove не сбило индексы.
   for(int i = n - 1; i >= 0; i--)
   {
      const ulong ticket = g_sync_states[i].ticket;
      bool alive = PositionSelectByTicket(ticket);
      if(alive && PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         alive = false;
      if(!alive)
         ArrayRemove(g_sync_states, i, 1);
   }
}

//+------------------------------------------------------------------+
//| Найти/создать состояние SyncTrail по тикету. Возвращает индекс   |
//| в g_sync_states[]. Поля initialSL/openPrice/dir фиксируются      |
//| только при создании (block invariants).                          |
//+------------------------------------------------------------------+
int FindOrCreateState(const ulong  ticket,
                      const int    dir,
                      const double openPrice,
                      const double currentSL)
{
   const int n = ArraySize(g_sync_states);
   for(int i = 0; i < n; i++)
      if(g_sync_states[i].ticket == ticket)
         return i;

   const int newIdx = n;
   ArrayResize(g_sync_states, n + 1);
   g_sync_states[newIdx].ticket              = ticket;
   g_sync_states[newIdx].dir                 = dir;
   g_sync_states[newIdx].openPrice           = openPrice;
   g_sync_states[newIdx].initialSL           = currentSL;
   g_sync_states[newIdx].activated           = false;
   g_sync_states[newIdx].blockSize           = 0.0;
   g_sync_states[newIdx].lastSL              = 0.0;
   g_sync_states[newIdx].modificationSkipped = false;
   g_sync_states[newIdx].warnedNoStops       = false;
   return newIdx;
}

void ManageSyncTrailing()
{
   GcSyncState();

   const double point             = g_broker.adjustedPoint;
   const double minBrokerDistance = g_broker.minBrokerDistance;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                    continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)  != MagicNumber) continue;

      const ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const int    dir       = (ptype == POSITION_TYPE_BUY) ? 1 : -1;
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double currentSL = PositionGetDouble(POSITION_SL);
      const double currentTP = PositionGetDouble(POSITION_TP);
      const double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      const int sIdx = FindOrCreateState(ticket, dir, openPrice, currentSL);

      // Позиция без стопов — активация невозможна; лог один раз.
      if(currentSL == 0.0 || currentTP == 0.0)
      {
         if(!g_sync_states[sIdx].warnedNoStops)
         {
            PrintFormat("⚠️  SyncTrail #%I64u: нет SL/TP, активация пропущена", ticket);
            g_sync_states[sIdx].warnedNoStops = true;
         }
         continue;
      }

      // Активация трейлинга по достижении порога TrailingStartFactor.
      if(!g_sync_states[sIdx].activated)
      {
         const double profitPts = (dir == 1)
                                  ? (bid - openPrice) / point
                                  : (openPrice - ask) / point;
         const double slDistPts = MathAbs(openPrice - g_sync_states[sIdx].initialSL) / point;
         const double threshold = slDistPts * TrailingStartFactor;

         if(profitPts < threshold)
            continue;

         g_sync_states[sIdx].activated = true;
         g_sync_states[sIdx].blockSize = MathAbs(currentTP - currentSL);

         const double blockPts = g_sync_states[sIdx].blockSize / point;
         PrintFormat("🟢 SyncTrail #%I64u %s: активирован | open=%.5f initSL=%.5f initTP=%.5f "
                     "block=%.1f profit=%.1f thr=%.1f",
                     ticket, (dir == 1 ? "BUY" : "SELL"),
                     openPrice, g_sync_states[sIdx].initialSL, currentTP,
                     blockPts, profitPts, threshold);
      }

      double cand = ComputeCandidateSL(dir, bid, ask, openPrice, g_sync_states[sIdx].initialSL);
      cand = ClampToBreakeven(dir, cand, openPrice);

      // Строгое улучшение SL
      if(!IsStrictImprovement(dir, cand, currentSL))
      {
         g_sync_states[sIdx].modificationSkipped = false;
         continue;
      }

      // Шаговый порог (при SyncTrailStepPoints==0 всегда true)
      if(!ImprovementMeetsStep(dir, cand, currentSL, point, SyncTrailStepPoints))
      {
         g_sync_states[sIdx].modificationSkipped = false;
         continue;
      }

      const double newSL = NormalizeDouble(cand, _Digits);
      const double newTP = NormalizeDouble(ComputeNewTP(dir, newSL, g_sync_states[sIdx].blockSize), _Digits);

      // Проверка брокерской дистанции с анти-спамом
      if(!BrokerDistanceOk(dir, bid, ask, newSL, newTP, minBrokerDistance))
      {
         if(!g_sync_states[sIdx].modificationSkipped)
         {
            PrintFormat("⏸️ SyncTrail #%I64u: отложено (MinBrokerDistance) | candSL=%.5f newTP=%.5f bid=%.5f ask=%.5f minDist=%.5f",
                        ticket, newSL, newTP, bid, ask, minBrokerDistance);
            g_sync_states[sIdx].modificationSkipped = true;
         }
         continue;
      }

      if(!g_trade_adapter.PositionModify(ticket, newSL, newTP))
      {
         // Гонка: позиция могла закрыться между селектом и модификацией.
         if(!PositionSelectByTicket(ticket))
            continue;
         PrintFormat("❌ SyncTrail #%I64u: PositionModify rc=%u (%s) newSL=%.5f newTP=%.5f",
                     ticket, g_trade_adapter.ResultRetcode(),
                     g_trade_adapter.ResultComment(), newSL, newTP);
         continue;
      }

      const double prevSL  = (g_sync_states[sIdx].lastSL == 0.0)
                             ? g_sync_states[sIdx].initialSL
                             : g_sync_states[sIdx].lastSL;
      const double deltaPts = MathAbs(newSL - prevSL) / point;
      PrintFormat("📈 SyncTrail #%I64u %s: SL→%.5f TP→%.5f Δ=%.1f pts",
                  ticket, (dir == 1 ? "BUY" : "SELL"), newSL, newTP, deltaPts);
      g_sync_states[sIdx].lastSL              = newSL;
      g_sync_states[sIdx].modificationSkipped = false;
   }
}

//+------------------------------------------------------------------+
//| РАСЧЁТ ТОЧКИ ВХОДА                                               |
//+------------------------------------------------------------------+

double CalcEntryPrice(const MqlRates &imb, const MqlRates &doji,
                      const int imbDir, const string patternName)
{
   if(patternName == "ghostTrueRB" || patternName == "ghostInsideWick")
      return (imbDir == 1) ? imb.high : imb.low;

   if(patternName == "TrueRB")
      return imb.close;

   if(patternName == "InsideWick")
   {
      if(InsideWickEntryMode == IW_ENTRY_IMB_EXTREME)
         return (imbDir == 1) ? imb.high : imb.low;
      else
         return doji.close;
   }

   return imb.close;
}

//+------------------------------------------------------------------+
//| РАСЧЁТ SL И TP                                                   |
//+------------------------------------------------------------------+

void CalcCRTLevels(const MqlRates &imb, const MqlRates &doji,
                   const int imbDir, const string patternName,
                   double &sl_out, double &tp_out)
{
   double point  = g_broker.adjustedPoint;
   double buffer = BufferPips * point;
   double entry  = CalcEntryPrice(imb, doji, imbDir, patternName);

   double imbBodyHi = MathMax(imb.open, imb.close);
   double imbBodyLo = MathMin(imb.open, imb.close);
   double imbMid    = (imbBodyHi + imbBodyLo) * 0.5;

   double dojiBodyHi      = MathMax(doji.open, doji.close);
   double dojiBodyLo      = MathMin(doji.open, doji.close);
   double dojiUpperShadow = doji.high - dojiBodyHi;
   double dojiLowerShadow = dojiBodyLo - doji.low;

   if(imbDir == 1)   // Bull IMB → SELL
   {
      double slRaw = MathMax(imb.high, doji.high) + buffer;
      slRaw = MathMax(slRaw, entry + MinSLPips * point);
      slRaw = MathMin(slRaw, entry + MaxSLPips * point);
      sl_out = slRaw;

      double tpCandidate;
      if(dojiLowerShadow > 0.0 && doji.low <= imbMid)
         tpCandidate = doji.low;
      else
         tpCandidate = imbBodyLo;

      double slDist = sl_out - entry;
      if(entry - tpCandidate < slDist)
         tpCandidate = entry - slDist;

      tp_out = tpCandidate;
   }
   else   // Bear IMB → BUY
   {
      double slRaw = MathMin(imb.low, doji.low) - buffer;
      slRaw = MathMin(slRaw, entry - MinSLPips * point);
      slRaw = MathMax(slRaw, entry - MaxSLPips * point);
      sl_out = slRaw;

      double tpCandidate;
      if(dojiUpperShadow > 0.0 && doji.high >= imbMid)
         tpCandidate = doji.high;
      else
         tpCandidate = imbBodyHi;

      double slDist = entry - sl_out;
      if(tpCandidate - entry < slDist)
         tpCandidate = entry + slDist;

      tp_out = tpCandidate;
   }
}

//+------------------------------------------------------------------+
//| УСТАНОВКА СИГНАЛА И ВЫБОР РЕЖИМА ВХОДА                           |
//+------------------------------------------------------------------+

void ProcessCRTSignal(const MqlRates &imb, const MqlRates &doji,
                      const int imbDir, const string patternName, const bool isFVG)
{
   double entry = CalcEntryPrice(imb, doji, imbDir, patternName);
   double sl = 0.0, tp = 0.0;
   CalcCRTLevels(imb, doji, imbDir, patternName, sl, tp);

   if(g_pending.active)
   {
      if(EntryMode == ENTRY_LIMIT && g_pending.limitTicket != 0)
         CancelLimitOrder();
      PrintFormat("♻️  Pending [%s] заменён новым [%s]", g_pending.patternName, patternName);
   }

   g_pending.active      = true;
   g_pending.patternName = patternName;
   g_pending.imbDir      = imbDir;
   g_pending.entryLevel  = entry;
   g_pending.sl          = sl;
   g_pending.tp          = tp;
   g_pending.isFVG       = isFVG;
   g_pending.swept       = false;
   g_pending.limitTicket = 0;

   if(MaxBarsToWait > 0)
      g_pending.expireTime = doji.time + (datetime)(MaxBarsToWait + 1) * PeriodSeconds(TradingTimeframe);
   else
      g_pending.expireTime = 0;

   g_last_signal_doji = doji.time;

   string dir    = (imbDir == 1) ? "SELL" : "BUY";
   double sl_pts = MathAbs(entry - sl) / g_broker.adjustedPoint;
   double tp_pts = MathAbs(tp - entry) / g_broker.adjustedPoint;
   double rr     = (sl_pts > 0.0) ? tp_pts / sl_pts : 0.0;
   string fvgTag = isFVG ? "+FVG" : "";
   string label  = patternName + fvgTag;

   if(EntryMode == ENTRY_LIMIT)
   {
      ENUM_ORDER_TYPE limitType = (imbDir == 1) ? ORDER_TYPE_SELL_LIMIT
                                                 : ORDER_TYPE_BUY_LIMIT;
      PlaceCRTLimitOrder(limitType, entry, sl, tp, label);
      return;
   }

   string modeStr = (EntryMode == ENTRY_MARKET) ? "MARKET" : "SWEEP+RECLAIM";

   PrintFormat("⏳ Pending %s [%s] Mode:%s | Level: %.5f | SL: %.0f pts | TP: %.0f pts | RR: %.2f | Exp: %s",
               dir, label, modeStr, entry, sl_pts, tp_pts, rr,
               MaxBarsToWait > 0 ? TimeToString(g_pending.expireTime, TIME_DATE|TIME_MINUTES) : "∞");

   Comment(StringFormat("⏳ Pending %s %s | Level: %.5f | SL: %.0f pts | TP: %.0f pts | RR: %.2f\n"
                        "Mode: %s",
                        label, dir, entry, sl_pts, tp_pts, rr, modeStr));
}

//+------------------------------------------------------------------+
//| ТИКОВАЯ ПРОВЕРКА ВХОДА ПО АКТИВНОМУ СИГНАЛУ                      |
//+------------------------------------------------------------------+

void CheckPendingEntry()
{
   if(!g_pending.active) return;

   if(EntryMode == ENTRY_LIMIT && g_pending.limitTicket != 0)
   {
      if(!PositionGuardPendingExists(g_pending.limitTicket))
      {
         g_pending.Reset();
         return;
      }
   }

   if(g_pending.expireTime > 0 && TimeTradeServer() > g_pending.expireTime)
   {
      PrintFormat("⌛ Pending [%s] отменён: таймаут (%d баров)", g_pending.patternName, MaxBarsToWait);
      if(EntryMode == ENTRY_LIMIT) CancelLimitOrder();
      g_pending.Reset();
      Comment("");
      return;
   }

   if(SessionIsBoundary(g_session_cfg, g_session_state))
   {
      PrintFormat("🚫 Pending [%s] отменён: граница сессии", g_pending.patternName);
      if(EntryMode == ENTRY_LIMIT) CancelLimitOrder();
      g_pending.Reset();
      Comment("");
      return;
   }

   ENUM_POSITION_TYPE dummy;
   if(PositionGuardHasOpen(MagicNumber, dummy))
   {
      if(EntryMode == ENTRY_LIMIT) CancelLimitOrder();
      g_pending.Reset();
      return;
   }

   if(EntryMode == ENTRY_LIMIT) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double level = g_pending.entryLevel;
   string label = g_pending.patternName + (g_pending.isFVG ? "+FVG" : "");

   if(EntryMode == ENTRY_MARKET)
   {
      if(g_pending.imbDir == 1)
      {
         if(bid >= level)
         {
            PrintFormat("✅ MARKET SELL: Bid=%.5f ≥ Level=%.5f → открываем [%s]", bid, level, label);
            OpenCRTTrade(ORDER_TYPE_SELL, bid, g_pending.sl, g_pending.tp, label);
            g_pending.Reset();
         }
      }
      else
      {
         if(ask <= level)
         {
            PrintFormat("✅ MARKET BUY: Ask=%.5f ≤ Level=%.5f → открываем [%s]", ask, level, label);
            OpenCRTTrade(ORDER_TYPE_BUY, ask, g_pending.sl, g_pending.tp, label);
            g_pending.Reset();
         }
      }
      return;
   }

   if(g_pending.imbDir == 1)
   {
      if(!g_pending.swept)
      {
         if(ask > level)
         {
            g_pending.swept = true;
            PrintFormat("📈 Sweep (SELL): Ask=%.5f > Level=%.5f [%s]", ask, level, label);
         }
      }
      else
      {
         if(bid < level)
         {
            PrintFormat("✅ Reclaim (SELL): Bid=%.5f < Level=%.5f → открываем [%s]", bid, level, label);
            OpenCRTTrade(ORDER_TYPE_SELL, bid, g_pending.sl, g_pending.tp, label);
            g_pending.Reset();
         }
      }
   }
   else
   {
      if(!g_pending.swept)
      {
         if(bid < level)
         {
            g_pending.swept = true;
            PrintFormat("📉 Sweep (BUY): Bid=%.5f < Level=%.5f [%s]", bid, level, label);
         }
      }
      else
      {
         if(ask > level)
         {
            PrintFormat("✅ Reclaim (BUY): Ask=%.5f > Level=%.5f → открываем [%s]", ask, level, label);
            OpenCRTTrade(ORDER_TYPE_BUY, ask, g_pending.sl, g_pending.tp, label);
            g_pending.Reset();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ОСНОВНАЯ ПРОВЕРКА CRT (баровая)                                  |
//+------------------------------------------------------------------+

void CheckCRTEntry()
{
   ENUM_POSITION_TYPE dummy;
   if(PositionGuardHasOpen(MagicNumber, dummy)) return;
   if(SessionIsBoundary(g_session_cfg, g_session_state)) return;

   MqlRates prev = g_rates[3];
   MqlRates imb  = g_rates[2];
   MqlRates doji = g_rates[1];

   if(doji.time == g_last_signal_doji) return;

   // Сборка конфигурации детектора из input-параметров EA.
   CrtDetectorConfig cfg;
   cfg.ImbBodyRatio         = ImbBodyRatio;
   cfg.DojiThreshold        = DojiThreshold;
   cfg.DojiToImbSizeRatio   = DojiToImbSizeRatio;
   cfg.DojiToImbRangeRatio  = DojiToImbRangeRatio;
   cfg.OpenTolerance        = OpenTolerance;
   cfg.BareImbWickTolerance = BareImbWickTolerance;

   CrtPatternFlags flags;
   flags.AlertTrueRB          = TradeTrueRB;
   flags.AlertInsideWick      = TradeInsideWick;
   flags.AlertGhostTrueRB     = TradeGhostTrueRB;
   flags.AlertGhostInsideWick = TradeGhostInsideWick;
   flags.AlertBareImbalance   = TradeBareImbalance;

   // Единственный вызов детектора.
   CrtSignal signal;
   CrtDetectorDetect(prev, imb, doji, cfg, flags, signal);

   if(!signal.detected) return;

   // Трендовый фильтр: imbDir=+1 (bull IMB) → SELL → -1; imbDir=-1 → BUY → +1
   if(!TrendIsAllowed(g_trend_cfg, g_trend_h, -signal.imbDir)) return;

   // Делегирование в существующий ProcessCRTSignal.
   ProcessCRTSignal(imb, doji, signal.imbDir, signal.patternName, signal.isFVG);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+

int OnInit()
{
   g_pending.Reset();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   //── Инициализация адаптера торговых операций ──
   if(g_trade_adapter == NULL)
      g_trade_adapter = new RealTradeAdapter(GetPointer(trade));
   if(g_trade_adapter == NULL)
   {
      Print("❌ Не удалось создать TradeAdapter");
      return INIT_FAILED;
   }

   //── Валидация параметров трейлинга ──
   if(SyncTrailStepPoints < 0)
   {
      PrintFormat("❌ Ошибка параметра: SyncTrailStepPoints=%.2f должен быть >= 0",
                  SyncTrailStepPoints);
      return INIT_PARAMETERS_INCORRECT;
   }

   ArraySetAsSeries(g_rates, true);
   g_last_bar_time = 0;

   //── Инициализация TrendFilter ──
   g_trend_cfg.useTrend  = UseTrendFilter;
   g_trend_cfg.useADX    = UseADXFilter;
   g_trend_cfg.timeframe = TrendTimeframe;
   g_trend_cfg.fastEMA   = TrendFastEMA;
   g_trend_cfg.slowEMA   = TrendSlowEMA;
   g_trend_cfg.adxPeriod = ADXPeriod;
   g_trend_cfg.adxMin    = ADXMin;
   if(!TrendInit(g_trend_cfg, g_trend_h))
     {
      Print("❌ Ошибка инициализации TrendFilter");
      return INIT_FAILED;
     }

   MqlDateTime srv;
   TimeToStruct(TimeTradeServer(), srv);
   PrintFormat("🕐 Серверное время: %04d.%02d.%02d %02d:%02d:%02d",
               srv.year, srv.mon, srv.day, srv.hour, srv.min, srv.sec);

   if(UseSessionFilter)
   {
      g_session_cfg.enabled             = UseSessionFilter;
      g_session_cfg.americanCloseHour   = AmericanCloseHour;
      g_session_cfg.americanCloseMinute = AmericanCloseMinute;
      g_session_cfg.asianOpenHour       = AsianOpenHour;
      g_session_cfg.asianOpenMinute     = AsianOpenMinute;
      g_session_cfg.windowMinutes       = SessionWindowMinutes;

      const bool auto_ok = SessionInit(g_session_cfg, g_session_state);

      long eff_am = 0, eff_as = 0;
      SessionGetEffective(g_session_cfg, g_session_state, eff_am, eff_as);

      if(auto_ok)
         PrintFormat("✅ Сессии: АВТО | Закр. Амер: %02d:%02d | Откр. Азия: %02d:%02d | Окно: ±%d мин",
                     (int)(eff_am / 3600), (int)((eff_am % 3600) / 60),
                     (int)(eff_as / 3600), (int)((eff_as % 3600) / 60),
                     SessionWindowMinutes);
      else
      {
         PrintFormat("⚠️  Сессии: РУЧНОЙ | Закр. Амер: %02d:%02d | Откр. Азия: %02d:%02d | Окно: ±%d мин",
                     AmericanCloseHour, AmericanCloseMinute,
                     AsianOpenHour, AsianOpenMinute, SessionWindowMinutes);
         Print("⚠️  Укажите часы в СЕРВЕРНОМ времени брокера.");
      }
   }
   else
   {
      // Фильтр выключен — Session* вернут false благодаря enabled=false.
      g_session_cfg.enabled             = false;
      g_session_cfg.americanCloseHour   = AmericanCloseHour;
      g_session_cfg.americanCloseMinute = AmericanCloseMinute;
      g_session_cfg.asianOpenHour       = AsianOpenHour;
      g_session_cfg.asianOpenMinute     = AsianOpenMinute;
      g_session_cfg.windowMinutes       = SessionWindowMinutes;
      SessionInit(g_session_cfg, g_session_state);
      Print("⏰ Сессионный фильтр выключен");
   }

   //── Selected Sessions Filter (новый API) ──
   g_selected_cfg.enabled                     = UseSelectedSessions;
   g_selected_cfg.useAsian                    = UseAsianSession;
   g_selected_cfg.useLondon                   = UseLondonSession;
   g_selected_cfg.useNewYork                  = UseNewYorkSession;
   g_selected_cfg.asianStartSec               = (long)AsianStartHour  * 3600 + (long)AsianStartMinute  * 60;
   g_selected_cfg.asianEndSec                 = (long)AsianEndHour    * 3600 + (long)AsianEndMinute    * 60;
   g_selected_cfg.londonStartSec              = (long)LondonStartHour * 3600 + (long)LondonStartMinute * 60;
   g_selected_cfg.londonEndSec                = (long)LondonEndHour   * 3600 + (long)LondonEndMinute   * 60;
   g_selected_cfg.nyStartSec                  = (long)NYStartHour     * 3600 + (long)NYStartMinute     * 60;
   g_selected_cfg.nyEndSec                    = (long)NYEndHour       * 3600 + (long)NYEndMinute       * 60;
   g_selected_cfg.gmtOffsetSeconds            = (long)SessionGmtOffsetHours * 3600;
   g_selected_cfg.dstMode                     = SessionDstMode;
   g_selected_cfg.closeOnSessionExit          = CloseOnSessionExit;
   g_selected_cfg.useBrokerSessionsAsFallback = UseBrokerSessionsAsFallback;

   const bool selected_ok = SelectedSessionsInit(g_selected_cfg, g_selected_state);

   if(!UseSelectedSessions)
   {
      Print("⏰ Selected sessions filter OFF");
   }
   else if(selected_ok)
   {
      // Список выбранных сессий через запятую.
      string sessions = "";
      if(UseAsianSession)   sessions += (StringLen(sessions) > 0 ? "," : "") + "Asian";
      if(UseLondonSession)  sessions += (StringLen(sessions) > 0 ? "," : "") + "London";
      if(UseNewYorkSession) sessions += (StringLen(sessions) > 0 ? "," : "") + "NewYork";
      if(StringLen(sessions) == 0) sessions = "(none)";

      long aS = 0, aE = 0, lS = 0, lE = 0, nS = 0, nE = 0;
      SelectedSessionsGetEffective(g_selected_cfg, g_selected_state,
                                   aS, aE, lS, lE, nS, nE);

      const double eff_hours = (double)g_selected_state.effectiveGmtOffsetSec / 3600.0;

      PrintFormat("⏰ Selected sessions ON | %s | GMT%+.2fh | "
                  "Asian %02d:%02d-%02d:%02d UTC | "
                  "London %02d:%02d-%02d:%02d UTC | "
                  "NY %02d:%02d-%02d:%02d UTC",
                  sessions, eff_hours,
                  (int)(aS / 3600), (int)((aS % 3600) / 60),
                  (int)(aE / 3600), (int)((aE % 3600) / 60),
                  (int)(lS / 3600), (int)((lS % 3600) / 60),
                  (int)(lE / 3600), (int)((lE % 3600) / 60),
                  (int)(nS / 3600), (int)((nS % 3600) / 60),
                  (int)(nE / 3600), (int)((nE % 3600) / 60));
   }
   else
   {
      // Init вернул false — детальная диагностика уже выведена внутри
      // SelectedSessionsInit (errorMessage из ValidateConfig). Добавляем
      // один summary-лог о факте отключения фильтра.
      Print("❌ Selected sessions filter: невалидная конфигурация — фильтр отключён");
   }

   string modeStr;
   switch(EntryMode)
   {
      case ENTRY_SWEEP_RECLAIM: modeStr = "SWEEP+RECLAIM"; break;
      case ENTRY_MARKET:        modeStr = "MARKET";        break;
      case ENTRY_LIMIT:         modeStr = "LIMIT";         break;
      default:                  modeStr = "?";
   }

   PrintFormat("✅ CRT Trade Bot v4.2 инициализирован. TF: %s | Режим входа: %s | MaxBars: %d",
               EnumToString(TradingTimeframe), modeStr, MaxBarsToWait);

   PrintFormat("📈 TrendFilter:%s TF:%s EMA(%d,%d) | ADX:%s Period:%d Min:%.1f",
               UseTrendFilter ? "ON" : "OFF",
               EnumToString(TrendTimeframe),
               TrendFastEMA, TrendSlowEMA,
               UseADXFilter ? "ON" : "OFF",
               ADXPeriod, ADXMin);

   //── Лог активного режима трейлинга ──
   string trailModeStr;
   switch(TrailingMode)
   {
      case TRAILING_OFF:       trailModeStr = "OFF";       break;
      case TRAILING_BREAKEVEN: trailModeStr = "BREAKEVEN"; break;
      case TRAILING_SYNC:      trailModeStr = "SYNC";      break;
      default:                 trailModeStr = "?";
   }
   if(TrailingMode == TRAILING_SYNC)
      PrintFormat("🔁 Трейлинг: %s | StartFactor=%.2f | StepPoints=%.2f",
                  trailModeStr, TrailingStartFactor, SyncTrailStepPoints);
   else
      PrintFormat("🔁 Трейлинг: %s | StartFactor=%.2f", trailModeStr, TrailingStartFactor);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   if(EntryMode == ENTRY_LIMIT)
   {
      // EA-state (g_pending.limitTicket) сбрасывается здесь — модуль про него не знает.
      PositionGuardCancelAllPending(trade, MagicNumber);
      g_pending.limitTicket = 0;
   }

   if(g_trade_adapter != NULL)
   {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
   }

   TrendDeinit(g_trend_h);

   Comment("");
   Print("✅ CRT Trade Bot v4.2 выгружен");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+

void OnTick()
{
   //── Selected Sessions Filter prelude ──
   // Применяется ДО legacy SessionIsAmericanPreClose / SessionIsBoundary.
   // При UseSelectedSessions = false prelude полностью
   // пропускается и legacy путь работает без изменений.
   if(UseSelectedSessions)
   {
      // Edge-trigger: ровно один раз на переход inside→outside.
      // DetectExit внутри обновляет state.wasInsideOnPreviousTick.
      if(SelectedSessionsDetectExit(g_selected_cfg, g_selected_state))
      {
         if(CloseOnSessionExit)
            HandleSessionExitClose();
         return;                              // пропуск legacy и логики входа
      }
      // Вне Selected_Union_Interval — никакой работы с рынком.
      if(!SelectedSessionsIsInside(g_selected_cfg, g_selected_state))
         return;
      // Inside: продолжаем в legacy путь.
   }

   //── Тиковая ветка ──
   if(SessionIsAmericanPreClose(g_session_cfg, g_session_state))
   {
      CloseAllOpenPositions();
      return;
   }

   CheckPendingEntry();
   ManageTrailing();

   //── Баровая ветка ──
   if(IsNewBar())
      CheckCRTEntry();
}