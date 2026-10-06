//+------------------------------------------------------------------+
//|                                           engulfing-bot_v2.1.mq5 |
//|  Engulfing + EntryModes + HTF Trend/ADX filter                   |
//+------------------------------------------------------------------+
#property strict
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
#include "Include/EntryTrigger.mqh"
CTrade trade;

//── Режим входа ──────────────────────────────────────────────────────
// ENUM_ENTRY_MODE — в Include/EntryTrigger.mqh

//── Входные параметры ─────────────────────────────────────────────────

input group "── Управление капиталом ──"
input int    MagicNumber = 71003;   // Магический номер (уникальный для каждого бота)
input double RiskPercent = 3.0;    // Риск на сделку, %
input double MaxRiskOvershoot = 1.5; // Пропуск сделки, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL   = 0.10; // Макс. спред как доля расстояния до SL (0.10 = 10%; 0 = выкл)
input double MaxSlippageToSL = 0.10; // Макс. проскальзывание как доля расстояния до SL (0 = без ограничения)

input group "── Параметры входа ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M1;
input ENUM_ENTRY_MODE EntryMode        = ENTRY_SWEEP_RECLAIM;
input bool RequireOppositeCandle       = true;   // Свеча [2] должна быть противоположной
input bool RequireFullBodyEngulf       = true;   // Тело [1] должно полностью поглотить тело [2]
// Все расстояния ниже — в ПУНКТАХ (не пипсах): на золоте с 3 знаками 1000 пт = 1.00 USD цены.
input double RBOpenCloseTolerancePips  = 100;    // Допуск |open[1] - close[2]|, пункты, 0 = выключено

input double MinBodyPips               = 0;      // Мин. тело свечи [1], пункты, 0 = выключено
input double R1BodyRatio               = 0.4;    // Мин. доля тела от диапазона [1], 0 = выключено
input double R2BodyRatio               = 0.2;    // Мин. доля тела от диапазона [2], 0 = выключено
input double R2ToR1SizeRatio           = 0.3;    // Мин. отношение тела [2] к телу [1], 0 = выключено


input double MaxSpreadPips             = 0;      // Макс. спред, пункты, 0 = выключено (см. также MaxSpreadToSL)
input int    TradeLockSeconds          = 3;      // Пауза после market-входа, сек, 0 = выключено

input group "── Ожидание входа ──"
input int MaxBarsToWait = 2;   // Макс. баров до отмены сигнала/ордера (0 = без ограничения)

input group "── Stop Loss / Take Profit ──"
input double BufferPips = 200;     // Отступ от экстремума свечей, пункты (200 = 0.20 USD)
input double MinSLPips  = 1500;    // Минимальный SL, пункты (1500 = 1.50 USD)
input double MaxSLPips  = 3175;    // Максимальный SL, пункты (3175 = 3.175 USD)
input double RiskReward = 1.5;     // TP = SL distance * RiskReward

// Параметры сессий — общие для всех ботов; у engulfing выбор сессий по умолчанию выключен.
#define SESSION_DEFAULT_SELECTED      false
#define SESSION_DEFAULT_LONDON        false
#define SESSION_DEFAULT_CLOSE_ON_EXIT false
#include "Include/Inputs/SessionInputs.mqh"

input group "── Фильтр тренда (HTF) ──"
input bool            UseTrendFilter = true;
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_M15;
input int             TrendFastEMA   = 50;
input int             TrendSlowEMA   = 200;

input group "── ADX фильтр (опционально) ──"
input bool   UseADXFilter = false;
input int    ADXPeriod    = 14;
input double ADXMin       = 20.0;

// Опциональный трейлинг через TrailingDispatcher. По умолчанию OFF →
// диспетчер вырождается в no-op. SYNC сейчас задокументированный no-op
// внутри диспетчера; реально работает BREAKEVEN.
input group "── Трейлинг (opt-in) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Статические глобальные переменные (вычисляются в OnInit) ─────────
// adjustedPoint, minBrokerDistance, fillType — внутри g_broker.
// Лот: LOT_BY_TICK_VALUE.
// BrokerEnforceMinSLDist модифицирует только SL; пересчёт TP — caller через CalcTPByRR.
BrokerContext g_broker;

