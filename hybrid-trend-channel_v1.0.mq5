//+------------------------------------------------------------------+
//|                                    hybrid-trend-channel_v1.0.mq5 |
//|  Следование тренду: пробой канала (Дончиан) на H4/D1. Закрытие   |
//|  бара за максимумом/минимумом EntryPeriod баров — вход по рынку; |
//|  стоп — StopAtrMult × ATR; выход — закрытие за противоположной   |
//|  границей канала ExitPeriod (тейка нет, прибыль растёт с         |
//|  трендом). Подключаемые модули (выключены по умолчанию):         |
//|   • режим рынка (Context/MarketRegime): только в тренде или во   |
//|     флэте — против пробоя (стоп по ATR, тейк по RR);             |
//|   • фильтр NFP (Context/NewsTimes): не входить рядом с выходом;  |
//|   • трейлинг (Exits/Trailing).                                   |
//|  Модули: Triggers/ChannelBreakout, Context/MarketRegime,         |
//|  Context/NewsTimes, Core/*, Exits/Trailing.                      |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Trend Channel v1.0 | пробой канала на H4/D1, выход по обратному каналу"

#include <Trade\Trade.mqh>
#include "Include/Core/TradeAdapter.mqh"
#include "Include/Core/BrokerAdapter.mqh"
#include "Include/Core/PositionGuard.mqh"
#include "Include/Core/TradeExecutor.mqh"
#include "Include/Exits/Trailing/SyncTrail.mqh"
#include "Include/Exits/Trailing/BreakevenTrail.mqh"
#include "Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "Include/Core/TesterMetric.mqh"
#include "Include/Triggers/ChannelBreakout.mqh"
#include "Include/Context/MarketRegime.mqh"
#include "Include/Context/NewsTimes.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

