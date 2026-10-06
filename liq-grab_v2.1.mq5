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
#include "Include/TesterMetric.mqh"
//--- Создаем объект торгового класса
CTrade trade;

//==========================================================================
// INPUT GROUPS
//==========================================================================
// Где ставить стоп-лосс.
enum ENUM_LIQ_SL_MODE
{
   SL_FIXED        = 0,  // Фиксированно: StopLossPoints от цены входа
   SL_BEYOND_SWEEP = 1,  // За экстремумом свечи, снявшей ликвидность, + буфер
   SL_ATR          = 2   // AtrSLMultiplier × ATR(AtrPeriod) от цены входа
};

// Какой уровень ликвидности «снимается».
enum ENUM_LIQ_LEVEL_MODE
{
   LEVEL_STREAK     = 0,  // Экстремум свечи из цепочки по тренду (исходная логика)
   LEVEL_PREV_DAY   = 1,  // Максимум/минимум предыдущего дня
   LEVEL_ASIA_RANGE = 2   // Максимум/минимум Азиатской сессии (AsiaStartHour..AsiaEndHour)
};

// Где ставить тейк-профит.
enum ENUM_LIQ_TP_MODE
{
   TP_RR        = 0,  // RiskRewardRatio × SL
   TP_LIQUIDITY = 1   // Противоположный экстремум за HistoryDepth баров, если он ≥ MinLiquidityRR × SL, иначе RR
};

input group "Money Management"
input int MagicNumber = 71001; // Магический номер (уникальный для каждого бота)
input double RiskPercent = 3.0; // Риск на сделку в %
input double MaxRiskOvershoot = 1.5; // Пропуск сделки, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL   = 0.10; // Макс. спред как доля расстояния до SL (0.10 = 10%; 0 = выкл)
input double MaxSlippageToSL = 0.10; // Макс. проскальзывание как доля расстояния до SL (0 = без ограничения)

input group "Trade Parameters"
input ENUM_LIQ_SL_MODE StopMode = SL_FIXED; // Режим стоп-лосса (SL_BEYOND_SWEEP хуже на эталоне, см. tester/results)
input double StopLossPoints = 3175; // SL в пунктах (режим SL_FIXED)
input double SweepSLBufferPoints = 100;  // Буфер за экстремумом снятия, пункты (SL_BEYOND_SWEEP)
input double MinSLPoints = 1000;         // Мин. SL, пункты (SL_BEYOND_SWEEP)
input double MaxSLPoints = 6350;         // Макс. SL, пункты (SL_BEYOND_SWEEP, SL_ATR)
input int    AtrPeriod       = 14;       // Период ATR (SL_ATR)
input double AtrSLMultiplier = 1.5;      // SL = множитель × ATR (SL_ATR)
input double RiskRewardRatio = 2.0; // RR
input ENUM_LIQ_TP_MODE TPMode = TP_RR;   // Режим тейк-профита
input double MinLiquidityRR  = 1.5;      // Мин. RR для цели у противоположной ликвидности (TP_LIQUIDITY)
input int    MaxTradesPerDay    = 0;  // Макс. входов за день (серверное время), 0 = без лимита
input int    PauseAfterLosses   = 0;  // Пауза после N стопов подряд, 0 = выкл
input int    LossPauseMinutes   = 60; // Длительность паузы, мин
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M3;
input bool UseClosedBarSignal = true; // Сигнал по закрытой свече (false — внутри формирующейся, как раньше)
input ENUM_LIQ_LEVEL_MODE LevelMode = LEVEL_STREAK; // Уровень ликвидности
input int AsiaStartHour = 0;  // Начало Азиатской сессии, час (серверное время)
input int AsiaEndHour   = 7;  // Конец Азиатской сессии, час (серверное время)

input group "Trend Analysis"
input int HistoryDepth = 30;
input int TrendLookback = 5;
input int MinStreak = 3;
input int SignalCandleShift = 0;
input int TrendMaxAgeBars = 0; // Забыть тренд, если не подтверждался N баров (0 = никогда)