// TrendFilter: lifecycle EMA/ADX полностью внутри модуля.
// Модульный TrendIsAllowed НЕ эмитит Print при отказе (silent rejection).
TrendConfig  g_trend_cfg;
TrendHandles g_trend_h;

// TradeAdapter + TrailingConfig для трейлинг-диспетчера. cfg заполняется
// в OnInit и далее передаётся по const & — диспетчер cfg не модифицирует.
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//── Состояние паттерна ────────────────────────────────────────────────
bool     g_pattern_active    = false;  // Паттерн ожидает входа
double   g_entry_level       = 0.0;   // 50% уровень тела свечи поглощения
int      g_pattern_dir       = 0;     //  1 = BUY, -1 = SELL
datetime g_entry_candle_time = 0;     // время бара [0] в момент активации паттерна
datetime g_pattern_expire_at = 0;     // 0 = без ограничения
double   g_sl_level          = 0.0;   // Рассчитанный уровень SL
double   g_tp_level          = 0.0;   // Рассчитанный уровень TP

//── Защита от повторного сигнала ──────────────────────────────────────
datetime last_rb_candle1_time = 0;    // rates[1].time последнего обработанного RB
datetime last_rb_candle2_time = 0;    // rates[2].time последнего обработанного RB
datetime last_rb_bar_time     = 0;    // legacy: rates[1].time последнего обработанного паттерна
int      last_rb_direction    = 0;    //  1 = BUY, -1 = SELL

//── Защита от повторной отправки market-ордера ────────────────────────
datetime g_last_trade_request_time = 0;

//── Лимитный ордер (только для ENTRY_LIMIT) ───────────────────────
ulong g_pending_ticket = 0;

//── Sweep/Reclaim состояние (только для ENTRY_SWEEP_RECLAIM) ──────
bool g_swept = false;

//+------------------------------------------------------------------+
//| УТИЛИТЫ                                                          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| СЕССИИ — реализация в Include/SessionFilter.mqh                  |
//+------------------------------------------------------------------+

bool IsSpreadAllowed()
{
   if(MaxSpreadPips <= 0.0) return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_pts = (ask - bid) / g_broker.adjustedPoint;
   static bool s_blocked = false;   // печатаем только при смене состояния, а не на каждом тике
   if(spread_pts <= MaxSpreadPips)
   {
      if(s_blocked) PrintFormat("✅ Спред %.1f pts снова в пределах лимита", spread_pts);
      s_blocked = false;
      return true;
   }
   if(!s_blocked) PrintFormat("🚫 Спред %.1f pts выше лимита %.1f pts", spread_pts, MaxSpreadPips);
   s_blocked = true;
   return false;
}

bool IsTradeRequestLocked()
{
   if(TradeLockSeconds <= 0 || g_last_trade_request_time == 0) return false;
   datetime now = TimeTradeServer();
   return ((now - g_last_trade_request_time) < TradeLockSeconds);
}

// TrendIsAllowed возвращает чистое bool без Print при отказе — решение о трассировке за EA.
bool IsEngulfingPattern(const MqlRates &r2, const MqlRates &r1, int &dir)
{
   double body1 = MathAbs(r1.close - r1.open);
   double body2 = MathAbs(r2.close - r2.open);

   if(body1 <= 0.0 || body2 <= 0.0) return false;
   if(MinBodyPips > 0.0 && body1 / g_broker.adjustedPoint < MinBodyPips) return false;

   if(R1BodyRatio > 0.0)
   {
      double range = r1.high - r1.low;
      if(range <= 0.0) return false;
      if(body1 / range < R1BodyRatio) return false;
   }

   if(R2BodyRatio > 0.0)
   {
      double range = r2.high - r2.low;
      if(range <= 0.0) return false;
      if(body2 / range < R2BodyRatio) return false;
   }

   // ── тело [2] не должно быть слишком маленьким относительно [1] ──
   if(R2ToR1SizeRatio > 0.0 && body2 / body1 < R2ToR1SizeRatio) return false;

   if(body1 <= body2) return false;

   if(RBOpenCloseTolerancePips > 0.0)
   {
      double rb_gap_pts = MathAbs(r1.open - r2.close) / g_broker.adjustedPoint;
      if(rb_gap_pts > RBOpenCloseTolerancePips) return false;
   }

   bool c1_bull = r1.close > r1.open;
   bool c1_bear = r1.close < r1.open;
   bool c2_bull = r2.close > r2.open;
   bool c2_bear = r2.close < r2.open;
   if(!c1_bull && !c1_bear) return false;

   if(RequireOppositeCandle)
   {
      if(c1_bull && !c2_bear) return false;
      if(c1_bear && !c2_bull) return false;
   }

   if(RequireFullBodyEngulf)
   {
      double r1_body_low  = MathMin(r1.open, r1.close);
      double r1_body_high = MathMax(r1.open, r1.close);
      double r2_body_low  = MathMin(r2.open, r2.close);
      double r2_body_high = MathMax(r2.open, r2.close);
      if(r1_body_low > r2_body_low || r1_body_high < r2_body_high) return false;
   }

   dir = c1_bull ? 1 : -1; // Вариант A: bullish → BUY, bearish → SELL
   return true;
}

