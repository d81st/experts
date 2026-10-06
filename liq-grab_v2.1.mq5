//+------------------------------------------------------------------+
//|                                                liq-grab_v2.1.mq5 |
//|  Liquidity Grab v2.1: вход после снятия ликвидности              |
//|  по тренду | сессионный фильтр | трейлинг                        |
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
//--- Создаем объект торгового класса
CTrade trade;

//==========================================================================
// INPUT GROUPS
//==========================================================================
// Где ставить стоп-лосс.
enum ENUM_LIQ_SL_MODE
{
   SL_FIXED        = 0,  // Фиксированно: StopLossPoints от цены входа
   SL_BEYOND_SWEEP = 1   // За экстремумом свечи, снявшей ликвидность, + буфер
};

input group "Money Management"
input int MagicNumber = 71001; // Магический номер (уникальный для каждого бота)
input double RiskPercent = 3.0; // Риск на сделку в %
input double MaxRiskOvershoot = 1.5; // Пропуск сделки, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL   = 0.10; // Макс. спред как доля расстояния до SL (0.10 = 10%; 0 = выкл)
input double MaxSlippageToSL = 0.10; // Макс. проскальзывание как доля расстояния до SL (0 = без ограничения)

input group "Trade Parameters"
input ENUM_LIQ_SL_MODE StopMode = SL_BEYOND_SWEEP; // Режим стоп-лосса
input double StopLossPoints = 3175; // SL в пунктах (режим SL_FIXED)
input double SweepSLBufferPoints = 100;  // Буфер за экстремумом снятия, пункты (SL_BEYOND_SWEEP)
input double MinSLPoints = 1000;         // Мин. SL, пункты (SL_BEYOND_SWEEP)
input double MaxSLPoints = 6350;         // Макс. SL, пункты (SL_BEYOND_SWEEP)
input double RiskRewardRatio = 2.0; // RR
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M3;
input bool UseClosedBarSignal = true; // Сигнал по закрытой свече (false — внутри формирующейся, как раньше)

input group "Trend Analysis"
input int HistoryDepth = 30;
input int TrendLookback = 5;
input int MinStreak = 3;
input int SignalCandleShift = 0;

input group "── Трейлинг ──"
// Унифицированный TrailingDispatcher (OFF / BREAKEVEN / SYNC). Default = BREAKEVEN.
// SYNC сейчас задокументированный no-op до экспорта SyncTrailManage.
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_BREAKEVEN_EX; // Режим трейлинга
input double                TrailingStartFactor   = 0.5;   // Множитель активации (profitPts >= factor * slDistPts)
input double                BreakevenOffsetPoints = 175;   // Оффсет для BREAKEVEN (пункты)
input double                SyncTrailStepPoints   = 0.0;   // Шаг для SYNC (пункты; 0 = любое улучшение)

input group "Session Filter"
input bool UseSessionFilter     = true;  // Включить сессионный фильтр
input int  AmericanCloseHour    = 21;    // Час закрытия Американской (серв.)
input int  AmericanCloseMinute  = 0;     // Минута закрытия Американской
input int  AsianOpenHour        = 0;     // Час открытия Азиатской (серв.)
input int  AsianOpenMinute      = 0;     // Минута открытия Азиатской
input int  SessionWindowMinutes = 5;     // Окно блокировки вокруг границы, мин

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

input group "Trend Filter (opt-in)"
// Тренд-фильтр opt-in: при UseTrendFilter=false (по умолчанию)
// TrendIsAllowed всегда возвращает true.
input bool            UseTrendFilter  = false;        // Включить тренд-фильтр
input ENUM_TIMEFRAMES TrendTimeframe  = PERIOD_M15;   // HTF для EMA/ADX
input int             TrendFastEMA    = 50;           // Период быстрой EMA
input int             TrendSlowEMA    = 200;          // Период медленной EMA
input bool            UseADXFilter    = false;        // Включить ADX/DI-фильтр
input int             ADXPeriod       = 14;           // Период ADX
input double          ADXMin          = 20.0;         // Минимум ADX для входа

//==========================================================================
// GLOBALS
//==========================================================================
// SessionFilter использует TimeCurrent(). В live разница с TimeTradeServer()
// в пределах секунды; в Strategy Tester модуль детерминирован.
// Диагностический Print в OnInit выводит TimeTradeServer().
SessionConfig g_session_cfg;
SessionState  g_session_state;