input group "── Трейлинг ──"
// Унифицированный TrailingDispatcher (OFF / BREAKEVEN / SYNC). Default = BREAKEVEN.
// SYNC сейчас задокументированный no-op до экспорта SyncTrailManage.
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_BREAKEVEN_EX; // Режим трейлинга
input double                TrailingStartFactor   = 0.5;   // Множитель активации (profitPts >= factor * slDistPts)
input double                BreakevenOffsetPoints = 175;   // Оффсет для BREAKEVEN (пункты)
input double                SyncTrailStepPoints   = 0.0;   // Шаг для SYNC (пункты; 0 = любое улучшение)

// Параметры сессий — общие для всех ботов (значения по умолчанию модуля).
#include "Include/Inputs/SessionInputs.mqh"

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
// BrokerContext: adjustedPoint, minBrokerDistance, fillType — заполняются BrokerInit.
BrokerContext g_broker;

// TrendFilter (opt-in). При UseTrendFilter=false TrendInit no-op и TrendIsAllowed → true.
TrendConfig  g_trend_cfg;
TrendHandles g_trend_h;

// ATR для StopMode = SL_ATR.
int g_atr_handle = INVALID_HANDLE;

// TradeAdapter + TrailingConfig для TrailingDispatcher.
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

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

   SessionsSetup();

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
   if(StopMode == SL_ATR)
   {
      g_atr_handle = iATR(_Symbol, TradingTimeframe, AtrPeriod);
      if(g_atr_handle == INVALID_HANDLE)
      {
         Print("❌ Не удалось создать ATR");
         return INIT_FAILED;
      }
   }

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
   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
   }

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
//| Лимиты частоты сделок: входов за день и пауза после серии стопов. |
//| Возвращает "" если вход разрешён, иначе причину.                 |
//+------------------------------------------------------------------+
string TradeFrequencyBlock()
{
   const datetime now = TimeCurrent();

   if(MaxTradesPerDay > 0)
   {
      const datetime dayStart = now - (now % 86400);
      if(!HistorySelect(dayStart, now)) return "";
      int entries = 0;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         const ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) entries++;
      }
      if(entries >= MaxTradesPerDay)
         return StringFormat("лимит %d входов за день", MaxTradesPerDay);
   }

   if(PauseAfterLosses > 0)
   {
      if(!HistorySelect(now - 7 * 86400, now)) return "";
      int      losses   = 0;
      datetime lastLoss = 0;
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
      {
         const ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         const double pnl = HistoryDealGetDouble(d, DEAL_PROFIT)
                          + HistoryDealGetDouble(d, DEAL_COMMISSION)
                          + HistoryDealGetDouble(d, DEAL_SWAP);
         if(pnl >= 0.0) break;   // серия убытков прервана
         if(lastLoss == 0) lastLoss = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         losses++;
      }
      if(losses >= PauseAfterLosses && now < lastLoss + LossPauseMinutes * 60)
         return StringFormat("пауза после %d стопов подряд до %s",
                             losses, TimeToString(lastLoss + LossPauseMinutes * 60, TIME_MINUTES));
   }
   return "";
}

