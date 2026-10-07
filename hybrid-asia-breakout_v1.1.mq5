//+------------------------------------------------------------------+
//|                                    hybrid-asia-breakout_v1.1.mq5 |
//|  Пробой диапазона Азии на открытии Лондона (opening range        |
//|  breakout): коробка — максимум/минимум окна Азии (Levels/        |
//|  DayLevels); в окне входа первая сделка дня по пробою коробки —  |
//|  по касанию или по закрытию бара за ней; стоп — за противопо-    |
//|  ложной границей или серединой коробки; тейк — RR от стопа;      |
//|  незакрытая позиция закрывается в CloseHour.                     |
//|  v1.1: подключаемый режим рынка (Context/MarketRegime, выключен  |
//|  по умолчанию): только в тренде или во флэте — против пробоя     |
//|  (стоп за экстремумом пробоя, тейк RR).                          |
//|  Модули: Levels/DayLevels, Context/MarketRegime, Core/*,         |
//|  Exits/Trailing.                                                 |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Asia Breakout v1.1 | пробой диапазона Азии на открытии Лондона + режим рынка"

#include <Trade\Trade.mqh>
#include "Include/Core/TradeAdapter.mqh"
#include "Include/Core/BrokerAdapter.mqh"
#include "Include/Core/PositionGuard.mqh"
#include "Include/Core/TradeExecutor.mqh"
#include "Include/Exits/Trailing/SyncTrail.mqh"
#include "Include/Exits/Trailing/BreakevenTrail.mqh"
#include "Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "Include/Core/TesterMetric.mqh"
#include "Include/Levels/DayLevels.mqh"
#include "Include/Context/MarketRegime.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

enum ENUM_BREAKOUT_ENTRY
  {
   BREAKOUT_TOUCH = 0,  // Цена прошла границу коробки + отступ → рынок
   BREAKOUT_CLOSE = 1   // Бар TradingTimeframe закрылся за границей + отступ → рынок
  };

