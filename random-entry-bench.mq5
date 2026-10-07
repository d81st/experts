//+------------------------------------------------------------------+
//|                                           random-entry-bench.mq5 |
//|  ИССЛЕДОВАТЕЛЬСКИЙ ЭТАЛОН — НЕ ДЛЯ ТОРГОВЛИ.                     |
//|  Случайные входы с тем же фильтром тренда, построением стопа,    |
//|  исполнением и выходом по времени, что у crt-bot. Показывает,    |
//|  сколько даёт само удержание позиции по тренду без сигнала:      |
//|  сигнал имеет смысл, только если он заметно лучше этого эталона. |
//+------------------------------------------------------------------+
#property strict
#property description "Исследовательский эталон: случайные входы (не для торговли)"

#include <Trade\Trade.mqh>
#include "Include/Core/BrokerAdapter.mqh"
#include "Include/Context/TrendFilter.mqh"
#include "Include/Core/PositionGuard.mqh"
#include "Include/Core/TradeExecutor.mqh"
#include "Include/Exits/TimeExit.mqh"
#include "Include/Core/TesterMetric.mqh"

input group "── Случайный вход ──"
input int             RandomSeed       = 1;     // Зерно генератора: разные зёрна — разные выборки
input double          EntryProbability = 0.02;  // Вероятность входа на каждом новом баре
input int             DirectionMode    = 0;     // 0 — случайно с учётом тренда; 1 — только покупки; -1 — только продажи

input group "── Как у crt-bot ──"
input int             MagicNumber      = 71099;
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M15;
input int             TimeExitBars     = 8;     // Выход через N баров (тейка нет)
input double          RiskPercent      = 1.0;
input double          MaxRiskOvershoot = 1.5;
input double          MaxSpreadToSL    = 0.10;
input double          MaxSlippageToSL  = 0.10;
input double          BufferPoints     = 200;   // Стоп за экстремумом двух последних баров + отступ, пункты
input double          MinSLPoints      = 2000;
input double          MaxSLPoints      = 20000;
input bool            UseTrendFilter   = true;
input ENUM_TIMEFRAMES TrendTimeframe   = PERIOD_H1;
input int             TrendFastEMA     = 50;
input int             TrendSlowEMA     = 200;

CTrade        trade;
BrokerContext g_broker;
TrendConfig   g_trend_cfg;
TrendHandles  g_trend_h;
datetime      g_last_bar = 0;

int OnInit()
  {
   MathSrand(RandomSeed);
   trade.SetExpertMagicNumber(MagicNumber);
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   g_trend_cfg.useTrend  = UseTrendFilter && DirectionMode == 0;
   g_trend_cfg.useADX    = false;
   g_trend_cfg.timeframe = TrendTimeframe;
   g_trend_cfg.fastEMA   = TrendFastEMA;
   g_trend_cfg.slowEMA   = TrendSlowEMA;
   g_trend_cfg.adxPeriod = 14;
   g_trend_cfg.adxMin    = 20.0;
   if(!TrendInit(g_trend_cfg, g_trend_h))
      return INIT_FAILED;

   PrintFormat("🎲 Random bench | seed:%d p:%.3f dir:%d TF:%s exit:%d bars",
               RandomSeed, EntryProbability, DirectionMode,
               EnumToString(TradingTimeframe), TimeExitBars);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   TrendDeinit(g_trend_h);
  }

void OnTick()
  {
   TimeExitManage(trade, MagicNumber, TradingTimeframe, TimeExitBars);

   const datetime bar = iTime(_Symbol, TradingTimeframe, 0);
   if(bar == g_last_bar)
      return;
   g_last_bar = bar;

   // Жребий тянется на каждом баре, чтобы выборка не зависела от открытых позиций.
   const bool draw = (MathRand() / 32768.0) < EntryProbability;
   int dir = ((MathRand() & 1) != 0) ? 1 : -1;
   if(!draw)
      return;

   ENUM_POSITION_TYPE type;
   if(PositionGuardHasOpen(MagicNumber, type))
      return;

   if(DirectionMode != 0)
      dir = (DirectionMode > 0) ? 1 : -1;
   else if(!TrendIsAllowed(g_trend_cfg, g_trend_h, dir))
     {
      dir = -dir;
      if(!TrendIsAllowed(g_trend_cfg, g_trend_h, dir))
         return;
     }

   // Стоп как у crt-bot: за экстремумом двух закрытых баров + отступ, в пределах [Min, Max].
   const double pt    = g_broker.adjustedPoint;
   const bool   buy   = (dir == 1);
   const double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ext   = buy ? MathMin(iLow(_Symbol, TradingTimeframe, 1), iLow(_Symbol, TradingTimeframe, 2))
                            : MathMax(iHigh(_Symbol, TradingTimeframe, 1), iHigh(_Symbol, TradingTimeframe, 2));
   double dist = buy ? (price - ext) : (ext - price);
   dist = MathMax(dist + BufferPoints * pt, MinSLPoints * pt);
   dist = MathMin(dist, MaxSLPoints * pt);

   TradeOrderRequest req;
   req.orderType = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price     = price;
   req.sl        = buy ? price - dist : price + dist;
   req.tp        = 0.0;
   req.lot       = BrokerCalcLot(g_broker, RiskPercent, dist / pt, LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(req.lot <= 0.0)
      return;
   req.comment         = StringFormat("RND_%s", buy ? "BUY" : "SELL");
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   const TradeResult result = TradeExecutorSend(trade, g_broker, req);
   if(!result.success && !result.skipped)
      PrintFormat("❌ Ошибка открытия: %u | %s", result.retcode, result.description);
  }

double OnTester()
  {
   return TesterMetric();
  }
//+------------------------------------------------------------------+
