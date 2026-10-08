//+------------------------------------------------------------------+
//|                                     hybrid-fibo-pattern_v1.0.mq5 |
//|  Гибрид №2: зоны Фибоначчи от волн ATR-зигзага (Fibo Zones) +    |
//|  подтверждение свечным паттерном в зоне: поглощение (engulfing)  |
//|  или CRT (crt-bot). Вход по рынку на открытии бара после         |
//|  паттерна, если паттерн коснулся зоны и смотрит в сторону сделки |
//|  зоны; стоп — за дальним краем зоны или экстремумом паттерна.    |
//|  Модули: Levels/FiboWave, Triggers/EngulfingPattern,             |
//|  Levels/CrtDetector, Triggers/ZoneOrders.                        |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Fibo Pattern v1.0 | фибо-зоны волны + подтверждение поглощением или CRT"

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
#include "../Include/Levels/FiboWave.mqh"
#include "../Include/Levels/CrtDetector.mqh"
#include "../Include/Triggers/EngulfingPattern.mqh"
#include "../Include/Triggers/ZoneOrders.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

enum ENUM_ZONE_PATTERN
  {
   ZONE_PATTERN_ENGULFING = 0,  // Поглощение
   ZONE_PATTERN_CRT       = 1,  // CRT (TrueRB, InsideWick, bare imbalance, ghost)
   ZONE_PATTERN_ANY       = 2   // Любой из двух
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены.

input group "── Волна (ATR-зигзаг) ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M15;  // Таймфрейм волны, зон и паттерна
input int    ZigZagAtrPeriod  = 14;
input double ZigZagAtrMult    = 3.0;   // Точка разворота подтверждается отходом цены на N × ATR
input int    ZigZagWarmupBars = 500;
input double MinRangePoints   = 0;     // Мин. размер волны, пункты (0 = без ограничения)

input group "── Зоны (доли волны) ──"
input bool   UseZoneRetrace     = true;   // Откат подтверждённой волны
input bool   UseZoneRetraceLive = true;   // Откат текущей волны
input double RetraceNear        = 0.382;
input double RetraceFar         = 0.5;
input bool   UseZoneExt1        = true;
input double Ext1Near           = 1.212;
input double Ext1Far            = 1.272;
input bool   UseZoneExt2        = true;
input double Ext2Near           = 1.618;
input double Ext2Far            = 1.762;
input bool   UseZoneExt3        = false;
input double Ext3Near           = 2.212;
input double Ext3Far            = 2.272;

input group "── Подтверждение паттерном ──"
input ENUM_ZONE_PATTERN Pattern = ZONE_PATTERN_ENGULFING;
// Поглощение (значения по умолчанию — как в engulfing-bot)
input bool   RequireOppositeCandle      = true;
input bool   RequireFullBodyEngulf      = true;
input double RBOpenCloseTolerancePoints = 100;
input double MinBodyPoints              = 0;
input double R1BodyRatio                = 0.4;
input double R2BodyRatio                = 0.2;
input double R2ToR1SizeRatio            = 0.3;
// CRT (значения по умолчанию — как в crt-bot)
input double ImbBodyRatio         = 0.40;
input double DojiThreshold        = 0.35;
input double DojiToImbSizeRatio   = 0.40;
input double DojiToImbRangeRatio  = 1.00;
input double OpenTolerance        = 0.01;
input double BareImbWickTolerance = 0.05;

input group "── Стоп / тейк ──"
input double SLBufferPoints = 300;    // Стоп за дальним краем зоны (или экстремумом паттерна) + отступ
input double MinSLPoints    = 1000;   // Мин. стоп: более близкий расширяется до этого значения
// Тейк: откат — конец волны (линия 0); зоны за диапазоном — пробитая граница.

input group "── Управление капиталом ──"
input int    MagicNumber      = 71006;
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
#include "../Include/Context/SessionInputs.mqh"

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext     g_broker;
datetime          g_lastBar = 0;
FiboWave          g_fw;
FiboWaveConfig    g_fw_cfg;
ZoneOrders        g_zo;
ZoneOrdersConfig  g_zo_cfg;
EngulfingConfig   g_eng_cfg;
CrtDetectorConfig g_crt_cfg;
CrtPatternFlags   g_crt_flags;
int               g_cntSignals = 0, g_cntInZone = 0;

//+------------------------------------------------------------------+
//| Паттерн на последних закрытых свечах: направление сделки (+1/-1) |
//| и экстремумы свечей паттерна (для касания зоны и стопа).         |
//+------------------------------------------------------------------+
int DetectPattern(double &patHi, double &patLo, string &name)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, TradingTimeframe, 0, 4, r) < 4)
      return 0;

   if(Pattern == ZONE_PATTERN_ENGULFING || Pattern == ZONE_PATTERN_ANY)
     {
      int dir = 0;
      if(EngulfingDetect(r[2], r[1], g_eng_cfg, g_broker.adjustedPoint, dir))
        {
         patHi = MathMax(r[1].high, r[2].high);
         patLo = MathMin(r[1].low, r[2].low);
         name  = "свече поглощения";
         return dir;
        }
     }
   if(Pattern == ZONE_PATTERN_CRT || Pattern == ZONE_PATTERN_ANY)
     {
      CrtSignal sig;
      CrtDetectorDetect(r[3], r[2], r[1], g_crt_cfg, g_crt_flags, sig);
      if(sig.detected)
        {
         patHi = MathMax(r[1].high, r[2].high);
         patLo = MathMin(r[1].low, r[2].low);
         name  = "CRT " + sig.patternName;
         return -sig.imbDir;   // бычий импульс → SELL, медвежий → BUY
        }
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| На новом баре: паттерн, коснувшийся зоны своей стороны, → вход.  |
//| Покупка: свечи паттерна дошли до ближнего края зоны снизу (low ≤ |
//| near); продажа — зеркально. Стоп — за дальним краем зоны или     |
//| экстремумом паттерна, что дальше.                                |
//+------------------------------------------------------------------+
void CheckPatternEntries(const bool canEnter)
  {
   double patHi = 0.0, patLo = 0.0;
   string name  = "";
   const int dir = DetectPattern(patHi, patLo, name);
   if(dir == 0)
      return;
   g_cntSignals++;

   FiboZone zs[FIBO_WAVE_SLOTS];
   bool     ok[FIBO_WAVE_SLOTS];
   FiboWaveBuildAll(g_fw, g_fw_cfg, zs, ok);
   for(int i = 0; i < FIBO_WAVE_SLOTS; i++)
     {
      if(!ok[i] || g_zo.used[i] || zs[i].dir != dir)
         continue;
      const bool touched = (dir == 1) ? (patLo <= zs[i].nearP) : (patHi >= zs[i].nearP);
      if(!touched)
         continue;
      g_cntInZone++;
      if(!canEnter)
         return;   // сделка уже открыта
      const double farP = (dir == 1) ? MathMin(zs[i].farP, patLo) : MathMax(zs[i].farP, patHi);
      ZoneOrdersEnterMarket(g_zo, trade, g_broker, g_zo_cfg, i, zs[i], farP, g_fw.id, name);
      return;      // одна сделка на сигнал
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

   g_eng_cfg.requireOpposite = RequireOppositeCandle;
   g_eng_cfg.requireFullBody = RequireFullBodyEngulf;
   g_eng_cfg.openCloseTolPts = RBOpenCloseTolerancePoints;
   g_eng_cfg.minBodyPts      = MinBodyPoints;
   g_eng_cfg.r1BodyRatio     = R1BodyRatio;
   g_eng_cfg.r2BodyRatio     = R2BodyRatio;
   g_eng_cfg.r2ToR1SizeRatio = R2ToR1SizeRatio;

   g_crt_cfg.ImbBodyRatio         = ImbBodyRatio;
   g_crt_cfg.DojiThreshold        = DojiThreshold;
   g_crt_cfg.DojiToImbSizeRatio   = DojiToImbSizeRatio;
   g_crt_cfg.DojiToImbRangeRatio  = DojiToImbRangeRatio;
   g_crt_cfg.OpenTolerance        = OpenTolerance;
   g_crt_cfg.BareImbWickTolerance = BareImbWickTolerance;
   g_crt_flags.AlertTrueRB          = true;
   g_crt_flags.AlertInsideWick      = true;
   g_crt_flags.AlertGhostTrueRB     = true;
   g_crt_flags.AlertGhostInsideWick = true;
   g_crt_flags.AlertBareImbalance   = true;
   SessionsSetup();

   g_zo_cfg.magic            = MagicNumber;
   g_zo_cfg.tf               = TradingTimeframe;
   g_zo_cfg.riskPercent      = RiskPercent;
   g_zo_cfg.maxRiskOvershoot = MaxRiskOvershoot;
   g_zo_cfg.maxSpreadToSL    = MaxSpreadToSL;
   g_zo_cfg.maxSlippageToSL  = MaxSlippageToSL;
   g_zo_cfg.slBufferPoints   = SLBufferPoints;
   g_zo_cfg.minSLPoints      = MinSLPoints;
   g_zo_cfg.commentPrefix    = "HFP";
   ZoneOrdersInit(g_zo, FIBO_WAVE_SLOTS);

   PrintFormat("✅ Hybrid Fibo Pattern v1.0 | Magic:%d TF:%s | зигзаг %.1f×ATR(%d) | паттерн:%s",
               MagicNumber, EnumToString(TradingTimeframe), ZigZagAtrMult, ZigZagAtrPeriod,
               Pattern == ZONE_PATTERN_ENGULFING ? "поглощение" : (Pattern == ZONE_PATTERN_CRT ? "CRT" : "любой"));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Диапазонов: %d | паттернов: %d | из них у зоны своей стороны: %d",
               g_fw.cntRanges, g_cntSignals, g_cntInZone);
   for(int i = 0; i < FIBO_WAVE_SLOTS; i++)
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
   if(!BrokerIsTradeSessionOpen())
      return;
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   ZoneOrdersCloseExtra(g_zo, trade, MagicNumber);
   if(!newBar || session != SESSION_TRADING || SessionsIsBoundary() || !g_fw.ready)
      return;

   ENUM_POSITION_TYPE type;
   CheckPatternEntries(!PositionGuardHasOpen(MagicNumber, type));
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