enum ENUM_BREAKOUT_SL
  {
   BREAKOUT_SL_OPPOSITE = 0,  // За противоположной границей коробки
   BREAKOUT_SL_MID      = 1   // За серединой коробки
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены. Время — серверное.

input group "── Коробка Азии ──"
input int    AsiaStartHour   = 0;      // Начало окна Азии, час
input int    AsiaEndHour     = 7;      // Конец окна Азии (не включая), час
input double MinBoxPoints    = 3000;   // Мин. размер коробки, пункты (меньше — день пропускаем)
input double MaxBoxPoints    = 0;      // Макс. размер коробки, пункты (больше — день пропускаем; 0 = без ограничения)

input group "── Вход ──"
input ENUM_BREAKOUT_ENTRY EntryMode = BREAKOUT_CLOSE;
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M15;  // Бар подтверждения (BREAKOUT_CLOSE)
input int    EntryEndHour     = 11;    // Окно входа: от конца Азии до этого часа (не включая)
input double BreakBufferPoints = 200;  // Отступ за границей коробки, пункты

input group "── Стоп / тейк / выход ──"
input ENUM_BREAKOUT_SL StopMode = BREAKOUT_SL_OPPOSITE;
input double SLBufferPoints = 200;     // Стоп за границей/серединой коробки + отступ
input double MinSLPoints    = 1000;    // Мин. стоп: более близкий расширяется до этого значения
input double RiskReward     = 1.5;     // Тейк = RiskReward × стоп (0 = без тейка)
input int    CloseHour      = 20;      // Закрыть позицию в этот час (0 = не закрывать)

input group "── Режим рынка (по умолчанию выключен) ──"
input ENUM_REGIME_MODE RegimeMode      = REGIME_OFF;  // Флэт: фильтр — день пропускаем, переключатель — против пробоя
input ENUM_TIMEFRAMES  RegimeTimeframe = PERIOD_H1;
input int              RegimePeriod    = 24;    // Баров для коэффициента эффективности
input double           RegimeThreshold = 0.30;  // ER ≥ порога — тренд, ниже — флэт

input group "── Управление капиталом ──"
input int    MagicNumber      = 71007;
input double RiskPercent      = 3.0;
input double MaxRiskOvershoot = 1.5;
input double MaxSpreadToSL    = 0.10;
input double MaxSlippageToSL  = 0.10;

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext g_broker;
MarketRegimeConfig g_regime;
int           g_cntRegimeSkip = 0, g_cntFade = 0;
datetime      g_lastBar  = 0;
datetime      g_boxDay   = 0;      // день, для которого построена коробка
bool          g_boxOk    = false;  // коробка годна для торговли сегодня
double        g_boxHi    = 0.0;
double        g_boxLo    = 0.0;
bool          g_traded   = false;  // сделка дня уже была (или день пропущен)
int           g_cntDays = 0, g_cntSkipSize = 0, g_cntTrades = 0, g_cntNoBreak = 0, g_cntTimeClose = 0;

int HourOf(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour;
  }

// Коробка дня: один раз, когда окно Азии закончилось.
void UpdateBox(const datetime now)
  {
   const datetime day = DayLevelsDayStart(now);
   if(g_boxDay == day)
      return;
   DayRange r;
   if(!DayLevelsHours(now, AsiaStartHour, AsiaEndHour, r))
      return;
   if(g_boxDay != 0 && g_boxOk && !g_traded)
      g_cntNoBreak++;
   g_boxDay = day;
   g_boxHi  = r.hi;
   g_boxLo  = r.lo;
   g_traded = false;
   g_cntDays++;
   const double size = (r.hi - r.lo) / g_broker.adjustedPoint;
   g_boxOk = (size >= MinBoxPoints && (MaxBoxPoints <= 0.0 || size <= MaxBoxPoints));
   if(!g_boxOk)
      g_cntSkipSize++;
   PrintFormat("📦 Азия %s: H=%.3f L=%.3f (%.2f USD)%s", TimeToString(day, TIME_DATE),
               r.hi, r.lo, r.hi - r.lo, g_boxOk ? "" : " — размер вне пределов, день пропущен");
  }

// Экстремум пробоя после конца Азии (по минуткам и текущей цене): для сделки dir против
// пробоя стоп ставится за ним — над максимумом для продажи, под минимумом для покупки.
double BreakExtreme(const int dir)
  {
   const datetime from = g_boxDay + AsiaEndHour * 3600;
   double v[];
   if(dir == -1)
     {
      double ext = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(CopyHigh(_Symbol, PERIOD_M1, from, TimeCurrent(), v) > 0)
         ext = MathMax(ext, v[ArrayMaximum(v)]);
      return MathMax(ext, g_boxHi);
     }
   double ext = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(CopyLow(_Symbol, PERIOD_M1, from, TimeCurrent(), v) > 0)
      ext = MathMin(ext, v[ArrayMinimum(v)]);
   return MathMin(ext, g_boxLo);
  }

// Пробой sig: +1 — вверх, -1 — вниз. Режим рынка решает направление сделки:
// по пробою, против него (флэт в режиме переключателя) или пропуск дня.
void EnterBreakout(const int sig)
  {
   const int dir = MarketRegimeApply(g_regime, sig);
   if(dir == 0)
     {
      g_traded = true;
      g_cntRegimeSkip++;
      PrintFormat("⏭ Пробой %s пропущен: флэт (ER %.2f < %.2f)", sig == 1 ? "вверх" : "вниз",
                  MarketRegimeER(g_regime), RegimeThreshold);
      return;
     }
   const bool fade = (dir != sig);
   const double pt    = g_broker.adjustedPoint;
   const double entry = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double anchor;
   if(fade)
      anchor = BreakExtreme(dir);
   else if(StopMode == BREAKOUT_SL_MID)
      anchor = (g_boxHi + g_boxLo) / 2.0;
   else
      anchor = (dir == 1) ? g_boxLo : g_boxHi;
   double sl = anchor - dir * SLBufferPoints * pt;
   if(dir * (entry - sl) < MinSLPoints * pt)
      sl = entry - dir * MinSLPoints * pt;
   sl = NormalizeDouble(sl, _Digits);
   const double dist = MathAbs(entry - sl);
   const double tp   = (RiskReward > 0.0) ? NormalizeDouble(entry + dir * RiskReward * dist, _Digits) : 0.0;

   g_traded = true;   // одна попытка в день
   const double lot = BrokerCalcLot(g_broker, RiskPercent, dist / pt, LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(lot <= 0.0)
     {
      PrintFormat("⏭ Пробой пропущен: стоп %.2f USD — мин. лот рискует > %.1f%% баланса",
                  dist, RiskPercent * MaxRiskOvershoot);
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = tp;
   req.lot             = lot;
   req.comment         = StringFormat("ASIA_BO %s%s", sig == 1 ? "up" : "down", fade ? " fade" : "");
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;
   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(res.success)
     {
      g_cntTrades++;
      if(fade)
         g_cntFade++;
      PrintFormat("🚀 Пробой %s коробки Азии%s | %s вход %.3f SL %.3f (%.2f USD) TP %.3f",
                  sig == 1 ? "вверх" : "вниз", fade ? " — флэт, против пробоя" : "",
                  dir == 1 ? "BUY" : "SELL", entry, sl, dist, tp);
     }
   else if(res.skipped)
      g_traded = false;   // фильтр (спред, пауза) — попробуем на следующем тике/баре
   else
      PrintFormat("❌ Вход по пробою не удался: %u %s", res.retcode, res.description);
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   g_trade_adapter = new RealTradeAdapter(GetPointer(trade));
   if(g_trade_adapter == NULL)
      return INIT_FAILED;
   g_trail_cfg.mode            = TrailingMode;
   g_trail_cfg.startFactor     = TrailingStartFactor;
   g_trail_cfg.breakevenOffset = BreakevenOffsetPoints;
   g_trail_cfg.trailStep       = SyncTrailStepPoints;
   g_regime.mode      = RegimeMode;
   g_regime.tf        = RegimeTimeframe;
   g_regime.period    = RegimePeriod;
   g_regime.threshold = RegimeThreshold;

   PrintFormat("✅ Hybrid Asia Breakout v1.1 | Magic:%d | Азия %d–%d | вход до %d:00 %s | стоп:%s | RR %.2f | закрытие %d:00",
               MagicNumber, AsiaStartHour, AsiaEndHour, EntryEndHour,
               EntryMode == BREAKOUT_TOUCH ? "по касанию" : "по закрытию " + EnumToString(TradingTimeframe),
               StopMode == BREAKOUT_SL_MID ? "середина" : "противоположная граница", RiskReward, CloseHour);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Дней: %d | пропущено по размеру коробки: %d | сделок: %d | без пробоя в окне: %d | закрыто по времени: %d",
               g_cntDays, g_cntSkipSize, g_cntTrades, g_cntNoBreak, g_cntTimeClose);
   if(RegimeMode != REGIME_OFF)
      PrintFormat("📊 Режим рынка: пропущено во флэте %d | против пробоя %d", g_cntRegimeSkip, g_cntFade);
   if(g_trade_adapter != NULL)
     {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
     }
  }

void OnTick()
  {
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);

   const datetime bar    = iTime(_Symbol, TradingTimeframe, 0);
   const bool     newBar = (bar != g_lastBar);
   if(newBar)
      g_lastBar = bar;

   if(!BrokerIsTradeSessionOpen())
      return;
   const datetime now  = TimeCurrent();
   const int      hour = HourOf(now);

   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);
   if(hasPos && CloseHour > 0 && hour >= CloseHour)
     {
      if(PositionGuardCloseAll(trade, MagicNumber) > 0)
         g_cntTimeClose++;
      return;
     }

   UpdateBox(now);
   if(hasPos || g_traded || !g_boxOk || g_boxDay != DayLevelsDayStart(now))
      return;
   if(hour < AsiaEndHour || hour >= EntryEndHour)
      return;

   const double buf = BreakBufferPoints * g_broker.adjustedPoint;
   if(EntryMode == BREAKOUT_TOUCH)
     {
      if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) >= g_boxHi + buf)
         EnterBreakout(1);
      else if(SymbolInfoDouble(_Symbol, SYMBOL_BID) <= g_boxLo - buf)
         EnterBreakout(-1);
      return;
     }
   if(!newBar)
      return;
   // Бар закрылся в окне входа (открылся не раньше конца Азии).
   if(iTime(_Symbol, TradingTimeframe, 1) < g_boxDay + AsiaEndHour * 3600)
      return;
   const double c1 = iClose(_Symbol, TradingTimeframe, 1);
   if(c1 > g_boxHi + buf)
      EnterBreakout(1);
   else if(c1 < g_boxLo - buf)
      EnterBreakout(-1);
  }

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
//+------------------------------------------------------------------+
