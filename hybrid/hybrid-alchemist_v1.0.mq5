//+------------------------------------------------------------------+
//|                                        hybrid-alchemist_v1.0.mq5 |
//|  «Alchemist's Trend»: вход, когда впервые сошлись четыре условия |
//|  — закрытие выше/ниже SMA, HMA растёт/падает, CCI за ±порогом,   |
//|  старший ТФ выше/ниже EMA (Triggers/AlchemistSignal). Вход по    |
//|  рынку на открытии следующего бара. Выходы (переключаемые):      |
//|   • через ExitBars баров (по умолчанию 12 на H1 — как на отсеве); |
//|   • защитный стоп StopAtrMult × ATR (от него считается лот);     |
//|   • по встречному сигналу;                                        |
//|   • трейлинг (выключен).                                          |
//|  Подключаемые фильтры (выключены): режим рынка, новости NFP и    |
//|  CPI/FOMC/ISM, закрытие при проскальзывании.                      |
//|  Отсев: tester/results/screening.md.                              |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid Alchemist v1.0 | MA + HMA + CCI + старший ТФ, выход через N баров"

#include <Trade\Trade.mqh>
#include "../Include/Core/TradeAdapter.mqh"
#include "../Include/Core/BrokerAdapter.mqh"
#include "../Include/Core/PositionGuard.mqh"
#include "../Include/Core/TradeExecutor.mqh"
#include "../Include/Exits/Trailing/SyncTrail.mqh"
#include "../Include/Exits/Trailing/BreakevenTrail.mqh"
#include "../Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "../Include/Core/TesterMetric.mqh"
#include "../Include/Triggers/AlchemistSignal.mqh"
#include "../Include/Context/MarketRegime.mqh"
#include "../Include/Context/NewsTimes.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

enum ENUM_ALCH_SIDE
  {
   ALCH_SIDE_BOTH  = 0,  // Покупки и продажи
   ALCH_SIDE_LONG  = 1,  // Только покупки
   ALCH_SIDE_SHORT = 2   // Только продажи
  };

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены. Время — серверное.

input group "── Сигнал ──"
input ENUM_TIMEFRAMES TradingTimeframe = PERIOD_H1;
input int             MaPeriod         = 200;     // SMA: покупки выше, продажи ниже
input bool            UseHma           = true;    // HMA растёт (покупка) / падает (продажа)
input int             HmaPeriod        = 21;
input bool            UseCci           = true;    // CCI за порогом
input int             CciPeriod        = 20;
input double          CciLevel         = 100;     // Покупка: CCI > +уровня, продажа: CCI < −уровня
input bool            UseHtf           = true;    // Старший ТФ: закрытие выше/ниже EMA
input ENUM_TIMEFRAMES HtfTimeframe     = PERIOD_H4;
input int             HtfEmaPeriod     = 50;
input ENUM_ALCH_SIDE  TradeSide        = ALCH_SIDE_BOTH;

input group "── Выход ──"
input int    ExitBars       = 12;     // Закрыть через N баров рабочего ТФ (0 = выкл.)
input bool   ExitOnOpposite = false;  // Закрыть по встречному сигналу
input int    AtrPeriod      = 14;
input double StopAtrMult    = 3.0;    // Стоп = N × ATR от входа (от него считается лот)
input double MinSLPoints    = 1000;   // Мин. стоп: более близкий расширяется до этого значения
input double RiskReward     = 0;      // Тейк = N × стоп (0 = без тейка)

input group "── Режим рынка (по умолчанию выключен) ──"
input ENUM_REGIME_MODE RegimeMode      = REGIME_OFF;
input ENUM_TIMEFRAMES  RegimeTimeframe = PERIOD_D1;
input int              RegimePeriod    = 20;    // Баров для коэффициента эффективности
input double           RegimeThreshold = 0.30;  // ER ≥ порога — тренд, ниже — флэт

input group "── Фильтр новостей (по умолчанию выключен) ──"
input int    AvoidNewsMinutes = 0;      // Не входить за N минут до и после выбранных новостей (0 = выкл.)
input bool   NewsNFP          = true;   // NFP, 8:30 по Нью-Йорку
input bool   NewsCPI          = true;   // CPI, 8:30 по Нью-Йорку
input bool   NewsFOMC         = true;   // Решение FOMC, 14:00 по Нью-Йорку
input bool   NewsISM          = true;   // ISM Manufacturing PMI, 10:00 по Нью-Йорку
input string NewsExtraTimes   = "";     // Свои даты: "ГГГГ.ММ.ДД ЧЧ:ММ;…"

input group "── Управление капиталом ──"
input int    MagicNumber      = 71012;
input double RiskPercent      = 1.0;
input double MaxRiskOvershoot = 1.5;
input double MaxSpreadToSL    = 0.10;
input double MaxSlippageToSL  = 0.10;
input bool   CloseOnSlippage  = false; // Вход по рынку исполнился хуже допуска — сразу закрыть

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext      g_broker;
AlchemistConfig    g_cfg;
AlchemistState     g_sig;
MarketRegimeConfig g_regime;
datetime           g_news[];
datetime           g_lastBar = 0;
bool               g_pending = false;   // новый бар есть, но рынок был закрыт — обработать при открытии
int                g_pendSig = 0;
int                g_atr     = INVALID_HANDLE;
int g_cntSignals = 0, g_cntBusy = 0, g_cntSide = 0, g_cntRegime = 0, g_cntNews = 0, g_cntTrades = 0;
int g_cntExitBars = 0, g_cntExitOpp = 0;

