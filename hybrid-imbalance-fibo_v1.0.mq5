//+------------------------------------------------------------------+
//|                                   hybrid-imbalance-fibo_v1.0.mq5 |
//|  Имбаланс-свеча + фибо. После закрытия длинной свечи с гэпом     |
//|  (FVG) от неё натягивается фибо: 0 — начало свечи, 1 — конец.    |
//|  Лимитки со следующей свечи:                                     |
//|   • откат 0.5–0.382 внутри свечи — по направлению свечи, тейк —  |
//|     конец свечи (линия 1);                                       |
//|   • 1.212–1.272 и 1.618–1.762 за концом свечи — на разворот,     |
//|     тейк — линия 1; по выбору — те же зоны за началом свечи.     |
//|  Стоп — за дальним краем зоны + отступ, не меньше минимума.      |
//|  Новая имбаланс-свеча заменяет старые уровни и лимитки.          |
//|  Модули: Levels/ImbalanceCandle, Triggers/ZoneOrders.            |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Imbalance Fibo v1.0 | фибо-зоны от имбаланс-свечи, лимитки"

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
#include "Include/Levels/ImbalanceCandle.mqh"
#include "Include/Triggers/ZoneOrders.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

#define IMB_SLOTS 5   // 0 откат; 1, 2 — за концом свечи; 3, 4 — за началом