//+------------------------------------------------------------------+
//| ПОЗИЦИИ И ОРДЕРА                                                 |
//+------------------------------------------------------------------+

// CancelPendingOrder() — EA-specific: сбрасывает g_pending_ticket после
// успешной отмены. Проверка существования делегирована PositionGuard.
void CancelPendingOrder()
{
   if(g_pending_ticket == 0) return;
   if(!PositionGuardPendingExists(g_pending_ticket))
   {
      g_pending_ticket = 0;
      return;
   }
   if(trade.OrderDelete(g_pending_ticket))
      PrintFormat("🚫 Лимитный ордер #%I64u отменён (цена не коснулась 50%%)", g_pending_ticket);
   else
      PrintFormat("❌ Ошибка отмены ордера #%I64u: %d | %s",
                  g_pending_ticket, trade.ResultRetcode(), trade.ResultComment());
   g_pending_ticket = 0;
}

void ResetPattern()
{
   g_pattern_active    = false;
   g_entry_level       = 0.0;
   g_pattern_dir       = 0;
   g_entry_candle_time = 0;
   g_pattern_expire_at = 0;
   g_sl_level          = 0.0;
   g_tp_level          = 0.0;
   g_swept             = false;
}

//+------------------------------------------------------------------+
//| РАСЧЁТ ЛОТА                                                      |
//+------------------------------------------------------------------+

double CalcTPByRR(double entry, double sl, int dir)
{
   double sl_dist = MathAbs(entry - sl);
   if(dir == 1) return entry + sl_dist * RiskReward;
   return entry - sl_dist * RiskReward;
}

//+------------------------------------------------------------------+
//| РАСЧЁТ SL И TP                                                   |
//|                                                                  |
//| SL = экстремум свечей [2] и [1] ± BufferPips                     |
//| TP = дистанция SL * RiskReward                                   |
//+------------------------------------------------------------------+

void CalcSLTP(double entry, int dir,
              double high2, double low2,
              double high1, double low1,
              double &sl_out, double &tp_out)
{
   double point = g_broker.adjustedPoint;

   if(dir == -1)  // SELL: SL выше экстремума
   {
      double slBase = MathMax(high2, high1);
      sl_out = slBase + BufferPips * point;
      sl_out = MathMax(sl_out, entry + MinSLPips * point);
      sl_out = MathMin(sl_out, entry + MaxSLPips * point);
      tp_out = CalcTPByRR(entry, sl_out, dir);
   }
   else           // BUY: SL ниже экстремума
   {
      double slBase = MathMin(low2, low1);
      sl_out = slBase - BufferPips * point;
      sl_out = MathMin(sl_out, entry - MinSLPips * point);
      sl_out = MathMax(sl_out, entry - MaxSLPips * point);
      tp_out = CalcTPByRR(entry, sl_out, dir);
   }
}

//+------------------------------------------------------------------+
//| ПРОВЕРКА И КОРРЕКЦИЯ МИНИМАЛЬНОЙ ДИСТАНЦИИ SL                    |
//| (BrokerEnforceMinSLDist модифицирует только SL; TP пересчитывает |
//|  caller через CalcTPByRR — RR сохраняется.)                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| ОТКРЫТИЕ РЫНОЧНОЙ СДЕЛКИ (ENTRY_MARKET/SWEEP_RECLAIM)            |
//+------------------------------------------------------------------+

