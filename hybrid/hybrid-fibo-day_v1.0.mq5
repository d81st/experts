//+------------------------------------------------------------------+
//|                                        hybrid-fibo-day_v1.0.mq5 |
//|  Гибрид №1: зоны Фибоначчи (Fibo Zones) от дневного диапазона    |
//|  ликвидности (liq-grab) вместо волны зигзага. Диапазон —         |
//|  предыдущий день или окно часов (Азия 0–7): каждый день одна     |
//|  однозначная «волна». Зоны: откат 0.382–0.5 по направлению волны |
//|  дня, 1.212–1.272 / 1.618–1.762 за диапазоном в обе стороны.     |
//|  Модули: Levels/DayLevels, Levels/FiboZones, Triggers/ZoneOrders.|
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Fibo Day v1.0 | фибо-зоны от диапазона прошлого дня или Азии | лимитка или подтверждение"

#include <Trade\Trade.mqh>
#include "../Include/Core/TradeAdapter.mqh"
#include "../Include/Core/BrokerAdapter.mqh"
#include "../Include/Context/SessionFilter.mqh"
#include "../Include/Core/PositionGuard.mqh"
#include "../Include/Core/TradeExecutor.mqh"
#include "../Include/Exits/Trailing/SyncTrail.mqh"
#include "../Include/Exits/Trailing/BreakevenTrail.mqh"
#include "../Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "../Include/Core/TesterMetric.mqh"
#include "../Include/Levels/DayLevels.mqh"
#include "../Include/Levels/FiboZones.mqh"
#include "../Include/Triggers/ZoneOrders.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//── Источник диапазона и режим входа ─────────────────────────────────
enum ENUM_DAY_RANGE_SOURCE
  {
   DAY_RANGE_PREV_DAY = 0,  // Предыдущий день (D1)
   DAY_RANGE_HOURS    = 1   // Окно часов текущего дня (Азия и т. п.)
  };