// Selected sessions filter. state хранит
// effectiveGmtOffsetSec, edge-trigger wasInsideOnPreviousTick и DST-кэш;
// cfg заполняется из input-параметров в OnInit. При UseSelectedSessions=false
// модуль не вызывается из OnTick.
SelectedSessionsConfig g_selected_cfg;
SelectedSessionsState  g_selected_state;

// BrokerContext: adjustedPoint, minBrokerDistance, fillType — заполняются BrokerInit.
BrokerContext g_broker;

// TrendFilter (opt-in). При UseTrendFilter=false TrendInit no-op и TrendIsAllowed → true.
TrendConfig  g_trend_cfg;
TrendHandles g_trend_h;

// TradeAdapter + TrailingConfig для TrailingDispatcher.
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//==========================================================================
// СЕССИИ — реализация в Include/SessionFilter.mqh
//==========================================================================

//+------------------------------------------------------------------+
//| LogSelectedSessionsSummary — одна сводная строка для журнала     |
//|                              терминала.                          |
//|                                                                  |
//| Формат: список выбранных сессий через запятую, эффективный       |
//| GMT-offset в часах, шесть пар HH:MM-HH:MM UTC-границ. Источник   |
//| границ — `SelectedSessionsGetEffective` (после возможного        |
//| broker-fallback в Init поля cfg уже актуальны).                  |
//+------------------------------------------------------------------+
void LogSelectedSessionsSummary()
  {
   string selected = "";
   if(g_selected_cfg.useAsian)   selected += (StringLen(selected) > 0 ? ",Asian"   : "Asian");
   if(g_selected_cfg.useLondon)  selected += (StringLen(selected) > 0 ? ",London"  : "London");
   if(g_selected_cfg.useNewYork) selected += (StringLen(selected) > 0 ? ",NewYork" : "NewYork");
   if(StringLen(selected) == 0)  selected = "none";

   long asS, asE, loS, loE, nyS, nyE;
   SelectedSessionsGetEffective(g_selected_cfg, g_selected_state,
                                asS, asE, loS, loE, nyS, nyE);

   const double offHrs = (double)g_selected_state.effectiveGmtOffsetSec / 3600.0;

   PrintFormat("⏰ Selected sessions ON | sessions=%s | gmt=%+.2fh | "
               "Asian=%02d:%02d-%02d:%02d | London=%02d:%02d-%02d:%02d | NY=%02d:%02d-%02d:%02d",
               selected, offHrs,
               (int)(asS / 3600), (int)((asS % 3600) / 60),
               (int)(asE / 3600), (int)((asE % 3600) / 60),
               (int)(loS / 3600), (int)((loS % 3600) / 60),
               (int)(loE / 3600), (int)((loE % 3600) / 60),
               (int)(nyS / 3600), (int)((nyS % 3600) / 60),
               (int)(nyE / 3600), (int)((nyE % 3600) / 60));
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   // Адаптация _Point по digits, fillType и min broker distance — внутри BrokerInit.
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   // TradeAdapter + TrailingConfig для TrailingDispatcher.
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

   PrintFormat("✅ Адаптация брокера: _Digits=%d | adjustedPoint=%.8f",
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               g_broker.adjustedPoint);

   // --- Заполняем SessionConfig из input-параметров ---
   g_session_cfg.enabled             = UseSessionFilter;
   g_session_cfg.americanCloseHour   = AmericanCloseHour;
   g_session_cfg.americanCloseMinute = AmericanCloseMinute;
   g_session_cfg.asianOpenHour       = AsianOpenHour;
   g_session_cfg.asianOpenMinute     = AsianOpenMinute;
   g_session_cfg.windowMinutes       = SessionWindowMinutes;

   // Инициализация state выполняется всегда: при UseSessionFilter=false
   // модуль всё равно вернёт false из всех проверочных функций.
   const bool sessionAutoDetected = SessionInit(g_session_cfg, g_session_state);

   if(UseSessionFilter)
   {
      MqlDateTime srv;
      TimeToStruct(TimeTradeServer(), srv);
      PrintFormat("🕐 Серверное время: %04d.%02d.%02d %02d:%02d:%02d",
                  srv.year, srv.mon, srv.day, srv.hour, srv.min, srv.sec);

      if(sessionAutoDetected)
         PrintFormat("✅ Сессии: АВТО | Закр. Амер: %02d:%02d | Откр. Азия: %02d:%02d | Окно: ±%d мин",
                     (int)(g_session_state.amCloseSec / 3600), (int)((g_session_state.amCloseSec % 3600) / 60),
                     (int)(g_session_state.asOpenSec  / 3600), (int)((g_session_state.asOpenSec  % 3600) / 60),
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
      Print("⏰ Сессионный фильтр выключен");
   }

   // --- Selected Sessions Filter ---
   // Заполнение cfg из input-параметров. Часы × 3600 + минуты × 60
   // даёт секунды суток UTC; gmtOffsetSeconds = часы × 3600.
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

   // Инициализация state выполняется всегда: SelectedSessionsInit при
   // невалидном cfg сам Print'ает диагностику и сбрасывает state в
   // безопасные нули. При UseSelectedSessions=false
   // OnTick prelude не вызывается — фильтр полностью прозрачен.
   const bool selected_ok = SelectedSessionsInit(g_selected_cfg, g_selected_state);

   if(!UseSelectedSessions)
      Print("⏰ Selected sessions filter OFF");
   else if(!selected_ok)
      Print("❌ Selected sessions filter: невалидная конфигурация — фильтр отключён");
   else
      LogSelectedSessionsSummary();

   // --- TrendFilter (opt-in) ---
   // ADX-фильтр гейтится UseTrendFilter (включение ADX отдельно от EMA
   // не имеет смысла в текущей архитектуре liq-grab).
   g_trend_cfg.useTrend  = UseTrendFilter;
   g_trend_cfg.useADX    = UseTrendFilter && UseADXFilter;
   g_trend_cfg.timeframe = TrendTimeframe;
   g_trend_cfg.fastEMA   = TrendFastEMA;
   g_trend_cfg.slowEMA   = TrendSlowEMA;
   g_trend_cfg.adxPeriod = ADXPeriod;
   g_trend_cfg.adxMin    = ADXMin;

   // При UseTrendFilter=false TrendInit no-op (все хэндлы → INVALID_HANDLE, return true).
   if(!TrendInit(g_trend_cfg, g_trend_h))
   {
      PrintFormat("❌ TrendFilter init failed | UseTrend=%s UseADX=%s | h.emaFast=%d h.emaSlow=%d h.adx=%d",
                  UseTrendFilter ? "true" : "false",
                  UseADXFilter   ? "true" : "false",
                  g_trend_h.emaFast, g_trend_h.emaSlow, g_trend_h.adx);
      return INIT_FAILED;
   }

   if(UseTrendFilter)
      PrintFormat("📈 TrendFilter: ON | TF=%s | EMA(%d,%d) | ADX=%s (period=%d, min=%.1f)",
                  EnumToString(TrendTimeframe), TrendFastEMA, TrendSlowEMA,
                  UseADXFilter ? "ON" : "OFF", ADXPeriod, ADXMin);
   else
      Print("📈 TrendFilter: OFF");

   PrintFormat("✅ LiqGrab | Magic: %d | TF: %s | FillType: %s",
               MagicNumber, EnumToString(TradingTimeframe), EnumToString(g_broker.fillType));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   TrendDeinit(g_trend_h);

   if(g_trade_adapter != NULL)
     {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
     }

   Print("✅ LiqGrab выгружен");
}

//+------------------------------------------------------------------+
//| Открытие сделки                                                  |
//+------------------------------------------------------------------+
// Спред и проскальзывание проверяет TradeExecutorSend (MaxSpreadToSL, MaxSlippageToSL).
// BrokerEnforceMinSLDist здесь же для caller-side пересчёта slPoints
// (TP = slPoints * rrRatio автоматически сохраняет RR при подтяжке SL).
void OpenTrade(ENUM_ORDER_TYPE orderType, double slPoints, double rrRatio)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (orderType == ORDER_TYPE_BUY) ? ask : bid;

   // Подъём SL до мин. дистанции тянет за собой tpPoints через RR.
   // TradeExecutorSend повторно вызовет BrokerEnforceMinSLDist (идемпотентно).
   const double sl_dist_pre  = slPoints * g_broker.adjustedPoint;
   double       sl_tentative = (orderType == ORDER_TYPE_BUY) ? (price - sl_dist_pre)
                                                             : (price + sl_dist_pre);
   BrokerEnforceMinSLDist(g_broker, orderType, price, sl_tentative);
   const double sl_dist_post = MathAbs(price - sl_tentative);
   if(sl_dist_post > sl_dist_pre + 0.5 * _Point)
   {
      slPoints = sl_dist_post / g_broker.adjustedPoint;
      PrintFormat("⚠️ SL→min: %.1f pts", slPoints);
   }

   const double tpPoints = slPoints * rrRatio;
   const double lot      = BrokerCalcLot(g_broker, RiskPercent, slPoints, LOT_BY_TICK_VALUE,
                                         MaxRiskOvershoot);
   if(lot <= 0.0) return;   // минимальный лот слишком рискованный — причина уже в журнале
   const double sl       = sl_tentative;
   const double tp       = (orderType == ORDER_TYPE_BUY)
                           ? price + tpPoints * g_broker.adjustedPoint
                           : price - tpPoints * g_broker.adjustedPoint;

   TradeOrderRequest req;
   req.orderType = orderType;
   req.price     = price;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = lot;
   req.comment   = StringFormat("LiqGrab TF:%s RR:%.1f", EnumToString(TradingTimeframe), rrRatio);
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   TradeResult result = TradeExecutorSend(trade, g_broker, req);
   if(!result.success && !result.skipped)   // пропуск по фильтру модуль уже записал в журнал
      PrintFormat("❌ Ошибка открытия: %u | %s", result.retcode, result.description);
   // Success-лог эмитит TradeExecutorSend в crt-bot-формате.
}