//+------------------------------------------------------------------+
//| StreakSignal — исходная логика: тренд по цепочке экстремумов,    |
//| уровень — экстремум свечи из цепочки, снятие на свече `sig`.     |
//+------------------------------------------------------------------+
bool StreakSignal(const MqlRates &rates[], const int sig,
                  ENUM_ORDER_TYPE &order_type, string &signal_msg)
{
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
   if(count < MinStreak) return false;
   if(SignalCandleShift < 0 || SignalCandleShift >= count) return false;

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

   static int      current_trend    = 0;
   static datetime trend_confirmed  = 0;   // время бара последнего подтверждения тренда
   if(proposed_trend != 0)
   {
      current_trend   = proposed_trend;
      trend_confirmed = rates[0].time;
   }
   else if(TrendMaxAgeBars > 0 && current_trend != 0 &&
           rates[0].time - trend_confirmed > (datetime)TrendMaxAgeBars * PeriodSeconds(TradingTimeframe))
   {
      current_trend = 0;   // тренд устарел
   }
   if(current_trend == 0) return false;

   int last_sig_idx = non_ghost_idx[SignalCandleShift];

   if(current_trend == 1)
   {
      double level = rates[last_sig_idx].low;
      bool swept    = rates[sig].low < level;
      bool returned = rates[sig].close > level;
      if(swept && returned)
      {
         order_type   = ORDER_TYPE_BUY;
         signal_msg   = "📈 Сигнал: BUY после снятия ликвидности Low в бычьем тренде (TF: " + EnumToString(TradingTimeframe) + ")";
         return true;
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
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| KeyLevelSignal — снятие значимого уровня на закрытой свече [1]:  |
//| максимум/минимум предыдущего дня или Азиатской сессии.           |
//| Пробой максимума с закрытием ниже → SELL, минимума → BUY.        |
//| Один вход на каждую сторону уровня в день. `opposite` — другая   |
//| граница (цель для TP_LIQUIDITY).                                 |
//+------------------------------------------------------------------+
bool KeyLevelSignal(const MqlRates &rates[], ENUM_ORDER_TYPE &order_type,
                    string &signal_msg, double &opposite)
{
   const datetime barTime  = rates[1].time;
   const datetime dayStart = barTime - (barTime % 86400);
   double levelHigh = 0.0, levelLow = 0.0;
   string levelName = "";

   if(LevelMode == LEVEL_PREV_DAY)
   {
      const int shift = iBarShift(_Symbol, PERIOD_D1, barTime) + 1;   // день перед свечой сигнала
      levelHigh = iHigh(_Symbol, PERIOD_D1, shift);
      levelLow  = iLow(_Symbol, PERIOD_D1, shift);
      levelName = "пред. дня";
   }
   else
   {
      const datetime asiaFrom = dayStart + AsiaStartHour * 3600;
      const datetime asiaTo   = dayStart + AsiaEndHour * 3600 - 1;
      if(barTime < asiaTo) return false;   // диапазон Азии ещё не сформирован
      double hi[], lo[];
      if(CopyHigh(_Symbol, PERIOD_M1, asiaFrom, asiaTo, hi) <= 0) return false;
      if(CopyLow(_Symbol, PERIOD_M1, asiaFrom, asiaTo, lo) <= 0) return false;
      levelHigh = hi[ArrayMaximum(hi)];
      levelLow  = lo[ArrayMinimum(lo)];
      levelName = "Азии";
   }
   if(levelHigh <= 0.0 || levelLow <= 0.0) return false;

   static datetime s_highDay = 0, s_lowDay = 0;   // одна сделка на сторону уровня в день
   const string tf = EnumToString(TradingTimeframe);

   if(rates[1].high > levelHigh && rates[1].close < levelHigh && s_highDay != dayStart)
   {
      s_highDay  = dayStart;
      order_type = ORDER_TYPE_SELL;
      opposite   = levelLow;
      signal_msg = StringFormat("📉 Сигнал: SELL после снятия максимума %s %s (TF: %s)",
                                levelName, DoubleToString(levelHigh, _Digits), tf);
      return true;
   }
   if(rates[1].low < levelLow && rates[1].close > levelLow && s_lowDay != dayStart)
   {
      s_lowDay   = dayStart;
      order_type = ORDER_TYPE_BUY;
      opposite   = levelHigh;
      signal_msg = StringFormat("📈 Сигнал: BUY после снятия минимума %s %s (TF: %s)",
                                levelName, DoubleToString(levelLow, _Digits), tf);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Проверка сигналов на открытие                                    |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   ENUM_POSITION_TYPE dummy;
   if(PositionGuardHasOpen(MagicNumber, dummy)) return;
   if(SessionsIsBoundary()) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, TradingTimeframe, 0, HistoryDepth, rates) < HistoryDepth) return;

   // Свеча, на которой ищем снятие ликвидности: 1 — последняя закрытая
   // (одна проверка на бар, вход на открытии следующей), 0 — формирующаяся.
   const bool closedBar = UseClosedBarSignal || LevelMode != LEVEL_STREAK;
   const int  sig       = closedBar ? 1 : 0;
   static datetime s_lastClosedCheck = 0;
   if(closedBar)
   {
      if(rates[0].time == s_lastClosedCheck) return;
      s_lastClosedCheck = rates[0].time;
   }

   ENUM_ORDER_TYPE order_type = WRONG_VALUE;
   string signal_msg = "";
   double opposite   = 0.0;   // противоположный уровень (только для значимых уровней)
   const bool found = (LevelMode == LEVEL_STREAK)
                      ? StreakSignal(rates, sig, order_type, signal_msg)
                      : KeyLevelSignal(rates, order_type, signal_msg, opposite);
   if(!found) return;

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

   const string freqBlock = TradeFrequencyBlock();
   if(freqBlock != "")
   {
      PrintFormat("⏸️ Сигнал пропущен: %s", freqBlock);
      return;
   }

   const double entry = (order_type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                       : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Стоп: фиксированный, за экстремумом снятия или от ATR.
   double slPoints = StopLossPoints;
   if(StopMode == SL_ATR)
   {
      double atr[1];
      if(CopyBuffer(g_atr_handle, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) return;
      slPoints = MathMax(AtrSLMultiplier * atr[0] / g_broker.adjustedPoint, MinSLPoints);
      if(slPoints > MaxSLPoints)
      {
         PrintFormat("🚫 SL от ATR %.0f пт > MaxSLPoints %.0f — вход пропущен", slPoints, MaxSLPoints);
         return;
      }
   }
   else if(StopMode == SL_BEYOND_SWEEP)
   {
      const double extreme = (order_type == ORDER_TYPE_BUY) ? rates[sig].low : rates[sig].high;
      slPoints = MathAbs(entry - extreme) / g_broker.adjustedPoint + SweepSLBufferPoints;
      slPoints = MathMax(slPoints, MinSLPoints);
      if(slPoints > MaxSLPoints)
      {
         PrintFormat("🚫 SL за снятием %.0f пт > MaxSLPoints %.0f — вход пропущен", slPoints, MaxSLPoints);
         return;
      }
   }

   // Тейк: RR или противоположный экстремум (ближайшая ликвидность с той стороны).
   double rr = RiskRewardRatio;
   if(TPMode == TP_LIQUIDITY)
   {
      double target = opposite;
      if(target <= 0.0)
      {
         target = (order_type == ORDER_TYPE_BUY) ? rates[sig + 1].high : rates[sig + 1].low;
         for(int i = sig + 2; i < HistoryDepth; i++)
            target = (order_type == ORDER_TYPE_BUY) ? MathMax(target, rates[i].high)
                                                    : MathMin(target, rates[i].low);
      }
      const double liqRR = MathAbs(target - entry) / (slPoints * g_broker.adjustedPoint);
      const bool   ahead = (order_type == ORDER_TYPE_BUY) ? (target > entry) : (target < entry);
      if(ahead && liqRR >= MinLiquidityRR) rr = liqRR;
   }

   Print(signal_msg);

   OpenTrade(order_type, slPoints, rr);
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
   const ENUM_SESSION_STATE session = SessionsOnTick();
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      HandleSessionExitClose();
   if(session != SESSION_TRADING)
      return;
   if(SessionsIsPreClose()) CloseAllOpenPositions();
   CheckEntrySignals();
   CheckExitConditions();
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Журнал выходов (CSV) и критерий оптимизатора.                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   TradeJournalOnTransaction(trans, MagicNumber);
}

double OnTester()
{
   return TesterMetric();
}
