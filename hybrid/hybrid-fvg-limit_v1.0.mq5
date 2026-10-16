//+------------------------------------------------------------------+
//|                                       hybrid-fvg-limit_v1.0.mq5 |
//|  Лимитки от незакрытых разрывов (FVG) на H1. На каждом новом     |
//|  баре: незакрытые разрывы возрастом MinGapAgeBars … MaxGapAgeBars|
//|  в каждую сторону — GapsPerSide ближайших к цене; у них лимитки  |
//|  на ближнем крае по направлению разрыва (медвежий над ценой —    |
//|  продажа, бычий под ценой — покупка). Стоп — за дальним краем    |
//|  + отступ; размер разрыва и границы стопа — в долях ATR. Тейк —  |
//|  TakeProfitRR × стоп. Лимитка снимается через OrderExpiryBars    |
//|  баров или когда разрыв выпал из выбора / закрыт насквозь.       |
//|  Переключатели (выключены): частичное закрытие, трейлинг,        |
//|  фильтр новостей.                                                |
//|  Модули: Levels/FvgGaps, Exits/PartialClose, Exits/Trailing,     |
//|  Context/NewsTimes, Core/*. Отсев: tester/results/fvg-limit.md.  |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid FVG Limit v1.0 | лимитки от незакрытых разрывов, пороги в ATR, тейк 10R"

#include <Trade\Trade.mqh>
#include "../Include/Core/TradeAdapter.mqh"
#include "../Include/Core/BrokerAdapter.mqh"
#include "../Include/Core/PositionGuard.mqh"
#include "../Include/Core/TradeExecutor.mqh"
#include "../Include/Exits/Trailing/SyncTrail.mqh"
#include "../Include/Exits/Trailing/BreakevenTrail.mqh"
#include "../Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "../Include/Exits/PartialClose.mqh"
#include "../Include/Core/TesterMetric.mqh"
#include "../Include/Levels/FvgGaps.mqh"
#include "../Include/Context/NewsTimes.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены. Время — серверное.

input group "── Разрывы ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_H1;
input int    MinGapAgeBars   = 10;    // Мин. возраст разрыва: цена успела уйти (баров после 3-й свечи)
input int    MaxGapAgeBars   = 50;    // Разрывы старше не берём
input int    GapsPerSide     = 3;     // Сколько ближайших разрывов в каждую сторону держат лимитки
input int    OrderExpiryBars = 20;    // Срок лимитки, баров с первой постановки
input int    AtrPeriod       = 14;
input double MinGapATR       = 0.2;   // Мин. размер разрыва, доли ATR

input group "── Стоп / тейк ──"
input double StopBufferPoints = 300;  // Стоп за дальним краем + отступ (запас на спред)
input double MinStopATR       = 0.3;  // Стоп меньше — расширяется до этого, доли ATR
input double MaxStopATR       = 1.0;  // Стоп больше — разрыв пропускается, доли ATR
input double TakeProfitRR     = 10;   // Тейк = N × стоп

input group "── Частичное закрытие (по умолчанию выключено) ──"
input bool   UsePartialClose  = false;
input double PartialAtRR      = 5;    // При прибыли N × стоп
input double PartialFraction  = 0.5;  // закрыть такую долю объёма
input bool   PartialMoveToBE  = false;// и перенести стоп остатка в безубыток

input group "── Фильтр новостей (по умолчанию выключен) ──"
input int    AvoidNewsMinutes = 0;      // Не держать лимитки за N минут до и после новостей (0 = выкл.)
input bool   NewsNFP          = true;
input bool   NewsCPI          = true;
input bool   NewsFOMC         = true;
input bool   NewsISM          = true;

input group "── Управление капиталом ──"
input int    MagicNumber      = 71013;
input double RiskPercent      = 1.0;
input double MaxRiskOvershoot = 1.5;
input bool   OnePosition      = true;  // Одна позиция: пока она открыта, лимиток нет

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext      g_broker;
FvgConfig          g_cfg;
FvgGap             g_gaps[];
PartialCloseConfig g_part_cfg;
PartialCloseState  g_part;
datetime           g_news[];
datetime           g_lastBar = 0;
int                g_atr     = INVALID_HANDLE;
int g_cntGaps = 0, g_cntPlaced = 0, g_cntTouched = 0, g_cntRisk = 0, g_cntNews = 0;