//+------------------------------------------------------------------+
//| Проверка сигналов на открытие                                    |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   ENUM_POSITION_TYPE dummy;
   if(PositionGuardHasOpen(MagicNumber, dummy)) return;
   if(SessionIsBoundary(g_session_cfg, g_session_state)) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, TradingTimeframe, 0, HistoryDepth, rates) < HistoryDepth) return;

   // Свеча, на которой ищем снятие ликвидности: 1 — последняя закрытая
   // (одна проверка на бар, вход на открытии следующей), 0 — формирующаяся.
   const int sig = UseClosedBarSignal ? 1 : 0;
   static datetime s_lastClosedCheck = 0;
   if(UseClosedBarSignal)
   {
      if(rates[0].time == s_lastClosedCheck) return;
      s_lastClosedCheck = rates[0].time;
   }

   int non_ghost_idx[];
   ArrayResize(non_ghost_idx, TrendLookback);
   int count = 0;
   for(int i = 1 + sig; i < HistoryDepth - 1 && count < TrendLookback; i++)
   {
      if(rates[i].high > rates[i+1].high || rates[i].low < rates[i+1].low)
      {
         non_ghost_idx[count] = i;
         count++;
      }
   }
   if(count < MinStreak) return;
   if(SignalCandleShift < 0 || SignalCandleShift >= count) return;

   int streak_high = 1;
   for(int k = 1; k < count; k++)
   {
      if(rates[non_ghost_idx[k-1]].high > rates[non_ghost_idx[k]].high) streak_high++;
      else break;
   }
   int streak_low = 1;
   for(int k = 1; k < count; k++)
   {
      if(rates[non_ghost_idx[k-1]].low < rates[non_ghost_idx[k]].low) streak_low++;
      else break;
   }

   int proposed_trend = 0;
   if(streak_high >= MinStreak && streak_low < MinStreak) proposed_trend = 1;
   else if(streak_low >= MinStreak && streak_high < MinStreak) proposed_trend = 2;

   static int current_trend = 0;
   if(proposed_trend != 0) current_trend = proposed_trend;
   if(current_trend == 0) return;

   int last_sig_idx = non_ghost_idx[SignalCandleShift];
   ENUM_ORDER_TYPE order_type = WRONG_VALUE;
   string signal_msg = "";
   bool signal_found = false;

   if(current_trend == 1)
   {
      double level = rates[last_sig_idx].low;
      bool swept    = rates[sig].low < level;
      bool returned = rates[sig].close > level;
      if(swept && returned)
      {
         order_type   = ORDER_TYPE_BUY;
         signal_msg   = "📈 Сигнал: BUY после снятия ликвидности Low в бычьем тренде (TF: " + EnumToString(TradingTimeframe) + ")";
         signal_found = true;
      }
   }
   else if(current_trend == 2)
   {
      double level = rates[last_sig_idx].high;
      bool swept    = rates[sig].high > level;
      bool returned = rates[sig].close < level;
      if(swept && returned)
      {
         order_type   = ORDER_TYPE_SELL;
         signal_msg   = "📉 Сигнал: SELL после снятия ликвидности High в медвежьем тренде (TF: " + EnumToString(TradingTimeframe) + ")";
         signal_found = true;
      }
   }

   if(!signal_found) return;

   static datetime last_entry_bar = 0;
   if(last_entry_bar == rates[0].time) return;
   last_entry_bar = rates[0].time;

   // TrendFilter применяется ДО открытия сделки. При UseTrendFilter=false
   // TrendIsAllowed → true.
   const int dirFromOrderType = (order_type == ORDER_TYPE_BUY) ? 1 : -1;
   if(!TrendIsAllowed(g_trend_cfg, g_trend_h, dirFromOrderType))
   {
      PrintFormat("🚫 TrendFilter блокирует %s по %s (UseTrend=%s UseADX=%s)",
                  (dirFromOrderType == 1 ? "BUY" : "SELL"),
                  _Symbol,
                  UseTrendFilter ? "true" : "false",
                  UseADXFilter   ? "true" : "false");
      return;
   }

   // Стоп: фиксированный или за экстремумом свечи, снявшей ликвидность.
   double slPoints = StopLossPoints;
   if(StopMode == SL_BEYOND_SWEEP)
   {
      const double entry   = (order_type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double extreme = (order_type == ORDER_TYPE_BUY) ? rates[sig].low : rates[sig].high;
      slPoints = MathAbs(entry - extreme) / g_broker.adjustedPoint + SweepSLBufferPoints;
      slPoints = MathMax(slPoints, MinSLPoints);
      if(slPoints > MaxSLPoints)
      {
         PrintFormat("🚫 SL за снятием %.0f пт > MaxSLPoints %.0f — вход пропущен", slPoints, MaxSLPoints);
         return;
      }
   }

   Print(signal_msg);

   OpenTrade(order_type, slPoints, RiskRewardRatio);
}