enum ENUM_HYBRID_ENTRY
  {
   HYBRID_ENTRY_LIMIT   = 0,  // Лимитка на ближнем краю зоны
   HYBRID_ENTRY_CONFIRM = 1   // Касание зоны + закрытие бара обратно → рынок
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены.

input group "── Диапазон ──"
input ENUM_DAY_RANGE_SOURCE RangeSource = DAY_RANGE_PREV_DAY;
input int    RangeStartHour = 0;     // Окно часов: начало (серверное время), DAY_RANGE_HOURS
input int    RangeEndHour   = 7;     // Окно часов: конец (не включая), DAY_RANGE_HOURS
input double MinRangePoints = 0;     // Мин. размер диапазона, пункты (0 = без ограничения)

input group "── Зоны (доли диапазона) ──"
input bool   UseZoneRetrace = true;  // Откат 0.382–0.5 по направлению волны дня
input double RetraceNear    = 0.382;
input double RetraceFar     = 0.5;
input bool   UseZoneExt1    = true;  // За диапазоном, в обе стороны
input double Ext1Near       = 1.212;
input double Ext1Far        = 1.272;
input bool   UseZoneExt2    = true;
input double Ext2Near       = 1.618;
input double Ext2Far        = 1.762;
input bool   UseZoneExt3    = false;
input double Ext3Near       = 2.212;
input double Ext3Far        = 2.272;

input group "── Вход / стоп / тейк ──"
input ENUM_HYBRID_ENTRY EntryMode   = HYBRID_ENTRY_LIMIT;
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M5;  // Бар подтверждения (режим CONFIRM)
input double SLBufferPoints = 300;   // Стоп за дальним краем зоны + отступ
input double MinSLPoints    = 1000;  // Мин. стоп: более близкий расширяется до этого значения
input double AskShiftPoints = 0;      // Сдвиг цен по Ask (вход Buy Limit, стоп/тейк продажи) ≈ спред, 0 = выкл
// Тейк: откат — конец волны дня; зоны за диапазоном — пробитая граница диапазона.

input group "── Управление капиталом ──"
input int    MagicNumber      = 71005;
input double RiskPercent      = 3.0;
input double MaxRiskOvershoot = 1.5;   // Пропуск, если мин. лот рискует > RiskPercent × N (0 = выкл)
input double MaxSpreadToSL    = 0.25;  // Вход по рынку: макс. спред как доля стопа (0 = выкл)
input double MaxSlippageToSL  = 0.10;  // Вход по рынку: макс. проскальзывание как доля стопа
input bool   CloseOnSlippage  = false; // Вход по рынку исполнился хуже допуска — сразу закрыть

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

// Сессии: торгует круглосуточно, на выходе из сессии позиции не закрывает.
#define SESSION_DEFAULT_SELECTED      false
#define SESSION_DEFAULT_LONDON        false
#define SESSION_DEFAULT_CLOSE_ON_EXIT false
#include "../Include/Context/SessionInputs.mqh"

//── Состояние ─────────────────────────────────────────────────────────

#define DAY_SLOTS 7   // 0 — откат; 1/2 — Ext1 сверху/снизу; 3/4 — Ext2; 5/6 — Ext3

BrokerContext    g_broker;
ZoneOrders       g_zo;
ZoneOrdersConfig g_zo_cfg;
datetime         g_lastBar = 0;

struct DayFiboRange
  {
   bool     valid;
   int      id;
   datetime day;      // день, для которого действует диапазон
   double   hi;
   double   lo;
   int      waveDir;  // +1 — минимум раньше максимума (волна вверх), -1 — вниз
  };
DayFiboRange g_range;
datetime     g_rangeDone = 0;   // день, для которого диапазон уже построен (годный или нет)
int          g_cntRanges = 0;

//+------------------------------------------------------------------+
//| Зоны                                                             |
//+------------------------------------------------------------------+

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

bool BuildZone(const int slot, FiboZone &z)
  {
   if(!g_range.valid)
      return false;
   double nearR, farR;
   if(!SlotLevels(slot, nearR, farR))
      return false;
   z.name = StringFormat("%.3f–%.3f", nearR, farR);
   if(slot == 0)
     {
      if(g_range.waveDir == 1)
         FiboRetraceZone(g_range.lo, g_range.hi, nearR, farR, z);
      else
         FiboRetraceZone(g_range.hi, g_range.lo, nearR, farR, z);
      z.name = "откат " + z.name;
     }
   else
     {
      FiboExtZone(g_range.hi, g_range.lo, slot % 2 == 1, nearR, farR, z);
      z.name = (slot % 2 == 1 ? "сверху " : "снизу ") + z.name;
     }
   return true;
  }

void BuildAllZones(FiboZone &zs[], bool &ok[])
  {
   for(int i = 0; i < DAY_SLOTS; i++)
      ok[i] = BuildZone(i, zs[i]);
  }

//+------------------------------------------------------------------+
//| Диапазон дня: один раз в день, как только он сформирован.        |
//| В новый день прежние зоны снимаются, даже если новый диапазон    |
//| ещё не готов (окно часов не закончилось).                        |
//+------------------------------------------------------------------+
void UpdateRange()
  {
   const datetime now = TimeCurrent();
   const datetime day = DayLevelsDayStart(now);
   if(g_rangeDone == day)
      return;

   DayRange r;
   const bool ready = (RangeSource == DAY_RANGE_PREV_DAY)
                      ? DayLevelsPrevDay(now, true, r)
                      : DayLevelsHours(now, RangeStartHour, RangeEndHour, r);
   if(!ready)
     {
      if(g_range.valid)
        {
         g_range.valid = false;
         ZoneOrdersReset(g_zo, trade);
        }
      return;
     }

   g_rangeDone = day;
   g_range.id++;
   g_range.day     = day;
   g_range.hi      = r.hi;
   g_range.lo      = r.lo;
   g_range.waveDir = (r.loTime < r.hiTime) ? 1 : -1;
   g_range.valid   = (r.hi - r.lo) >= MinRangePoints * g_broker.adjustedPoint;
   ZoneOrdersReset(g_zo, trade);
   g_cntRanges++;
   PrintFormat("📐 Диапазон #%d (%s): H=%.3f L=%.3f R=%.2f USD | волна %s%s",
               g_range.id, RangeSource == DAY_RANGE_PREV_DAY ? "прошлый день" : "окно часов",
               g_range.hi, g_range.lo, g_range.hi - g_range.lo,
               g_range.waveDir == 1 ? "вверх" : "вниз",
               g_range.valid ? "" : " | меньше MinRangePoints — не торгуем");
  }

//+------------------------------------------------------------------+
//| OnInit / OnDeinit                                                |
//+------------------------------------------------------------------+

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   TradeExecutorSetCloseOnSlippage(CloseOnSlippage);
   BrokerInit(g_broker);
   trade.SetTypeFilling(g_broker.fillType);

   g_trade_adapter = new RealTradeAdapter(GetPointer(trade));
   if(g_trade_adapter == NULL)
      return INIT_FAILED;
   g_trail_cfg.mode            = TrailingMode;
   g_trail_cfg.startFactor     = TrailingStartFactor;
   g_trail_cfg.breakevenOffset = BreakevenOffsetPoints;
   g_trail_cfg.trailStep       = SyncTrailStepPoints;
   SessionsSetup();

   g_range.valid = false;
   g_range.id    = 0;
   g_range.day   = 0;
   g_rangeDone   = 0;

   g_zo_cfg.magic            = MagicNumber;
   g_zo_cfg.tf               = TradingTimeframe;
   g_zo_cfg.riskPercent      = RiskPercent;
   g_zo_cfg.maxRiskOvershoot = MaxRiskOvershoot;
   g_zo_cfg.maxSpreadToSL    = MaxSpreadToSL;
   g_zo_cfg.maxSlippageToSL  = MaxSlippageToSL;
   g_zo_cfg.slBufferPoints   = SLBufferPoints;
   g_zo_cfg.minSLPoints      = MinSLPoints;
   g_zo_cfg.commentPrefix    = "HFD";
   g_zo_cfg.askShiftPoints   = AskShiftPoints;
   ZoneOrdersInit(g_zo, DAY_SLOTS);

   PrintFormat("✅ Hybrid Fibo Day v1.0 | Magic:%d | диапазон: %s | вход:%s TF:%s | отступ %.0f пт | мин. стоп %.0f пт",
               MagicNumber,
               RangeSource == DAY_RANGE_PREV_DAY ? "прошлый день"
                                                 : StringFormat("часы %d–%d", RangeStartHour, RangeEndHour),
               EntryMode == HYBRID_ENTRY_LIMIT ? "LIMIT" : "CONFIRM", EnumToString(TradingTimeframe),
               SLBufferPoints, MinSLPoints);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Диапазонов: %d", g_cntRanges);
   for(int i = 0; i < DAY_SLOTS; i++)
     {
      double nearR, farR;
      if(!SlotLevels(i, nearR, farR))
         continue;
      const string name = (i == 0) ? "откат" : (i % 2 == 1 ? "сверху" : "снизу");
      ZoneOrdersPrintSlot(g_zo, i, StringFormat("%s %.3f–%.3f", name, nearR, farR));
     }
   ZoneOrdersPrintTotals(g_zo);
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
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);

   const datetime bar    = iTime(_Symbol, TradingTimeframe, 0);
   const bool     newBar = (bar != g_lastBar);
   if(newBar)
      g_lastBar = bar;

   const ENUM_SESSION_STATE session = SessionsOnTick();
   // Рынок закрыт по расписанию (ежедневный перерыв): ни выставить, ни снять ордер нельзя.
   if(!BrokerIsTradeSessionOpen())
      return;
   UpdateRange();
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   ZoneOrdersCloseExtra(g_zo, trade, MagicNumber);
   ZoneOrdersSweepOrphans(g_zo, trade, MagicNumber);
   if(session != SESSION_TRADING || SessionsIsBoundary() || !g_range.valid)
     {
      ZoneOrdersCancelAll(g_zo, trade);
      return;
     }

   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);
   FiboZone zs[DAY_SLOTS];
   bool     ok[DAY_SLOTS];

   if(EntryMode == HYBRID_ENTRY_CONFIRM)
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
