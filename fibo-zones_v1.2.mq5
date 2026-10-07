//+------------------------------------------------------------------+
//|                                              fibo-zones_v1.2.mq5 |
//|  Fibo Zones v1.2: зоны Фибоначчи у последней волны ATR-зигзага.  |
//|  Внутри волны — откат 0.382–0.5 по направлению волны (у          |
//|  подтверждённой и у текущей, ещё развивающейся волны); за        |
//|  границами диапазона — 1.212–1.272 / 1.618–1.762 (2.212–2.272    |
//|  выключена) в обе стороны на разворот. Вход лимиткой или по      |
//|  подтверждению. v1.2: учёт и удаление лимиток, перерыв рынка,   |
//|  одна лимитка на направление, лишние позиции закрываются.       |
//+------------------------------------------------------------------+
#property strict
#property description "Fibo Zones v1.2 | зоны Фибоначчи у последней волны ATR-зигзага | лимитка или подтверждение"

#include <Trade\Trade.mqh>
#include "Include/Core/TradeAdapter.mqh"
#include "Include/Core/BrokerAdapter.mqh"
#include "Include/Context/SessionFilter.mqh"
#include "Include/Core/PositionGuard.mqh"
#include "Include/Core/TradeExecutor.mqh"
#include "Include/Exits/Trailing/SyncTrail.mqh"
#include "Include/Exits/Trailing/BreakevenTrail.mqh"
#include "Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "Include/Core/TesterMetric.mqh"
#include "Include/Levels/AtrZigZag.mqh"
#include "Include/Levels/FiboZones.mqh"
#include "Include/Triggers/ZoneOrders.mqh"
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
input bool   UseZoneRetrace = true;   // Откат подтверждённой волны (крупные волны)
input bool   UseZoneRetraceLive = true; // Откат текущей волны: от последней точки до текущего экстремума
input double RetraceNear    = 0.382;
input double RetraceFar     = 0.5;
input bool   UseZoneExt1    = true;   // За диапазоном, в обе стороны
input double Ext1Near       = 1.212;
input double Ext1Far        = 1.272;
input bool   UseZoneExt2    = true;
input double Ext2Near       = 1.618;
input double Ext2Far        = 1.762;
input bool   UseZoneExt3    = false;  // 2.212–2.272: убыточна на подборе, по умолчанию выключена
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
#include "Include/Context/SessionInputs.mqh"

//── Состояние ─────────────────────────────────────────────────────────

#define FIBO_SLOTS 8   // 0 — откат подтверждённой волны; 1/2 — Ext1 сверху/снизу; 3/4 — Ext2; 5/6 — Ext3;
                      // 7 — откат текущей волны

BrokerContext g_broker;
int           g_atrHandle = INVALID_HANDLE;
datetime      g_lastBar   = 0;
bool          g_zzReady   = false;

// ATR-зигзаг (Include/Levels/AtrZigZag.mqh): волны и подтверждённые точки разворота.
AtrZigZag g_zz;

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

// Сделка зоны (FiboZone) — в Include/Levels/FiboZones.mqh.

// Ордера по зонам (Include/Triggers/ZoneOrders.mqh): учёт слотов, лимитки, подтверждение.
ZoneOrders       g_zo;
ZoneOrdersConfig g_zo_cfg;
datetime g_liveKey = 0;           // слот 7: время текущего экстремума волны (сменился — зона новая)

// Статистика за прогон (печатается в OnDeinit).
int g_cntRanges = 0;

//+------------------------------------------------------------------+
//| Зоны                                                             |
//+------------------------------------------------------------------+

// Доли волны и флаг включения для слота.
bool SlotLevels(const int slot, double &nearR, double &farR)
  {
   switch(slot)
     {
      case 0:  nearR = RetraceNear; farR = RetraceFar; return UseZoneRetrace;
      case 7:  nearR = RetraceNear; farR = RetraceFar; return UseZoneRetraceLive;
      case 1:
      case 2:  nearR = Ext1Near;    farR = Ext1Far;    return UseZoneExt1;
      case 3:
      case 4:  nearR = Ext2Near;    farR = Ext2Far;    return UseZoneExt2;
      default: nearR = Ext3Near;    farR = Ext3Far;    return UseZoneExt3;
     }
  }

// Цены зоны. Уровни отсчитываются от границ диапазона долями R = hi - lo:
// откат — от конца волны внутрь; за диапазоном сверху — lo + r·R, снизу — hi - r·R.
// Слот 7 — откат текущей волны: от последней подтверждённой точки до текущего экстремума.
bool BuildZone(const int slot, FiboZone &z)
  {
   double nearR, farR;
   if(!SlotLevels(slot, nearR, farR))
      return false;
   z.name = StringFormat("%.3f–%.3f", nearR, farR);

   if(slot == 7)
     {
      if(!g_zzReady || g_zz.dir == 0 || !AtrZigZagHasRange(g_zz))
         return false;
      // После минимума волна идёт вверх (покупка на откате), после максимума — вниз.
      const double start = (g_zz.dir == 1) ? g_zz.pivLo  : g_zz.pivHi;
      const double end   = (g_zz.dir == 1) ? g_zz.candHi : g_zz.candLo;
      const double W     = (g_zz.dir == 1) ? end - start : start - end;
      if(W <= 0.0 || W < MinRangePoints * g_broker.adjustedPoint)
         return false;
      FiboRetraceZone(start, end, nearR, farR, z);
      z.name = "откат текущей " + z.name;
      return true;
     }

   if(!g_range.valid)
      return false;
   if(slot == 0)
     {
      if(g_range.waveDir == 1)
         FiboRetraceZone(g_range.lo, g_range.hi, nearR, farR, z);
      else
         FiboRetraceZone(g_range.hi, g_range.lo, nearR, farR, z);
      z.name = "откат подтв. " + z.name;
     }
   else if(slot % 2 == 1)   // сверху: продажа на разворот, тейк — максимум диапазона
     {
      FiboExtZone(g_range.hi, g_range.lo, true, nearR, farR, z);
      z.name = "сверху " + z.name;
     }
   else                     // снизу: покупка на разворот, тейк — минимум диапазона
     {
      FiboExtZone(g_range.hi, g_range.lo, false, nearR, farR, z);
      z.name = "снизу " + z.name;
     }
   return true;
  }