//+------------------------------------------------------------------+
//| Закрытие всех позиций                                            |
//+------------------------------------------------------------------+
// У liq-grab нет pending-ордеров → нет EA-prelude, просто делегат.
void CloseAllOpenPositions()
{
   Print("🔒 Закрытие всех позиций перед закрытием Американской сессии");
   PositionGuardCloseAll(trade, MagicNumber);
}

void CheckExitConditions() { /* заглушка */ }

//+------------------------------------------------------------------+
//| HandleSessionExitClose — закрытие позиций и отмена pending на    |
//|                          переходе inside → outside.              |
//|                                                                  |
//| Вызывается из OnTick prelude ровно один раз на                   |
//| Session_Exit_Event при `CloseOnSessionExit = true`. liq-grab не  |
//| держит явного EA-pending state (ни g_pending, ни g_pattern_*) —  |
//| только делегат к PositionGuard + диагностический Print           |
//| (anti-spam: вызывающий код гарантирует ровно один                |
//| вызов через edge-trigger `wasInsideOnPreviousTick`).             |
//|                                                                  |
//| UTC-время выхода берётся из                                      |
//| `g_selected_state.lastEvaluatedUtcSec` (секунды суток UTC,       |
//| обновлены `SelectedSessionsIsInside` внутри `DetectExit` на этом |
//| же тике) — детерминированно и без повторного обращения к         |
//| `TimeGMT()`.                                                     |
//+------------------------------------------------------------------+
void HandleSessionExitClose()
  {
   const int closed    = PositionGuardCloseAll(trade, MagicNumber);
   const int cancelled = PositionGuardCancelAllPending(trade, MagicNumber);

   const long t = g_selected_state.lastEvaluatedUtcSec;
   PrintFormat("⏰ Session exit | UTC=%02d:%02d:%02d | closed=%d | cancelled=%d",
               (int)(t / 3600), (int)((t % 3600) / 60), (int)(t % 60),
               closed, cancelled);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(UseSelectedSessions)
     {
      if(SelectedSessionsDetectExit(g_selected_cfg, g_selected_state))
        {
         if(CloseOnSessionExit)
            HandleSessionExitClose();
         return;
        }
      if(!SelectedSessionsIsInside(g_selected_cfg, g_selected_state))
         return;
     }
   if(SessionIsAmericanPreClose(g_session_cfg, g_session_state)) CloseAllOpenPositions();
   CheckEntrySignals();
   CheckExitConditions();
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);
}
//+------------------------------------------------------------------+