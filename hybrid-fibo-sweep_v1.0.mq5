//+------------------------------------------------------------------+
//|                                       hybrid-fibo-sweep_v1.0.mq5 |
//|  Гибрид №3: снятие ликвидности за фибо-зоной. Зоны 1.212–1.272 и |
//|  1.618–1.762 за диапазоном волны ATR-зигзага (как в Fibo Zones). |
//|  Свеча прокалывает зону насквозь (за дальний край) и закрывается |
//|  обратно — вход по рынку на разворот на следующем баре. Стоп за  |
//|  экстремумом прокола, тейк — пробитая граница диапазона (линия   |
//|  0/1) или RR.                                                    |
//|  Модули: Levels/FiboWave, Triggers/ZoneOrders.                   |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Fibo Sweep v1.0 | снятие ликвидности за фибо-зоной 1.212 / 1.618 и возврат"

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

enum ENUM_SWEEP_RETURN
  {
   SWEEP_RETURN_FAR  = 0,  // Закрытие обратно за дальний край зоны (1.272 / 1.762)
   SWEEP_RETURN_NEAR = 1   // Закрытие обратно за ближний край зоны (1.212 / 1.618)
  };

enum ENUM_SWEEP_TP
  {
   SWEEP_TP_LINE = 0,  // Пробитая граница диапазона (линия 0/1)
   SWEEP_TP_RR   = 1   // RR от стопа
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены.

input group "── Волна (ATR-зигзаг) ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M15;  // Таймфрейм волны, зон и свечи снятия
input int    ZigZagAtrPeriod  = 14;
input double ZigZagAtrMult    = 3.0;   // Точка разворота подтверждается отходом цены на N × ATR
input int    ZigZagWarmupBars = 500;
input double MinRangePoints   = 0;     // Мин. размер волны, пункты (0 = без ограничения)

input group "── Зоны (доли волны) ──"
input bool   UseZoneExt1 = true;
input double Ext1Near    = 1.212;
input double Ext1Far     = 1.272;
input bool   UseZoneExt2 = true;
input double Ext2Near    = 1.618;
input double Ext2Far     = 1.762;

input group "── Снятие ──"
input double            SweepMinPoints = 0;                 // Прокол за дальний край зоны не меньше, пункты
input ENUM_SWEEP_RETURN SweepReturn    = SWEEP_RETURN_FAR;  // Куда должна закрыться свеча

input group "── Стоп / тейк ──"
input double        SLBufferPoints = 300;            // Стоп за экстремумом прокола + отступ
input double        MinSLPoints    = 1000;           // Мин. стоп: более близкий расширяется до этого значения
input ENUM_SWEEP_TP TakeProfitMode = SWEEP_TP_LINE;
input double        RiskReward     = 2.0;            // Для режима RR

input group "── Управление капиталом ──"
input int    MagicNumber      = 71008;
input double RiskPercent      = 3.0;
input double MaxRiskOvershoot = 1.5;
input double MaxSpreadToSL    = 0.25;
input double MaxSlippageToSL  = 0.10;

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

// Сессии: торгует круглосуточно, на выходе из сессии позиции не закрывает.
#define SESSION_DEFAULT_SELECTED      false
#define SESSION_DEFAULT_LONDON        false
#define SESSION_DEFAULT_CLOSE_ON_EXIT false
#include "Include/Context/SessionInputs.mqh"

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext    g_broker;
datetime         g_lastBar = 0;
FiboWave         g_fw;
FiboWaveConfig   g_fw_cfg;
ZoneOrders       g_zo;
ZoneOrdersConfig g_zo_cfg;
int              g_cntSweeps[FIBO_WAVE_SLOTS];

//+------------------------------------------------------------------+
//| Снятие на закрытом баре 1 по зонам диапазона, известного до него.|
//| Продажа (зона сверху): максимум бара выше дальнего края зоны,    |
//| закрытие — ниже дальнего (или ближнего) края. Покупка — зеркально.|
//+------------------------------------------------------------------+
void CheckSweeps(const bool canEnter)
  {
   FiboZone zs[FIBO_WAVE_SLOTS];
   bool     ok[FIBO_WAVE_SLOTS];
   FiboWaveBuildAll(g_fw, g_fw_cfg, zs, ok);

   const double pt = g_broker.adjustedPoint;
   const double h1 = iHigh(_Symbol, TradingTimeframe, 1);
   const double l1 = iLow(_Symbol, TradingTimeframe, 1);
   const double c1 = iClose(_Symbol, TradingTimeframe, 1);

   for(int i = 0; i < FIBO_WAVE_SLOTS; i++)
     {
      if(!ok[i] || g_zo.used[i])
         continue;
      FiboZone z = zs[i];
      const double back  = (SweepReturn == SWEEP_RETURN_FAR) ? z.farP : z.nearP;
      const bool   swept = (z.dir == -1)
                           ? (h1 > z.farP + SweepMinPoints * pt && c1 < back)
                           : (l1 < z.farP - SweepMinPoints * pt && c1 > back);
      if(!swept)
         continue;
      g_cntSweeps[i]++;
      if(!canEnter)
         continue;   // сделка уже открыта

      const double ext = (z.dir == -1) ? h1 : l1;
      if(TakeProfitMode == SWEEP_TP_RR)
        {
         const double entry = (z.dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         bool widened;
         const double sl = ZoneOrdersSL(g_zo_cfg, g_broker, z, entry, ext, widened);
         z.tp = entry + z.dir * RiskReward * MathAbs(entry - sl);
        }
      ZoneOrdersEnterMarket(g_zo, trade, g_broker, g_zo_cfg, i, z, ext, g_fw.id, "снятию за зоной");
      return;      // одна сделка на бар
     }
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

   g_fw_cfg.tf             = TradingTimeframe;
   g_fw_cfg.atrPeriod      = ZigZagAtrPeriod;
   g_fw_cfg.atrMult        = ZigZagAtrMult;
   g_fw_cfg.warmupBars     = ZigZagWarmupBars;
   g_fw_cfg.minRange       = MinRangePoints * g_broker.adjustedPoint;
   g_fw_cfg.useRetrace     = false;
   g_fw_cfg.useRetraceLive = false;
   g_fw_cfg.useExt1        = UseZoneExt1;
   g_fw_cfg.useExt2        = UseZoneExt2;
   g_fw_cfg.useExt3        = false;
   g_fw_cfg.retraceNear    = 0.382;     g_fw_cfg.retraceFar = 0.5;
   g_fw_cfg.ext1Near       = Ext1Near;  g_fw_cfg.ext1Far    = Ext1Far;
   g_fw_cfg.ext2Near       = Ext2Near;  g_fw_cfg.ext2Far    = Ext2Far;
   g_fw_cfg.ext3Near       = 2.212;     g_fw_cfg.ext3Far    = 2.272;
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
   g_zo_cfg.commentPrefix    = "HFS";
   ZoneOrdersInit(g_zo, FIBO_WAVE_SLOTS);
   ArrayInitialize(g_cntSweeps, 0);

   PrintFormat("✅ Hybrid Fibo Sweep v1.0 | Magic:%d TF:%s | зигзаг %.1f×ATR(%d) | возврат за %s край | тейк %s",
               MagicNumber, EnumToString(TradingTimeframe), ZigZagAtrMult, ZigZagAtrPeriod,
               SweepReturn == SWEEP_RETURN_FAR ? "дальний" : "ближний",
               TakeProfitMode == SWEEP_TP_LINE ? "граница диапазона" : StringFormat("RR %.1f", RiskReward));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Диапазонов: %d", g_fw.cntRanges);
   for(int i = 0; i < FIBO_WAVE_SLOTS; i++)
     {
      double nearR, farR;
      if(!FiboWaveSlotLevels(g_fw_cfg, i, nearR, farR))
         continue;
      const string name = StringFormat("%s %.3f–%.3f", FiboWaveSlotName(i), nearR, farR);
      PrintFormat("📊 Зона %s: снятий %d", name, g_cntSweeps[i]);
      ZoneOrdersPrintSlot(g_zo, i, name);
     }
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
   TrailingManage(g_trade_adapter, g_broker, MagicNumber, g_trail_cfg);

   const datetime bar    = iTime(_Symbol, TradingTimeframe, 0);
   const bool     newBar = (bar != g_lastBar);
   const ENUM_SESSION_STATE session = SessionsOnTick();
   if(newBar)
     {
      g_lastBar = bar;
      // Снятие проверяем по зонам, построенным до бара 1, затем добавляем бар 1 в зигзаг.
      ENUM_POSITION_TYPE type;
      if(g_fw.ready && BrokerIsTradeSessionOpen() && session == SESSION_TRADING && !SessionsIsBoundary())
         CheckSweeps(!PositionGuardHasOpen(MagicNumber, type));
      const int ev = FiboWaveOnNewBar(g_fw, g_fw_cfg);
      if((ev & FIBO_WAVE_RANGE_CHANGED) != 0)
         ZoneOrdersReset(g_zo, trade);
     }

   if(!BrokerIsTradeSessionOpen())
      return;
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
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