void DeleteOrder(const ulong ticket)
  {
   if(ticket != 0 && PositionGuardPendingExists(ticket))
      trade.OrderDelete(ticket);
  }

void ClearOrders()
  {
   for(int i = 0; i < ArraySize(g_gaps); i++)
      if(g_gaps[i].ticket != 0)
        {
         DeleteOrder(g_gaps[i].ticket);
         g_gaps[i].ticket = 0;
        }
  }

// Лимитка разрыва i. Возврат: 1 — лимитка стоит (или временный отказ — повторим), 0 — разрыв
// убрать: риск минимального лота велик или цена уже прошла край и вход случился по рынку.
int PlaceOrder(const int i)
  {
   const FvgGap gp = g_gaps[i];
   const double entry = NormalizeDouble(gp.nearP, _Digits);
   const double sl    = NormalizeDouble(entry - gp.dir * gp.sd, _Digits);
   const double tp    = NormalizeDouble(entry + gp.dir * TakeProfitRR * gp.sd, _Digits);
   const double lot   = BrokerCalcLot(g_broker, RiskPercent, gp.sd / g_broker.adjustedPoint, LOT_BY_TICK_VALUE,
                                      MaxRiskOvershoot);
   if(lot <= 0.0)
     {
      g_cntRisk++;
      return 0;
     }
   TradeOrderRequest req;
   req.orderType = (gp.dir == 1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   req.price     = entry;
   req.sl        = sl;
   req.tp        = tp;
   req.lot       = lot;
   req.comment   = StringFormat("HFG %s", TimeToString(gp.t, TIME_DATE | TIME_MINUTES));
   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(!res.success)
      return 1;   // временный отказ — попробуем на следующем баре
   g_cntPlaced++;
   if(req.orderType == ORDER_TYPE_BUY || req.orderType == ORDER_TYPE_SELL)
     {
      PrintFormat("📌 Разрыв %s: цена уже за краем — вход по рынку", TimeToString(gp.t, TIME_DATE | TIME_MINUTES));
      return 0;
     }
   g_gaps[i].ticket = res.ticket;
   PrintFormat("📌 %s разрыв %s | вход %.3f SL %.3f (%.2f USD) TP %.3f | лимитка до %s",
               gp.dir == 1 ? "BUY LIMIT" : "SELL LIMIT", TimeToString(gp.t, TIME_DATE | TIME_MINUTES),
               entry, sl, gp.sd, tp,
               TimeToString(gp.first + (datetime)OrderExpiryBars * PeriodSeconds(TradingTimeframe), TIME_DATE | TIME_MINUTES));
   return 1;
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);
   PositionGuardCancelAllPending(trade, MagicNumber);   // лимитки прошлого запуска

   g_trade_adapter = new RealTradeAdapter(GetPointer(trade));
   if(g_trade_adapter == NULL)
      return INIT_FAILED;
   g_trail_cfg.mode            = TrailingMode;
   g_trail_cfg.startFactor     = TrailingStartFactor;
   g_trail_cfg.breakevenOffset = BreakevenOffsetPoints;
   g_trail_cfg.trailStep       = SyncTrailStepPoints;

   g_part_cfg.enabled  = UsePartialClose;
   g_part_cfg.atR      = PartialAtRR;
   g_part_cfg.fraction = PartialFraction;
   g_part_cfg.moveToBE = PartialMoveToBE;

   g_cfg.tf         = TradingTimeframe;
   g_cfg.minAge     = MinGapAgeBars;
   g_cfg.maxAge     = MaxGapAgeBars;
   g_cfg.expiryBars = OrderExpiryBars;
   g_cfg.perSide    = GapsPerSide;
   g_cfg.minGapAtr  = MinGapATR;
   g_cfg.minSlAtr   = MinStopATR;
   g_cfg.maxSlAtr   = MaxStopATR;
   g_cfg.buffer     = StopBufferPoints * g_broker.adjustedPoint;

   g_atr = iATR(_Symbol, TradingTimeframe, AtrPeriod);
   if(g_atr == INVALID_HANDLE)
     {
      Print("❌ Не удалось создать ATR");
      return INIT_FAILED;
     }
   if(AvoidNewsMinutes > 0)
      NewsBuildList(NewsNFP, NewsCPI, NewsFOMC, NewsISM, "", g_news);

   PrintFormat("✅ Hybrid FVG Limit v1.0 | Magic:%d TF:%s | возраст %d–%d, по %d в сторону, лимитка %d бар | "
               "разрыв ≥ %.2f ATR, стоп %.2f–%.2f ATR + %.0f пт | тейк %.1fR | частичное: %s | одна позиция: %s",
               MagicNumber, EnumToString(TradingTimeframe), MinGapAgeBars, MaxGapAgeBars, GapsPerSide, OrderExpiryBars,
               MinGapATR, MinStopATR, MaxStopATR, StopBufferPoints, TakeProfitRR,
               UsePartialClose ? StringFormat("%.0f%% на %.1fR%s", PartialFraction * 100, PartialAtRR,
                                              PartialMoveToBE ? " + безубыток" : "") : "выкл.",
               OnePosition ? "да" : "нет");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Разрывов найдено: %d | лимиток выставлено: %d | отработано касанием: %d | пропуск (риск мин. лота): %d | "
               "без лимиток из-за новостей: %d баров",
               g_cntGaps, g_cntPlaced, g_cntTouched, g_cntRisk, g_cntNews);
   if(!MQLInfoInteger(MQL_TESTER))
      ClearOrders();
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
   if(g_trade_adapter != NULL)
     {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
     }
  }