bool OpenEngulfingTrade(ENUM_ORDER_TYPE orderType, double entry,
                        double sl, double tp)
{
   // EA-specific guard'ы (trade-lock + spread-check) выполняются ДО TradeExecutorSend.
   if(IsTradeRequestLocked()) return false;
   if(!IsSpreadAllowed())     return false;

   // Caller-side TP recalc при подтяжке SL до мин. брокерской дистанции.
   // Делаем ДО формирования запроса, чтобы избежать
   // post-condition guard'а INVALID_STOPS внутри TradeExecutorSend.
   {
      const double sl_before = sl;
      BrokerEnforceMinSLDist(g_broker, orderType, entry, sl);
      if(sl != sl_before)
      {
         const int dirFromType = (orderType == ORDER_TYPE_BUY ||
                                  orderType == ORDER_TYPE_BUY_LIMIT) ? 1 : -1;
         tp = CalcTPByRR(entry, sl, dirFromType);
         PrintFormat("⚠️ SL→min: %.5f", sl);
      }
   }

   const double sl_dist = MathAbs(entry - sl);
   const string dir     = (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL");

   TradeOrderRequest req;
   req.orderType = orderType;
   req.price     = entry;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = BrokerCalcLot(g_broker, RiskPercent,
                                 sl_dist / g_broker.adjustedPoint,
                                 LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(req.lot <= 0.0)
   {
      ResetPattern();   // минимальный лот слишком рискованный — сигнал отбрасываем
      return false;
   }
   req.comment   = StringFormat("ENG_%s TF:%s", dir, EnumToString(TradingTimeframe));
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   const TradeResult result = TradeExecutorSend(trade, g_broker, req);
   if(result.success)
   {
      // EA-state-update после успеха (модуль состояние EA не трогает).
      g_last_trade_request_time = TimeTradeServer();
      return true;
   }

   // Пропуск по фильтру (спред, пауза) модуль уже записал в журнал;
   // паттерн остаётся активным и ждёт нормализации до истечения срока.
   if(!result.skipped)
      PrintFormat("❌ Ошибка открытия: %u | %s",
                  result.retcode, result.description);
   return false;
}

//+------------------------------------------------------------------+
//| РАЗМЕЩЕНИЕ ЛИМИТНОГО ОРДЕРА (ENTRY_LIMIT)                        |
//+------------------------------------------------------------------+

void PlaceLimitOrder(ENUM_ORDER_TYPE orderType, double price,
                     double sl, double tp)
{
   // Caller-side TP recalc.
   {
      const double sl_before = sl;
      BrokerEnforceMinSLDist(g_broker, orderType, price, sl);
      if(sl != sl_before)
      {
         const int dirFromType = (orderType == ORDER_TYPE_BUY ||
                                  orderType == ORDER_TYPE_BUY_LIMIT) ? 1 : -1;
         tp = CalcTPByRR(price, sl, dirFromType);
         PrintFormat("⚠️ SL→min: %.5f", sl);
      }
   }

   const double          sl_dist  = MathAbs(price - sl);
   const ENUM_ORDER_TYPE original = orderType;
   const string          dir      = (orderType == ORDER_TYPE_BUY_LIMIT ? "BUY LIMIT" : "SELL LIMIT");

   // Fallback BUY_LIMIT→BUY / SELL_LIMIT→SELL делает TradeExecutorSend.
   // При fallback TP не пересчитывается под market-цену
   // (RR сохраняется относительно limit-price; отклонение ≤ min broker distance).
   TradeOrderRequest req;
   req.orderType = orderType;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = BrokerCalcLot(g_broker, RiskPercent,
                                 sl_dist / g_broker.adjustedPoint,
                                 LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(req.lot <= 0.0)
   {
      ResetPattern();   // минимальный лот слишком рискованный — сигнал отбрасываем
      return;
   }
   req.comment   = StringFormat("ENG_%s TF:%s", dir, EnumToString(TradingTimeframe));
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   const TradeResult result = TradeExecutorSend(trade, g_broker, req);

   if(result.success)
   {
      // Fallback limit→market: ведём себя как market-вход.
      const bool fellBackToMarket = (req.orderType != original);
      if(fellBackToMarket)
      {
         PrintFormat("⚠️ %s %.5f уже пройден → вход по рынку",
                     (original == ORDER_TYPE_BUY_LIMIT ? "BUY LIMIT" : "SELL LIMIT"),
                     price);
         g_last_trade_request_time = TimeTradeServer();
         g_pending_ticket          = 0;
         ResetPattern();
      }
      else
      {
         g_pending_ticket = result.ticket;
      }
      return;
   }

   PrintFormat("❌ Ошибка %s: %u | %s",
               dir, result.retcode, result.description);
   ResetPattern();
}

//+------------------------------------------------------------------+
//| ЗАКРЫТИЕ ПЕРЕД ГРАНИЦЕЙ СЕССИИ                                   |
//| (Bulk-close делегирован PositionGuard; EA-prelude — здесь, т.к.  |
//|  затрагивает EA-specific state: pending-ticket и pattern.)       |
//+------------------------------------------------------------------+
void CloseAllOpenPositions()
{
   Print("🔒 Закрытие позиций перед границей сессии");

   // EA-specific prelude
   if(EntryMode == ENTRY_LIMIT) PositionGuardCancelAllPending(trade, MagicNumber);
   if(g_pattern_active)
   {
      ResetPattern();
      Print("🚫 Ожидающий паттерн сброшен (граница сессии)");
   }

   PositionGuardCloseAll(trade, MagicNumber);
}

//+------------------------------------------------------------------+
//| ЗАКРЫТИЕ ПО SESSION_EXIT_EVENT (новый Selected Sessions API)     |
//|                                                                  |
//| Вызывается из OnTick prelude после SelectedSessionsDetectExit==  |
//| true и только при CloseOnSessionExit=true. Edge-trigger в        |
//| DetectExit гарантирует ровно один вызов на переход inside→       |
//| outside, поэтому Print здесь тоже один на                        |
//| событие.                                                         |
//|                                                                  |
//| Контракт:                                                        |
//|   1. PositionGuardCloseAll(trade, MagicNumber)                   |
//|   2. PositionGuardCancelAllPending(trade, MagicNumber)           |
//|   3. EA-specific pending: ResetPattern + g_pending_ticket=0      |
//|   4. Один Print с UTC-временем выхода и счётчиками               |
//|                                                                  |
//| UTC-время берём из g_selected_state.lastEvaluatedUtcSec — оно    |
//| записано последним вызовом SelectedSessionsIsInside (внутри      |
//| SelectedSessionsDetectExit) и не требует повторного обращения к  |
//| TimeGMT().                                                       |
//+------------------------------------------------------------------+
void HandleSessionExitClose()
{
   const int closed    = PositionGuardCloseAll(trade, MagicNumber);
   const int cancelled = PositionGuardCancelAllPending(trade, MagicNumber);

   // EA-specific pending state (engulfing-bot): паттерн + лимитный тикет.
   ResetPattern();
   g_pending_ticket = 0;

   const long utcSec = g_selected_state.lastEvaluatedUtcSec;
   const int  hh = (int)(utcSec / 3600);
   const int  mm = (int)((utcSec % 3600) / 60);
   const int  ss = (int)(utcSec % 60);

   PrintFormat("⏰ Session exit @ %02d:%02d:%02d UTC | closed=%d | cancelled=%d",
               hh, mm, ss, closed, cancelled);
}

//+------------------------------------------------------------------+
//| ОСНОВНАЯ ЛОГИКА: ПОИСК И ВХОД В ПАТТЕРН                          |
//|                                                                  |
//| 1. Лимитный ордер уже исполнен → сбросить состояние              |
//| 2. Открытая позиция → ничего не делаем                           |
//| 3. Паттерн активен и таймаут → сброс                             |
//| 4. Паттерна нет → проверить новый паттерн на rates[1/2]          |
//| 5. Паттерн активен → MARKET/SWEEP_RECLAIM/LIMIT логика           |
//+------------------------------------------------------------------+

void CheckEngulfingEntry()
{
   //── 1: Лимитный ордер исполнился → позиция открыта, сбросить ──
   if(g_pending_ticket != 0 && !PositionGuardPendingExists(g_pending_ticket))
   {
      g_pending_ticket = 0;
      ResetPattern();
      return;
   }

   //── 2: Уже есть открытая позиция или недавно отправлен ордер → ждём ──
   ENUM_POSITION_TYPE dummy;
   if(PositionGuardHasOpen(MagicNumber, dummy)) return;
   if(IsTradeRequestLocked()) return;

   //── Загрузка свечей ──
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, TradingTimeframe, 0, 3, rates) < 3) return;

   //── 3: Таймаут ожидания входа (по MaxBarsToWait) ──
   if(g_pattern_active && g_pattern_expire_at > 0 && TimeTradeServer() > g_pattern_expire_at)
   {
      PrintFormat("⌛ Паттерн истёк: уровень %.5f не достигнут за %d бар(ов)",
                  g_entry_level, MaxBarsToWait);
      if(EntryMode == ENTRY_LIMIT) CancelPendingOrder();
      ResetPattern();
      return;
   }

   //── 4: Поиск нового паттерна ──
   if(!g_pattern_active)
   {
      if(SessionsIsBoundary()) return;
      if(!IsSpreadAllowed()) return;

      double body1 = MathAbs(rates[1].close - rates[1].open);
      double body2 = MathAbs(rates[2].close - rates[2].open);
      int new_dir = 0;
      if(!IsEngulfingPattern(rates[2], rates[1], new_dir)) return;
      if(!TrendIsAllowed(g_trend_cfg, g_trend_h, new_dir)) return;

      bool c1_bull = (new_dir == 1);

      // Защита от повторного сигнала по той же паре свечей RB
      if(last_rb_candle2_time == rates[2].time &&
         last_rb_candle1_time == rates[1].time &&
         last_rb_direction == new_dir) return;

      // Доп. защита: та же поглощающая свеча не должна повторно стать rates[2]
      if(last_rb_candle1_time == rates[2].time && last_rb_direction == new_dir) return;

      // 50% уровень тела свечи поглощения
      double entry_level = (rates[1].open + rates[1].close) / 2.0;

      // Рассчитываем SL и TP относительно уровня входа
      double sl = 0.0, tp = 0.0;
      CalcSLTP(entry_level, new_dir,
               rates[2].high, rates[2].low,
               rates[1].high, rates[1].low,
               sl, tp);

      double rb_gap_pts = MathAbs(rates[1].open - rates[2].close) / g_broker.adjustedPoint;
      PrintFormat("🔍 RB %s | b[2]:%.1f b[1]:%.1f | O[1]-C[2]:%.1f | 50%%:%.5f | SL:%.5f | TP:%.5f | RR:%.2f | SLd:%.1f | Exp:%s",
                  c1_bull ? "BUY" : "SELL",
                  body2 / g_broker.adjustedPoint,
                  body1 / g_broker.adjustedPoint,
                  rb_gap_pts, entry_level, sl, tp, RiskReward,
                  MathAbs(entry_level - sl) / g_broker.adjustedPoint,
                  MaxBarsToWait > 0 ? TimeToString(rates[1].time + (datetime)(MaxBarsToWait + 1) * PeriodSeconds(TradingTimeframe), TIME_DATE|TIME_MINUTES) : "∞");

      // Запоминаем паттерн
      last_rb_candle1_time = rates[1].time;
      last_rb_candle2_time = rates[2].time;
      last_rb_bar_time     = rates[1].time;
      last_rb_direction    = new_dir;

      g_pattern_active    = true;
      g_entry_level       = entry_level;
      g_pattern_dir       = new_dir;
      g_entry_candle_time = rates[0].time;
      if(MaxBarsToWait > 0)
         g_pattern_expire_at = rates[1].time + (datetime)(MaxBarsToWait + 1) * PeriodSeconds(TradingTimeframe);
      else
         g_pattern_expire_at = 0;
      g_sl_level          = sl;
      g_tp_level          = tp;
      g_swept             = false;

      // ENTRY_LIMIT: сразу выставляем ордер и выходим
      if(EntryMode == ENTRY_LIMIT)
      {
         ENUM_ORDER_TYPE limitType = (new_dir == 1) ? ORDER_TYPE_BUY_LIMIT
                                                     : ORDER_TYPE_SELL_LIMIT;
         PlaceLimitOrder(limitType, entry_level, sl, tp);
         return;
      }
   }

   // ── Шаг 5: тиковая обработка активного паттерна ──────────────────
   if(g_pattern_active && EntryMode != ENTRY_LIMIT)
   {
      if(SessionsIsBoundary()) return;
      if(!IsSpreadAllowed()) return;

      double price = 0.0;
      if(EntryTriggerPoll(EntryMode, g_pattern_dir, g_entry_level, g_swept, "RB 50%", price))
      {
         const ENUM_ORDER_TYPE type = (g_pattern_dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         const double tp_actual = CalcTPByRR(price, g_sl_level, g_pattern_dir);
         if(OpenEngulfingTrade(type, price, g_sl_level, tp_actual)) ResetPattern();
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+

int OnInit()
{
   //--- SendNotification("Message");

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   // BrokerInit заполняет g_broker (adjustedPoint, minBrokerDistance, fillType).
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   // TradeAdapter + TrailingConfig (opt-in трейлинг; OFF по умолчанию = no-op).
   g_trade_adapter = new RealTradeAdapter(GetPointer(trade));
   if(g_trade_adapter == NULL)
     {
      Print("❌ Не удалось создать TradeAdapter");
      return INIT_FAILED;
     }
   g_trail_cfg.mode            = TrailingMode;
   g_trail_cfg.startFactor     = TrailingStartFactor;
   g_trail_cfg.breakevenOffset = BreakevenOffsetPoints;
   g_trail_cfg.trailStep       = SyncTrailStepPoints;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // TrendFilter wiring (модуль валидирует пределы и откатывает хэндлы при сбое).
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

   SessionsSetup();

   ResetPattern();
   g_pending_ticket           = 0;
   last_rb_candle1_time       = 0;
   last_rb_candle2_time       = 0;
   last_rb_bar_time           = 0;
   last_rb_direction          = 0;
   g_last_trade_request_time  = 0;

   string modeStr = "?";
   if(EntryMode == ENTRY_SWEEP_RECLAIM) modeStr = "SWEEP+RECLAIM";
      else if(EntryMode == ENTRY_MARKET)   modeStr = "MARKET";
      else if(EntryMode == ENTRY_LIMIT)    modeStr = "LIMIT";

   PrintFormat("✅ Engulfing Bot v2.1 | Magic:%d TF:%s Mode:%s D:%d P:%.8f "
               "MinSL:%.0f MaxSL:%.0f Buf:%.0f RR:%.2f RBTol:%.1f MinBody:%.1f MaxSpr:%.1f Lock:%d MaxBars:%d Fill:%s",
               MagicNumber, EnumToString(TradingTimeframe),
               modeStr,
               digits, g_broker.adjustedPoint,
               MinSLPips, MaxSLPips, BufferPips, RiskReward, RBOpenCloseTolerancePips, MinBodyPips, MaxSpreadPips, TradeLockSeconds, MaxBarsToWait,
               EnumToString(g_broker.fillType));

   PrintFormat("📈 TrendFilter:%s TF:%s EMA(%d,%d) | ADX:%s Period:%d Min:%.1f",
               UseTrendFilter ? "ON" : "OFF",
               EnumToString(TrendTimeframe),
               TrendFastEMA, TrendSlowEMA,
               UseADXFilter ? "ON" : "OFF",
               ADXPeriod, ADXMin);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   // Bulk-cancel через модуль; EA-state (g_pending_ticket) сбрасываем сами.
   PositionGuardCancelAllPending(trade, MagicNumber);
   g_pending_ticket = 0;

   TrendDeinit(g_trend_h);

   if(g_trade_adapter != NULL)
     {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
     }

   Print("✅ Engulfing Bot v2.1 выгружен");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+

void OnTick()
{
   const ENUM_SESSION_STATE session = SessionsOnTick();
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      HandleSessionExitClose();
   if(session != SESSION_TRADING)
      return;

   // 1. Закрыть позиции перед концом Американской сессии
   if(SessionsIsPreClose())
   {
      CloseAllOpenPositions();
      return;
   }

   // 2. Не открывать новые сделки на границах сессий
   if(SessionsIsBoundary())
   {
      // EA-prelude (pending+pattern) — здесь; bulk-cancel — в модуле.
      if(EntryMode == ENTRY_LIMIT) PositionGuardCancelAllPending(trade, MagicNumber);
      if(g_pattern_active)
      {
         ResetPattern();
         Print("🚫 Ожидающий паттерн сброшен (граница сессии)");
      }
      return;
   }

   // 3. Трейлинг (режим TrailingMode).
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);

   // 4. Поиск паттерна → вход
   CheckEngulfingEntry();
}