enum ENUM_TREND_SIDE
  {
   TREND_SIDE_BOTH  = 0,  // Покупки и продажи
   TREND_SIDE_LONG  = 1,  // Только покупки
   TREND_SIDE_SHORT = 2   // Только продажи
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены. Время — серверное.

input group "── Канал ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_H4;
input int             EntryPeriod      = 20;   // Вход: закрытие за максимумом/минимумом N баров
input int             ExitPeriod       = 10;   // Выход: закрытие за противоположной границей N баров
input ENUM_TREND_SIDE TradeSide        = TREND_SIDE_BOTH;

input group "── Стоп ──"
input int    AtrPeriod   = 20;
input double StopAtrMult = 2.0;    // Стоп = N × ATR от входа
input double MinSLPoints = 1000;   // Мин. стоп: более близкий расширяется до этого значения

input group "── Режим рынка (по умолчанию выключен) ──"
input ENUM_REGIME_MODE RegimeMode      = REGIME_OFF;
input ENUM_TIMEFRAMES  RegimeTimeframe = PERIOD_D1;
input int              RegimePeriod    = 20;    // Баров для коэффициента эффективности
input double           RegimeThreshold = 0.30;  // ER ≥ порога — тренд, ниже — флэт
input double           FadeRiskReward  = 1.5;   // Сделка против пробоя во флэте: тейк = N × стоп

input group "── Фильтр NFP (по умолчанию выключен) ──"
input int    AvoidNfpMinutes = 0;                // Не входить за N минут до и после NFP (0 = выкл.)
input string NfpTimes        = NEWS_NFP_DEFAULT; // Время выходов, сервер: "ГГГГ.ММ.ДД ЧЧ:ММ;…"

input group "── Управление капиталом ──"
input int    MagicNumber      = 71010;
input double RiskPercent      = 1.0;
input double MaxRiskOvershoot = 1.5;
input double MaxSpreadToSL    = 0.10;
input double MaxSlippageToSL  = 0.10;

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext      g_broker;
MarketRegimeConfig g_regime;
datetime           g_nfp[];
datetime           g_lastBar = 0;
int                g_atr     = INVALID_HANDLE;
bool               g_fade    = false;   // открытая сделка — против пробоя (выход по стопу/тейку)
int g_cntSignals = 0, g_cntSide = 0, g_cntRegime = 0, g_cntFade = 0, g_cntNfp = 0, g_cntTrades = 0, g_cntExits = 0;

void Enter(const int dir, const bool fade)
  {
   double atr[];
   if(CopyBuffer(g_atr, 0, 1, 1, atr) < 1 || atr[0] <= 0.0)
      return;
   const double pt    = g_broker.adjustedPoint;
   const double entry = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double dist  = MathMax(StopAtrMult * atr[0], MinSLPoints * pt);
   const double sl    = NormalizeDouble(entry - dir * dist, _Digits);
   const double tp    = fade ? NormalizeDouble(entry + dir * FadeRiskReward * dist, _Digits) : 0.0;
   const double lot   = BrokerCalcLot(g_broker, RiskPercent, dist / pt, LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(lot <= 0.0)
     {
      PrintFormat("⏭ Пропуск: стоп %.2f USD — мин. лот рискует > %.1f%% баланса", dist, RiskPercent * MaxRiskOvershoot);
      return;
     }

   TradeOrderRequest req;
   req.orderType       = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price           = entry;
   req.sl              = sl;
   req.tp              = tp;
   req.lot             = lot;
   req.comment         = fade ? "TCH fade" : "TCH trend";
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;
   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(!res.success)
      return;
   g_fade = fade;
   g_cntTrades++;
   PrintFormat("🚀 %s %s | вход %.3f SL %.3f (%.2f USD, %.1f ATR)%s", fade ? "Против пробоя" : "По пробою",
               dir == 1 ? "BUY" : "SELL", entry, sl, dist, dist / atr[0],
               fade ? StringFormat(" TP %.3f", tp) : " | выход по каналу");
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

   g_atr = iATR(_Symbol, TradingTimeframe, AtrPeriod);
   if(g_atr == INVALID_HANDLE)
     {
      Print("❌ Не удалось создать ATR");
      return INIT_FAILED;
     }
   g_regime.mode      = RegimeMode;
   g_regime.tf        = RegimeTimeframe;
   g_regime.period    = RegimePeriod;
   g_regime.threshold = RegimeThreshold;
   if(AvoidNfpMinutes > 0)
      NewsParseTimes(NfpTimes, g_nfp);

   PrintFormat("✅ Hybrid Trend Channel v1.0 | Magic:%d TF:%s | вход %d, выход %d баров | стоп %.1f×ATR(%d) | режим рынка:%s | NFP ±%d мин",
               MagicNumber, EnumToString(TradingTimeframe), EntryPeriod, ExitPeriod, StopAtrMult, AtrPeriod,
               RegimeMode == REGIME_OFF ? "выкл." : (RegimeMode == REGIME_FILTER ? "только тренд" : "переключатель"),
               AvoidNfpMinutes);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Пробоев: %d | отсеяно стороной: %d, режимом (флэт): %d, NFP: %d | против пробоя: %d | сделок: %d | выходов по каналу: %d",
               g_cntSignals, g_cntSide, g_cntRegime, g_cntNfp, g_cntFade, g_cntTrades, g_cntExits);
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
   if(!BrokerIsTradeSessionOpen())
      return;
   // Новый бар обрабатываем только при открытом рынке (иначе — на первом тике после перерыва).
   const datetime bar = iTime(_Symbol, TradingTimeframe, 0);
   if(bar == g_lastBar)
      return;
   g_lastBar = bar;

   ENUM_POSITION_TYPE type;
   if(PositionGuardHasOpen(MagicNumber, type))
     {
      const int posDir = (type == POSITION_TYPE_BUY) ? 1 : -1;
      if(!g_fade && ChannelExitSignal(TradingTimeframe, ExitPeriod, posDir) &&
         PositionGuardCloseAll(trade, MagicNumber) > 0)
        {
         g_cntExits++;
         PrintFormat("🏁 Выход по каналу %d баров", ExitPeriod);
        }
      return;
     }

   const int sig = ChannelBreakoutSignal(TradingTimeframe, EntryPeriod);
   if(sig == 0)
      return;
   g_cntSignals++;
   const int dir = MarketRegimeApply(g_regime, sig);
   if(dir == 0)
     {
      g_cntRegime++;
      return;
     }
   if((TradeSide == TREND_SIDE_LONG && dir != 1) || (TradeSide == TREND_SIDE_SHORT && dir != -1))
     {
      g_cntSide++;
      return;
     }
   if(AvoidNfpMinutes > 0 && NewsInWindow(g_nfp, TimeCurrent(), AvoidNfpMinutes, AvoidNfpMinutes) > 0)
     {
      g_cntNfp++;
      return;
     }
   const bool fade = (dir != sig);
   if(fade)
      g_cntFade++;
   Enter(dir, fade);
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
