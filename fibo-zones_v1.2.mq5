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
#include "Include/Levels/FiboWave.mqh"
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

#define FIBO_SLOTS FIBO_WAVE_SLOTS   // 0 — откат подтверждённой волны; 1/2 — Ext1 сверху/снизу;
                                    // 3/4 — Ext2; 5/6 — Ext3; 7 — откат текущей волны

BrokerContext g_broker;
datetime      g_lastBar = 0;

// Волны и зоны (Include/Levels/FiboWave.mqh).
FiboWave       g_fw;
FiboWaveConfig g_fw_cfg;

// Ордера по зонам (Include/Triggers/ZoneOrders.mqh): учёт слотов, лимитки, подтверждение.
ZoneOrders       g_zo;
ZoneOrdersConfig g_zo_cfg;

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

   g_fw_cfg.tf             = TradingTimeframe;
   g_fw_cfg.atrPeriod      = ZigZagAtrPeriod;
   g_fw_cfg.atrMult        = ZigZagAtrMult;
   g_fw_cfg.warmupBars     = ZigZagWarmupBars;
   g_fw_cfg.minRange       = MinRangePoints * g_broker.adjustedPoint;
   g_fw_cfg.useRetrace     = UseZoneRetrace;
   g_fw_cfg.useRetraceLive = UseZoneRetraceLive;
   g_fw_cfg.useExt1        = UseZoneExt1;
   g_fw_cfg.useExt2        = UseZoneExt2;
   g_fw_cfg.useExt3        = UseZoneExt3;
   g_fw_cfg.retraceNear    = RetraceNear;  g_fw_cfg.retraceFar = RetraceFar;
   g_fw_cfg.ext1Near       = Ext1Near;     g_fw_cfg.ext1Far    = Ext1Far;
   g_fw_cfg.ext2Near       = Ext2Near;     g_fw_cfg.ext2Far    = Ext2Far;
   g_fw_cfg.ext3Near       = Ext3Near;     g_fw_cfg.ext3Far    = Ext3Far;
   if(!FiboWaveInit(g_fw, g_fw_cfg))
     {
      Print("❌ Не удалось создать ATR");
      return INIT_FAILED;
     }
   SessionsSetup();

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

   PrintFormat("✅ Fibo Zones v1.2 | Magic:%d TF:%s | зигзаг %.1f×ATR(%d) | вход:%s | отступ %.0f пт | мин. стоп %.0f пт",
               MagicNumber, EnumToString(TradingTimeframe), ZigZagAtrMult, ZigZagAtrPeriod,
               EntryMode == FIBO_ENTRY_LIMIT ? "LIMIT" : "CONFIRM", SLBufferPoints, MinSLPoints);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Диапазонов: %d", g_fw.cntRanges);
   for(int i = 0; i < FIBO_SLOTS; i++)
     {
      double nearR, farR;
      if(!FiboWaveSlotLevels(g_fw_cfg, i, nearR, farR))
         continue;
      ZoneOrdersPrintSlot(g_zo, i, StringFormat("%s %.3f–%.3f", FiboWaveSlotName(i), nearR, farR));
     }
   ZoneOrdersPrintTotals(g_zo);
   FiboWaveDeinit(g_fw);
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
      const int ev = FiboWaveOnNewBar(g_fw, g_fw_cfg);
      if((ev & FIBO_WAVE_RANGE_CHANGED) != 0)
         ZoneOrdersReset(g_zo, trade);
      if((ev & FIBO_WAVE_LIVE_CHANGED) != 0)
         ZoneOrdersRelease(g_zo, 7);
     }

   const ENUM_SESSION_STATE session = SessionsOnTick();
   // Рынок закрыт по расписанию (ежедневный перерыв): ни выставить, ни снять ордер нельзя.
   if(!BrokerIsTradeSessionOpen())
      return;
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   ZoneOrdersCloseExtra(g_zo, trade, MagicNumber);
   ZoneOrdersSweepOrphans(g_zo, trade, MagicNumber);
   if(session != SESSION_TRADING || SessionsIsBoundary() || !g_fw.ready)
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
         FiboWaveBuildAll(g_fw, g_fw_cfg, zs, ok);
         ZoneOrdersConfirm(g_zo, trade, g_broker, g_zo_cfg, zs, ok, !hasPos, g_fw.id);
        }
      return;
     }

   if(hasPos)
     {
      ZoneOrdersCancelAll(g_zo, trade);
      return;
     }
   FiboWaveBuildAll(g_fw, g_fw_cfg, zs, ok);
   ZoneOrdersManageLimits(g_zo, trade, g_broker, g_zo_cfg, zs, ok, g_fw.id);
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