void OnTick()
  {
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);
   PartialCloseManage(trade, MagicNumber, g_part_cfg, g_part);

   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);
   if(OnePosition && hasPos)
      ClearOrders();   // исполнилась лимитка — остальные снимаем сразу

   const datetime bar = iTime(_Symbol, TradingTimeframe, 0);
   if(bar == g_lastBar)
      return;
   g_lastBar = bar;

   //--- учёт разрывов на закрытых барах
   double atr[1];
   if(CopyBuffer(g_atr, 0, 1, 1, atr) < 1)
      return;
   const int before = ArraySize(g_gaps);
   ulong drop[];
   const double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const int touched = FvgOnNewBar(g_cfg, g_gaps, atr[0], spread, drop);
   g_cntTouched += touched;
   for(int i = 0; i < ArraySize(drop); i++)
      DeleteOrder(drop[i]);
   for(int i = 0; i < ArraySize(g_gaps); i++)
      if(g_gaps[i].t == iTime(_Symbol, TradingTimeframe, 1))
         g_cntGaps++;

   //--- лимитки: только у выбранных, при открытом рынке, без открытой позиции (OnePosition)
   // лимитки стоят весь бар: блок, если новость в [сейчас − N мин, конец бара + N мин]
   const bool newsBlock = AvoidNewsMinutes > 0 &&
                          NewsInWindow(g_news, TimeCurrent(),
                                       AvoidNewsMinutes + PeriodSeconds(TradingTimeframe) / 60, AvoidNewsMinutes) > 0;
   if(newsBlock)
      g_cntNews++;
   const bool canPlace = BrokerIsTradeSessionOpen() && !(OnePosition && hasPos) && !newsBlock;
   for(int i = 0; i < ArraySize(g_gaps); i++)
     {
      if(!g_gaps[i].selected || !canPlace)
        {
         if(g_gaps[i].ticket != 0)
           {
            DeleteOrder(g_gaps[i].ticket);
            g_gaps[i].ticket = 0;
           }
         continue;
        }
      if(g_gaps[i].ticket != 0 && PositionGuardPendingExists(g_gaps[i].ticket))
         continue;
      g_gaps[i].ticket = 0;
      if(PlaceOrder(i) == 0)
        {
         FvgRemoveAt(g_gaps, i);   // риск мин. лота велик или вход уже случился по рынку
         i--;
        }
     }
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