void Enter(const int dir)
  {
   double atr[];
   if(CopyBuffer(g_atr, 0, 1, 1, atr) < 1 || atr[0] <= 0.0)
      return;
   const double pt    = g_broker.adjustedPoint;
   const double entry = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double dist  = MathMax(StopAtrMult * atr[0], MinSLPoints * pt);
   const double sl    = NormalizeDouble(entry - dir * dist, _Digits);
   const double tp    = (RiskReward > 0.0) ? NormalizeDouble(entry + dir * RiskReward * dist, _Digits) : 0.0;
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
   req.comment         = "HAL";
   req.maxSpreadToSL   = MaxSpreadToSL;
   req.maxSlippageToSL = MaxSlippageToSL;
   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(!res.success)
      return;
   g_cntTrades++;
   PrintFormat("🚀 %s | вход %.3f SL %.3f (%.2f USD, %.1f ATR)%s", dir == 1 ? "BUY" : "SELL",
               entry, sl, dist, dist / atr[0], tp > 0.0 ? StringFormat(" TP %.3f", tp) : "");
  }

// Выход через ExitBars баров: бар входа и следующие ExitBars−1 баров закрыты.
bool ExitByBars()
  {
   if(ExitBars <= 0)
      return false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      const int age = iBarShift(_Symbol, TradingTimeframe, opened, false);
      if(age >= ExitBars && trade.PositionClose(t))
        {
         g_cntExitBars++;
         PrintFormat("⏱ Выход через %d бар(ов): #%I64u", ExitBars, t);
         return true;
        }
     }
   return false;
  }

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

   g_cfg.tf           = TradingTimeframe;
   g_cfg.maPeriod     = MaPeriod;
   g_cfg.useHma       = UseHma;
   g_cfg.hmaPeriod    = HmaPeriod;
   g_cfg.useCci       = UseCci;
   g_cfg.cciPeriod    = CciPeriod;
   g_cfg.cciLevel     = CciLevel;
   g_cfg.useHtf       = UseHtf;
   g_cfg.htf          = HtfTimeframe;
   g_cfg.htfEmaPeriod = HtfEmaPeriod;
   if(!AlchemistInit(g_sig, g_cfg))
     {
      Print("❌ Не удалось создать индикаторы сигнала");
      return INIT_FAILED;
     }
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
   if(AvoidNewsMinutes > 0)
      NewsBuildList(NewsNFP, NewsCPI, NewsFOMC, NewsISM, NewsExtraTimes, g_news);

   PrintFormat("✅ Hybrid Alchemist v1.0 | Magic:%d TF:%s | SMA%d%s%s%s | выход %d бар%s | стоп %.1f×ATR(%d) | новости ±%d мин",
               MagicNumber, EnumToString(TradingTimeframe), MaPeriod,
               UseHma ? StringFormat(" + HMA%d", HmaPeriod) : "",
               UseCci ? StringFormat(" + CCI%d ±%.0f", CciPeriod, CciLevel) : "",
               UseHtf ? StringFormat(" + %s EMA%d", EnumToString(HtfTimeframe), HtfEmaPeriod) : "",
               ExitBars, ExitOnOpposite ? " / встречный сигнал" : "", StopAtrMult, AtrPeriod, AvoidNewsMinutes);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Сигналов: %d | при открытой сделке: %d | отсеяно стороной: %d, режимом: %d, новостями: %d | "
               "сделок: %d | выходов через N баров: %d, по встречному сигналу: %d",
               g_cntSignals, g_cntBusy, g_cntSide, g_cntRegime, g_cntNews, g_cntTrades, g_cntExitBars, g_cntExitOpp);
   AlchemistRelease(g_sig);
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
   // Сигнал считаем на каждом новом баре, даже если торговля закрыта (котировки золота идут
   // до ~22:00, а торговая сессия закрывается около 21:00): вход — на первом тике после открытия.
   const datetime bar = iTime(_Symbol, TradingTimeframe, 0);
   if(bar != g_lastBar)
     {
      g_lastBar = bar;
      const int fresh = AlchemistSignal(g_sig, g_cfg);
      // необработанный сигнал (пришёл, пока рынок был закрыт) не затираем пустым
      if(fresh != 0 || !g_pending)
         g_pendSig = fresh;
      g_pending = true;
     }
   if(!g_pending || !BrokerIsTradeSessionOpen())
      return;
   g_pending = false;

   ExitByBars();
   const int sig = g_pendSig;

   ENUM_POSITION_TYPE type;
   if(PositionGuardHasOpen(MagicNumber, type))
     {
      const int posDir = (type == POSITION_TYPE_BUY) ? 1 : -1;
      if(sig != 0)
         g_cntSignals++;
      if(ExitOnOpposite && sig == -posDir && PositionGuardCloseAll(trade, MagicNumber) > 0)
        {
         g_cntExitOpp++;
         Print("🏁 Выход по встречному сигналу");
        }
      else
        {
         if(sig != 0)
            g_cntBusy++;
         return;
        }
     }
   else if(sig != 0)
      g_cntSignals++;
   if(sig == 0)
      return;

   const int dir = MarketRegimeApply(g_regime, sig);
   if(dir != sig)   // в режиме «переключатель» сигнал против тренда здесь не торгуем
     {
      g_cntRegime++;
      return;
     }
   if((TradeSide == ALCH_SIDE_LONG && dir != 1) || (TradeSide == ALCH_SIDE_SHORT && dir != -1))
     {
      g_cntSide++;
      return;
     }
   if(AvoidNewsMinutes > 0 && NewsInWindow(g_news, TimeCurrent(), AvoidNewsMinutes, AvoidNewsMinutes) > 0)
     {
      g_cntNews++;
      return;
     }
   Enter(dir);
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