enum ENUM_IMB_EXT_SIDE
  {
   IMB_EXT_END   = 0,  // За концом свечи (над вершиной покупной)
   IMB_EXT_START = 1,  // За началом свечи (под минимумом покупной)
   IMB_EXT_BOTH  = 2   // С обеих сторон
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены.

input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_M15;  // Таймфрейм свечи и зон

input group "── Имбаланс-свеча ──"
input int    ImbAtrPeriod    = 10;    // ATR свечей до имбаланса
input double ImbMinRangeATR  = 1.0;   // Длина свечи (тень к тени) ≥ N × ATR
input double ImbMinBodyRatio = 0.6;   // Тело ≥ доли свечи
input double ImbMinGapATR    = 0.2;   // Гэп (закрытие − экстремум предыдущей) ≥ N × ATR
input int    ZoneLifeBars    = 0;     // Уровни живут N свечей (0 = до следующей имбаланс-свечи)

input group "── Зоны (уровни фибо: 0 — начало свечи, 1 — конец) ──"
input bool              UseZoneRetrace = true;
input double            RetraceNear    = 0.5;     // Лимитка
input double            RetraceFar     = 0.382;   // За ним стоп
input bool              UseZoneExt1    = true;
input double            Ext1Near       = 1.212;
input double            Ext1Far        = 1.272;
input bool              UseZoneExt2    = true;
input double            Ext2Near       = 1.618;
input double            Ext2Far        = 1.762;
input ENUM_IMB_EXT_SIDE ExtSide        = IMB_EXT_END;

input group "── Стоп / тейк ──"
input double SLBufferPoints = 300;    // Стоп за дальним краем зоны + отступ (спред и запас)
input double MinSLPoints    = 1500;   // Мин. стоп: более близкий расширяется до этого значения
// Тейк: откат и зоны за концом свечи — конец свечи (линия 1); за началом — начало (линия 0).

input group "── Управление капиталом ──"
input int    MagicNumber      = 71009;
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
int              g_atr     = INVALID_HANDLE;
ImbalanceConfig  g_imb_cfg;
ZoneOrders       g_zo;
ZoneOrdersConfig g_zo_cfg;

bool     g_active = false;   // есть уровни текущей свечи
int      g_dir    = 0;
double   g_hi     = 0.0;
double   g_lo     = 0.0;
int      g_id     = 0;       // номер свечи (в комментарии ордера)
int      g_age    = 0;       // свечей после имбаланса
int      g_cntCandles = 0, g_cntExpired = 0;

string SlotName(const int i)
  {
   switch(i)
     {
      case 0:  return StringFormat("откат %.3f–%.3f", RetraceNear, RetraceFar);
      case 1:  return StringFormat("за концом %.3f–%.3f", Ext1Near, Ext1Far);
      case 2:  return StringFormat("за концом %.3f–%.3f", Ext2Near, Ext2Far);
      case 3:  return StringFormat("за началом %.3f–%.3f", Ext1Near, Ext1Far);
      default: return StringFormat("за началом %.3f–%.3f", Ext2Near, Ext2Far);
     }
  }

void BuildZones(FiboZone &zs[], bool &ok[])
  {
   const bool useEnd   = (ExtSide != IMB_EXT_START);
   const bool useStart = (ExtSide != IMB_EXT_END);
   ImbalanceRetraceZone(g_hi, g_lo, g_dir, RetraceNear, RetraceFar, zs[0]);
   ImbalanceExtZone(g_hi, g_lo, g_dir, true,  Ext1Near, Ext1Far, zs[1]);
   ImbalanceExtZone(g_hi, g_lo, g_dir, true,  Ext2Near, Ext2Far, zs[2]);
   ImbalanceExtZone(g_hi, g_lo, g_dir, false, Ext1Near, Ext1Far, zs[3]);
   ImbalanceExtZone(g_hi, g_lo, g_dir, false, Ext2Near, Ext2Far, zs[4]);
   ok[0] = UseZoneRetrace;
   ok[1] = UseZoneExt1 && useEnd;
   ok[2] = UseZoneExt2 && useEnd;
   ok[3] = UseZoneExt1 && useStart;
   ok[4] = UseZoneExt2 && useStart;
   for(int i = 0; i < IMB_SLOTS; i++)
      zs[i].name = SlotName(i);
  }

// На новом баре: закрытая свеча 1 — имбаланс? Тогда новые уровни вместо старых.
void OnNewBar()
  {
   if(g_active && ZoneLifeBars > 0 && ++g_age > ZoneLifeBars)
     {
      ZoneOrdersReset(g_zo, trade);
      g_active = false;
      g_cntExpired++;
     }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   double atr[];
   if(CopyRates(_Symbol, TradingTimeframe, 1, 2, r) < 2 || CopyBuffer(g_atr, 0, 2, 1, atr) < 1)
      return;
   int dir = 0;
   if(!ImbalanceDetect(r[1], r[0], atr[0], g_imb_cfg, dir))
      return;

   ZoneOrdersReset(g_zo, trade);
   g_active = true;
   g_dir    = dir;
   g_hi     = r[0].high;
   g_lo     = r[0].low;
   g_age    = 0;
   g_id++;
   g_cntCandles++;
   PrintFormat("🕯 Имбаланс-свеча #%d %s %s: H=%.3f L=%.3f (%.2f USD, ATR %.2f)", g_id,
               dir == 1 ? "BUY" : "SELL", TimeToString(r[0].time), g_hi, g_lo, g_hi - g_lo, atr[0]);
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

   g_atr = iATR(_Symbol, TradingTimeframe, ImbAtrPeriod);
   if(g_atr == INVALID_HANDLE)
     {
      Print("❌ Не удалось создать ATR");
      return INIT_FAILED;
     }
   g_imb_cfg.minRangeAtr  = ImbMinRangeATR;
   g_imb_cfg.minBodyRatio = ImbMinBodyRatio;
   g_imb_cfg.minGapAtr    = ImbMinGapATR;
   SessionsSetup();

   g_zo_cfg.magic            = MagicNumber;
   g_zo_cfg.tf               = TradingTimeframe;
   g_zo_cfg.riskPercent      = RiskPercent;
   g_zo_cfg.maxRiskOvershoot = MaxRiskOvershoot;
   g_zo_cfg.maxSpreadToSL    = MaxSpreadToSL;
   g_zo_cfg.maxSlippageToSL  = MaxSlippageToSL;
   g_zo_cfg.slBufferPoints   = SLBufferPoints;
   g_zo_cfg.minSLPoints      = MinSLPoints;
   g_zo_cfg.commentPrefix    = "HIF";
   ZoneOrdersInit(g_zo, IMB_SLOTS);

   PrintFormat("✅ Hybrid Imbalance Fibo v1.0 | Magic:%d TF:%s | свеча ≥ %.1f×ATR(%d), тело ≥ %.0f%%, гэп ≥ %.2f×ATR | мин. стоп %.2f USD",
               MagicNumber, EnumToString(TradingTimeframe), ImbMinRangeATR, ImbAtrPeriod,
               ImbMinBodyRatio * 100.0, ImbMinGapATR, MinSLPoints / 1000.0);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Имбаланс-свечей: %d | уровни истекли без новой свечи: %d", g_cntCandles, g_cntExpired);
   for(int i = 0; i < IMB_SLOTS; i++)
      ZoneOrdersPrintSlot(g_zo, i, SlotName(i));
   ZoneOrdersPrintTotals(g_zo);
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
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

   const datetime bar = iTime(_Symbol, TradingTimeframe, 0);
   if(bar != g_lastBar)
     {
      g_lastBar = bar;
      OnNewBar();
     }

   const ENUM_SESSION_STATE session = SessionsOnTick();
   // Рынок закрыт по расписанию (ежедневный перерыв): ни выставить, ни снять ордер нельзя.
   if(!BrokerIsTradeSessionOpen())
      return;
   if(session == SESSION_JUST_EXITED && CloseOnSessionExit)
      PositionGuardCloseAll(trade, MagicNumber);
   ZoneOrdersCloseExtra(g_zo, trade, MagicNumber);
   ZoneOrdersSweepOrphans(g_zo, trade, MagicNumber);
   if(!g_active || session != SESSION_TRADING || SessionsIsBoundary())
     {
      ZoneOrdersCancelAll(g_zo, trade);   // вне торговли лимитки не держим
      return;
     }

   // Бот держит одну сделку: пока она открыта, лимитки сняты.
   ENUM_POSITION_TYPE type;
   if(PositionGuardHasOpen(MagicNumber, type))
     {
      ZoneOrdersCancelAll(g_zo, trade);
      return;
     }
   FiboZone zs[IMB_SLOTS];
   bool     ok[IMB_SLOTS];
   BuildZones(zs, ok);
   ZoneOrdersManageLimits(g_zo, trade, g_broker, g_zo_cfg, zs, ok, g_id);
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
