//+------------------------------------------------------------------+
//|                                              fibo-zones_v1.0.mq5 |
//|  Fibo Zones v1.0: зоны Фибоначчи у последней волны ATR-зигзага.  |
//|  Внутри волны — откат 0.382–0.5 по направлению волны; за         |
//|  границами диапазона — 1.212–1.272 / 1.618–1.762 / 2.212–2.272   |
//|  в обе стороны на разворот. Вход лимиткой или по подтверждению.  |
//+------------------------------------------------------------------+
#property strict
#property description "Fibo Zones v1.0 | зоны Фибоначчи у последней волны ATR-зигзага | лимитка или подтверждение"

#include <Trade\Trade.mqh>
#include "Include/TradeAdapter.mqh"
#include "Include/BrokerAdapter.mqh"
#include "Include/SessionFilter.mqh"
#include "Include/PositionGuard.mqh"
#include "Include/TradeExecutor.mqh"
#include "Include/Trailing/SyncTrail.mqh"
#include "Include/Trailing/BreakevenTrail.mqh"
#include "Include/Trailing/TrailingDispatcher.mqh"
#include "Include/TesterMetric.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//── Режим входа ──────────────────────────────────────────────────────
enum ENUM_FIBO_ENTRY
  {
   FIBO_ENTRY_LIMIT   = 0,  // Лимитка на ближнем краю зоны
   FIBO_ENTRY_CONFIRM = 1   // Касание зоны + закрытие бара обратно → рынок
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены.

input group "── Волна (ATR-зигзаг) ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M5;  // Таймфрейм волны, зон и входа
input int    ZigZagAtrPeriod  = 14;   // Период ATR
input double ZigZagAtrMult    = 3.0;  // Точка разворота подтверждается отходом цены на N × ATR
input int    ZigZagWarmupBars = 500;  // Баров истории для поиска волны при старте
input double MinRangePoints   = 0;    // Мин. размер волны, пункты (0 = без ограничения)

input group "── Зоны (доли волны) ──"
input bool   UseZoneRetrace = true;   // Откат внутри волны (по направлению волны)
input double RetraceNear    = 0.382;
input double RetraceFar     = 0.5;
input bool   UseZoneExt1    = true;   // За диапазоном, в обе стороны
input double Ext1Near       = 1.212;
input double Ext1Far        = 1.272;
input bool   UseZoneExt2    = true;
input double Ext2Near       = 1.618;
input double Ext2Far        = 1.762;
input bool   UseZoneExt3    = true;
input double Ext3Near       = 2.212;
input double Ext3Far        = 2.272;

input group "── Вход / стоп / тейк ──"
input ENUM_FIBO_ENTRY EntryMode = FIBO_ENTRY_LIMIT;
input double SLBufferPoints = 300;    // Стоп за дальним краем зоны + отступ (≈ спред + немного)
input double MinSLPoints    = 1000;   // Мин. стоп: более близкий стоп расширяется до этого значения
// Тейк: откат — конец волны (линия 0); зоны за диапазоном — пробитая граница диапазона.

input group "── Управление капиталом ──"
input int    MagicNumber      = 71004;  // Магический номер (уникальный для каждого бота)
input double RiskPercent      = 3.0;    // Риск на сделку, %
input double MaxRiskOvershoot = 1.5;    // Пропуск, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL    = 0.25;   // Вход по рынку: макс. спред как доля стопа (0 = выкл)
input double MaxSlippageToSL  = 0.10;   // Вход по рынку: макс. проскальзывание как доля стопа

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

// Параметры сессий: торгует круглосуточно, на выходе из сессии позиции не закрывает.
#define SESSION_DEFAULT_SELECTED      false
#define SESSION_DEFAULT_LONDON        false
#define SESSION_DEFAULT_CLOSE_ON_EXIT false
#include "Include/Inputs/SessionInputs.mqh"

//── Состояние ─────────────────────────────────────────────────────────

#define FIBO_SLOTS 7   // 0 — откат; 1/2 — Ext1 сверху/снизу; 3/4 — Ext2; 5/6 — Ext3

BrokerContext g_broker;
int           g_atrHandle = INVALID_HANDLE;
datetime      g_lastBar   = 0;
bool          g_zzReady   = false;

// ATR-зигзаг: 0 — направление не определено, +1 — после минимума ищем максимум, -1 — наоборот.
int      g_zzDir    = 0;
double   g_candHi   = 0.0, g_candLo = 0.0;
datetime g_candHiT  = 0,   g_candLoT = 0;
double   g_pivHi    = 0.0, g_pivLo = 0.0;
datetime g_pivHiT   = 0,   g_pivLoT = 0;

// Диапазон — последняя подтверждённая волна.
struct FiboRange
  {
   bool     valid;
   int      id;
   double   hi;
   double   lo;
   int      waveDir;   // +1 — волна вверх (минимум раньше максимума), -1 — вниз
  };
FiboRange g_range;

// Сделка зоны: направление, вход, стоп, тейк.
struct FiboZone
  {
   int    dir;      // +1 покупка, -1 продажа
   double nearP;    // ближний край (вход лимиткой)
   double farP;     // дальний край
   double tp;
   string name;
  };

bool     g_used[FIBO_SLOTS];      // зона уже торговалась в этом диапазоне
ulong    g_ticket[FIBO_SLOTS];    // тикет лимитки
bool     g_touched[FIBO_SLOTS];   // CONFIRM: цена заходила в зону
double   g_touchExt[FIBO_SLOTS];  // CONFIRM: экстремум касания

// Статистика за прогон (печатается в OnDeinit).
int g_cntRanges = 0;
int g_cntPlaced[FIBO_SLOTS], g_cntFilled[FIBO_SLOTS], g_cntPassed[FIBO_SLOTS];
int g_cntRisk[FIBO_SLOTS], g_cntWidened[FIBO_SLOTS];

//+------------------------------------------------------------------+
//| Зоны                                                             |
//+------------------------------------------------------------------+

// Доли волны и флаг включения для слота.
bool SlotLevels(const int slot, double &nearR, double &farR)
  {
   switch(slot)
     {
      case 0:  nearR = RetraceNear; farR = RetraceFar; return UseZoneRetrace;
      case 1:
      case 2:  nearR = Ext1Near;    farR = Ext1Far;    return UseZoneExt1;
      case 3:
      case 4:  nearR = Ext2Near;    farR = Ext2Far;    return UseZoneExt2;
      default: nearR = Ext3Near;    farR = Ext3Far;    return UseZoneExt3;
     }
  }

// Цены зоны. Уровни отсчитываются от границ диапазона долями R = hi - lo:
// откат — от конца волны внутрь; за диапазоном сверху — lo + r·R, снизу — hi - r·R.
bool BuildZone(const int slot, FiboZone &z)
  {
   if(!g_range.valid)
      return false;
   double nearR, farR;
   if(!SlotLevels(slot, nearR, farR))
      return false;

   const double R = g_range.hi - g_range.lo;
   z.name = StringFormat("%.3f–%.3f", nearR, farR);
   if(slot == 0)
     {
      z.dir = g_range.waveDir;
      if(z.dir == 1)
        { z.nearP = g_range.hi - nearR * R; z.farP = g_range.hi - farR * R; z.tp = g_range.hi; }
      else
        { z.nearP = g_range.lo + nearR * R; z.farP = g_range.lo + farR * R; z.tp = g_range.lo; }
      z.name = "откат " + z.name;
     }
   else if(slot % 2 == 1)   // сверху: продажа на разворот, тейк — максимум диапазона
     {
      z.dir = -1;
      z.nearP = g_range.lo + nearR * R; z.farP = g_range.lo + farR * R; z.tp = g_range.hi;
      z.name = "сверху " + z.name;
     }
   else                     // снизу: покупка на разворот, тейк — минимум диапазона
     {
      z.dir = 1;
      z.nearP = g_range.hi - nearR * R; z.farP = g_range.hi - farR * R; z.tp = g_range.lo;
      z.name = "снизу " + z.name;
     }
   return true;
  }

// Стоп за точкой farP + отступ; ближе MinSLPoints — расширяется до минимума.
double ZoneSL(const int slot, const FiboZone &z, const double entry, const double farP)
  {
   const double pt = g_broker.adjustedPoint;
   double sl = farP - z.dir * SLBufferPoints * pt;
   if(MathAbs(entry - sl) < MinSLPoints * pt)
     {
      sl = entry - z.dir * MinSLPoints * pt;
      g_cntWidened[slot]++;
     }
   return NormalizeDouble(sl, _Digits);
  }

//+------------------------------------------------------------------+
//| ATR-зигзаг по закрытым барам                                     |
//+------------------------------------------------------------------+

void ResetSlots()
  {
   PositionGuardCancelAllPending(trade, MagicNumber);
   for(int i = 0; i < FIBO_SLOTS; i++)
     {
      g_used[i] = false; g_ticket[i] = 0; g_touched[i] = false; g_touchExt[i] = 0.0;
     }
  }

void ConfirmPivot(const bool isHigh, const double price, const datetime t, const bool log)
  {
   if(isHigh) { g_pivHi = price; g_pivHiT = t; }
   else       { g_pivLo = price; g_pivLoT = t; }
   if(g_pivHiT == 0 || g_pivLoT == 0)
      return;

   g_range.id++;
   g_range.hi      = g_pivHi;
   g_range.lo      = g_pivLo;
   g_range.waveDir = (g_pivLoT < g_pivHiT) ? 1 : -1;
   g_range.valid   = (g_pivHi - g_pivLo) >= MinRangePoints * g_broker.adjustedPoint;
   ResetSlots();
   if(!log)
      return;
   g_cntRanges++;
   PrintFormat("📐 Диапазон #%d: H=%.3f L=%.3f R=%.2f USD | волна %s%s",
               g_range.id, g_range.hi, g_range.lo, g_range.hi - g_range.lo,
               g_range.waveDir == 1 ? "вверх" : "вниз",
               g_range.valid ? "" : " | меньше MinRangePoints — не торгуем");
  }

void ZigZagStep(const int shift, const bool log)
  {
   double atr[1];
   if(CopyBuffer(g_atrHandle, 0, shift, 1, atr) != 1 || atr[0] <= 0.0)
      return;
   const double   h  = iHigh(_Symbol, TradingTimeframe, shift);
   const double   l  = iLow(_Symbol, TradingTimeframe, shift);
   const datetime t  = iTime(_Symbol, TradingTimeframe, shift);
   const double   th = ZigZagAtrMult * atr[0];

   if(g_zzDir == 0)
     {
      if(g_candHiT == 0 || h > g_candHi) { g_candHi = h; g_candHiT = t; }
      if(g_candLoT == 0 || l < g_candLo) { g_candLo = l; g_candLoT = t; }
      if(g_candHiT < t && g_candHi - l >= th)
        { ConfirmPivot(true, g_candHi, g_candHiT, log); g_zzDir = -1; g_candLo = l; g_candLoT = t; }
      else if(g_candLoT < t && h - g_candLo >= th)
        { ConfirmPivot(false, g_candLo, g_candLoT, log); g_zzDir = 1; g_candHi = h; g_candHiT = t; }
      return;
     }
   if(g_zzDir == 1)
     {
      if(h > g_candHi) { g_candHi = h; g_candHiT = t; }
      else if(g_candHi - l >= th)
        { ConfirmPivot(true, g_candHi, g_candHiT, log); g_zzDir = -1; g_candLo = l; g_candLoT = t; }
     }
   else
     {
      if(l < g_candLo) { g_candLo = l; g_candLoT = t; }
      else if(h - g_candLo >= th)
        { ConfirmPivot(false, g_candLo, g_candLoT, log); g_zzDir = 1; g_candHi = h; g_candHiT = t; }
     }
  }

// Прогрев по истории (без журнала), затем по одному закрытому бару.
void ZigZagOnNewBar()
  {
   if(!g_zzReady)
     {
      const int bars = MathMin(ZigZagWarmupBars, Bars(_Symbol, TradingTimeframe) - 2);
      if(bars < ZigZagAtrPeriod + 2 || BarsCalculated(g_atrHandle) < bars + 1)
         return;
      for(int s = bars; s >= 2; s--)
         ZigZagStep(s, false);
      g_zzReady = true;
      if(g_range.valid)
         PrintFormat("📐 Стартовый диапазон #%d: H=%.3f L=%.3f | волна %s",
                     g_range.id, g_range.hi, g_range.lo, g_range.waveDir == 1 ? "вверх" : "вниз");
     }
   ZigZagStep(1, true);
  }

//+------------------------------------------------------------------+
//| Лимитки                                                          |
//+------------------------------------------------------------------+

double ZoneLot(const double entry, const double sl)
  {
   return BrokerCalcLot(g_broker, RiskPercent, MathAbs(entry - sl) / g_broker.adjustedPoint,
                        LOT_BY_TICK_VALUE, MaxRiskOvershoot);
  }

void ManageLimitSlot(const int slot)
  {
   if(g_used[slot])
      return;
   FiboZone z;
   if(!BuildZone(slot, z))
      return;

   if(g_ticket[slot] != 0)
     {
      // Лимитка исчезла: исполнена (или снята брокером) — зона отработана.
      if(!PositionGuardPendingExists(g_ticket[slot]))
        {
         g_ticket[slot] = 0;
         g_used[slot]   = true;
         g_cntFilled[slot]++;
        }
      return;
     }

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double entry = NormalizeDouble(z.nearP, _Digits);
   // Цена уже на зоне или за ней — лимитка не имеет смысла, зону пропускаем.
   if((z.dir == 1 && ask <= entry) || (z.dir == -1 && bid >= entry))
     {
      g_used[slot] = true;
      g_cntPassed[slot]++;
      return;
     }

   const double sl  = ZoneSL(slot, z, entry, z.farP);
   const double lot = ZoneLot(entry, sl);
   if(lot <= 0.0)
     {
      g_used[slot] = true;
      g_cntRisk[slot]++;
      PrintFormat("⏭ Зона %s пропущена: стоп %.2f USD — мин. лот рискует > %.1f%% баланса",
                  z.name, MathAbs(entry - sl), RiskPercent * MaxRiskOvershoot);
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (z.dir == 1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = NormalizeDouble(z.tp, _Digits);
   req.lot             = lot;
   req.comment         = StringFormat("FIBO_%d #%d", slot, g_range.id);
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(!res.success)
     {
      if(!res.skipped)
        {
         g_used[slot] = true;   // не повторяем отказ на каждом тике
         PrintFormat("❌ Лимитка зоны %s не выставлена: %u %s", z.name, res.retcode, res.description);
        }
      return;
     }
   g_cntPlaced[slot]++;
   // Лимитка могла сразу исполниться по рынку (цена ушла за уровень) — тогда тикета ордера нет.
   if(req.orderType == ORDER_TYPE_BUY || req.orderType == ORDER_TYPE_SELL)
     {
      g_used[slot] = true;
      g_cntFilled[slot]++;
     }
   else
      g_ticket[slot] = res.ticket;
   PrintFormat("📌 %s зона %s | вход %.3f SL %.3f (%.2f USD) TP %.3f | диапазон #%d",
               z.dir == 1 ? "BUY LIMIT" : "SELL LIMIT", z.name, entry, sl, MathAbs(entry - sl),
               req.tp, g_range.id);
  }

// Открыта сделка — остальные лимитки снимаем (вернутся после её закрытия).
void CancelOpenSlots()
  {
   for(int i = 0; i < FIBO_SLOTS; i++)
     {
      if(g_ticket[i] == 0)
         continue;
      if(PositionGuardPendingExists(g_ticket[i]))
         trade.OrderDelete(g_ticket[i]);
      else
        {
         g_used[i] = true;   // исчезла сама — значит, исполнена
         g_cntFilled[i]++;
        }
      g_ticket[i] = 0;
     }
  }

//+------------------------------------------------------------------+
//| Вход по подтверждению (закрытый бар)                             |
//+------------------------------------------------------------------+

void ManageConfirmSlot(const int slot, const bool canEnter)
  {
   if(g_used[slot])
      return;
   FiboZone z;
   if(!BuildZone(slot, z))
      return;

   const double h1 = iHigh(_Symbol, TradingTimeframe, 1);
   const double l1 = iLow(_Symbol, TradingTimeframe, 1);
   const double c1 = iClose(_Symbol, TradingTimeframe, 1);

   if(z.dir == -1 ? (h1 >= z.nearP) : (l1 <= z.nearP))
     {
      if(!g_touched[slot])
         g_touchExt[slot] = (z.dir == -1) ? h1 : l1;
      g_touched[slot]  = true;
      g_touchExt[slot] = (z.dir == -1) ? MathMax(g_touchExt[slot], h1) : MathMin(g_touchExt[slot], l1);
     }
   if(!g_touched[slot])
      return;
   if(z.dir == -1 ? (c1 >= z.nearP) : (c1 <= z.nearP))
      return;   // бар ещё не закрылся обратно из зоны
   if(!canEnter)
     {
      g_touched[slot] = false;   // подтверждение пришлось на открытую сделку — ждём нового касания
      return;
     }

   const double entry = (z.dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double farP  = (z.dir == -1) ? MathMax(z.farP, g_touchExt[slot]) : MathMin(z.farP, g_touchExt[slot]);
   const double sl    = ZoneSL(slot, z, entry, farP);
   const double lot   = ZoneLot(entry, sl);
   g_used[slot] = true;
   if(lot <= 0.0)
     {
      g_cntRisk[slot]++;
      PrintFormat("⏭ Зона %s пропущена: стоп %.2f USD — мин. лот рискует > %.1f%% баланса",
                  z.name, MathAbs(entry - sl), RiskPercent * MaxRiskOvershoot);
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (z.dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = NormalizeDouble(z.tp, _Digits);
   req.lot             = lot;
   req.comment         = StringFormat("FIBO_%d #%d", slot, g_range.id);
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;

   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(res.success)
     {
      g_cntPlaced[slot]++;
      g_cntFilled[slot]++;
      PrintFormat("✅ %s по подтверждению, зона %s | SL %.3f (%.2f USD) TP %.3f | диапазон #%d",
                  z.dir == 1 ? "BUY" : "SELL", z.name, sl, MathAbs(entry - sl), req.tp, g_range.id);
     }
   else if(!res.skipped)
      PrintFormat("❌ Вход в зоне %s не удался: %u %s", z.name, res.retcode, res.description);
  }

//+------------------------------------------------------------------+
//| OnInit / OnDeinit                                                |
//+------------------------------------------------------------------+

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

   g_atrHandle = iATR(_Symbol, TradingTimeframe, ZigZagAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("❌ Не удалось создать ATR");
      return INIT_FAILED;
     }
   SessionsSetup();

   g_range.valid = false;
   g_range.id    = 0;
   for(int i = 0; i < FIBO_SLOTS; i++)
     {
      g_used[i] = false; g_ticket[i] = 0; g_touched[i] = false; g_touchExt[i] = 0.0;
      g_cntPlaced[i] = 0; g_cntFilled[i] = 0; g_cntPassed[i] = 0; g_cntRisk[i] = 0; g_cntWidened[i] = 0;
     }

   PrintFormat("✅ Fibo Zones v1.0 | Magic:%d TF:%s | зигзаг %.1f×ATR(%d) | вход:%s | отступ %.0f пт | мин. стоп %.0f пт",
               MagicNumber, EnumToString(TradingTimeframe), ZigZagAtrMult, ZigZagAtrPeriod,
               EntryMode == FIBO_ENTRY_LIMIT ? "LIMIT" : "CONFIRM", SLBufferPoints, MinSLPoints);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Диапазонов: %d", g_cntRanges);
   for(int i = 0; i < FIBO_SLOTS; i++)
     {
      double nearR, farR;
      if(!SlotLevels(i, nearR, farR))
         continue;
      string name = (i == 0) ? "откат" : (i % 2 == 1 ? "сверху" : "снизу");
      PrintFormat("📊 Зона %s %.3f–%.3f: ордеров %d | исполнено %d | цена уже за зоной %d | риск велик %d | стоп расширен %d",
                  name, nearR, farR, g_cntPlaced[i], g_cntFilled[i], g_cntPassed[i], g_cntRisk[i], g_cntWidened[i]);
     }
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_trade_adapter != NULL)
     {
      delete g_trade_adapter;
      g_trade_adapter = NULL;
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+

void OnTick()
  {
   // Трейлинг и поиск волны — независимо от сессии.
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);

   const datetime bar    = iTime(_Symbol, TradingTimeframe, 0);
   const bool     newBar = (bar != g_lastBar);
   if(newBar)
     {
      g_lastBar = bar;
      ZigZagOnNewBar();
     }

   const ENUM_SESSION_STATE session = SessionsOnTick();
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   if(session != SESSION_TRADING || SessionsIsBoundary() || !g_zzReady)
     {
      CancelOpenSlots();   // вне торговли лимитки не держим
      return;
     }

   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);

   if(EntryMode == FIBO_ENTRY_CONFIRM)
     {
      if(newBar)
         for(int i = 0; i < FIBO_SLOTS; i++)
            ManageConfirmSlot(i, !hasPos);
      return;
     }

   if(hasPos)
     {
      CancelOpenSlots();
      return;
     }
   for(int i = 0; i < FIBO_SLOTS; i++)
      ManageLimitSlot(i);
  }

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
//+------------------------------------------------------------------+