// Слот 7: экстремум текущей волны сменился — прежняя зона больше не актуальна.
void SyncLiveSlot()
  {
   const datetime key = (g_zz.dir == 1) ? g_zz.candHiT : (g_zz.dir == -1 ? g_zz.candLoT : 0);
   if(key == g_liveKey)
      return;
   g_liveKey = key;
   ZoneOrdersRelease(g_zo, 7);
  }

// Все зоны текущего диапазона и текущей волны (ok[i] — зона i есть).
void BuildAllZones(FiboZone &zs[], bool &ok[])
  {
   for(int i = 0; i < FIBO_SLOTS; i++)
      ok[i] = BuildZone(i, zs[i]);
  }

//+------------------------------------------------------------------+
//| ATR-зигзаг по закрытым барам                                     |
//+------------------------------------------------------------------+

// Подтверждена новая точка разворота: диапазон — последняя подтверждённая волна.
void OnPivot(const bool log)
  {
   if(!AtrZigZagHasRange(g_zz))
      return;

   g_range.id++;
   g_range.hi      = g_zz.pivHi;
   g_range.lo      = g_zz.pivLo;
   g_range.waveDir = AtrZigZagWaveDir(g_zz);
   g_range.valid   = (g_zz.pivHi - g_zz.pivLo) >= MinRangePoints * g_broker.adjustedPoint;
   ZoneOrdersReset(g_zo, trade);
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
   if(AtrZigZagStep(g_zz, h, l, t, th) != 0)
      OnPivot(log);
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

   AtrZigZagReset(g_zz);
   g_range.valid = false;
   g_range.id    = 0;

   g_zo_cfg.magic            = MagicNumber;
   g_zo_cfg.tf               = TradingTimeframe;
   g_zo_cfg.riskPercent      = RiskPercent;
   g_zo_cfg.maxRiskOvershoot = MaxRiskOvershoot;
   g_zo_cfg.maxSpreadToSL    = MaxSpreadToSL;
   g_zo_cfg.maxSlippageToSL  = MaxSlippageToSL;
   g_zo_cfg.slBufferPoints   = SLBufferPoints;
   g_zo_cfg.minSLPoints      = MinSLPoints;
   g_zo_cfg.commentPrefix    = "FIBO";
   ZoneOrdersInit(g_zo, FIBO_SLOTS);
   g_liveKey = 0;

   PrintFormat("✅ Fibo Zones v1.2 | Magic:%d TF:%s | зигзаг %.1f×ATR(%d) | вход:%s | отступ %.0f пт | мин. стоп %.0f пт",
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
      string name = (i == 0) ? "откат подтв." : (i == 7 ? "откат текущей" : (i % 2 == 1 ? "сверху" : "снизу"));
      ZoneOrdersPrintSlot(g_zo, i, StringFormat("%s %.3f–%.3f", name, nearR, farR));
     }
   ZoneOrdersPrintTotals(g_zo);
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
      SyncLiveSlot();
     }

   const ENUM_SESSION_STATE session = SessionsOnTick();
   // Рынок закрыт по расписанию (ежедневный перерыв): ни выставить, ни снять ордер нельзя.
   if(!BrokerIsTradeSessionOpen())
      return;
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   ZoneOrdersCloseExtra(g_zo, trade, MagicNumber);
   ZoneOrdersSweepOrphans(g_zo, trade, MagicNumber);
   if(session != SESSION_TRADING || SessionsIsBoundary() || !g_zzReady)
     {
      ZoneOrdersCancelAll(g_zo, trade);   // вне торговли лимитки не держим
      return;
     }

   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);
   FiboZone zs[FIBO_SLOTS];
   bool     ok[FIBO_SLOTS];

   if(EntryMode == FIBO_ENTRY_CONFIRM)
     {
      if(newBar)
        {
         BuildAllZones(zs, ok);
         ZoneOrdersConfirm(g_zo, trade, g_broker, g_zo_cfg, zs, ok, !hasPos, g_range.id);
        }
      return;
     }

   if(hasPos)
     {
      ZoneOrdersCancelAll(g_zo, trade);
      return;
     }
   BuildAllZones(zs, ok);
   ZoneOrdersManageLimits(g_zo, trade, g_broker, g_zo_cfg, zs, ok, g_range.id);
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
