//+------------------------------------------------------------------+
//|                                     hybrid-nfp-straddle_v1.0.mq5 |
//|  Торговля на выходе NFP: за MinutesBefore минут до выхода —      |
//|  buy stop выше цены и sell stop ниже на DistancePoints. Сработал |
//|  один — второй снимается. Стоп — SLPoints от входа, тейк — RR.   |
//|  Неисполненные ордера снимаются через ExpireMinutes после выхода,|
//|  позиция закрывается через HoldMinutes.                          |
//|  Время выходов — Context/NewsTimes (встроенный список + свои даты).|
//|  Модули: Context/NewsTimes, Core/*, Exits/Trailing.              |
//+------------------------------------------------------------------+
#property strict
#property description "Hybrid NFP Straddle v1.0 | отложки по обе стороны цены на выходе NFP"

#include <Trade\Trade.mqh>
#include "../Include/Core/TradeAdapter.mqh"
#include "../Include/Core/BrokerAdapter.mqh"
#include "../Include/Core/PositionGuard.mqh"
#include "../Include/Core/TradeExecutor.mqh"
#include "../Include/Exits/Trailing/SyncTrail.mqh"
#include "../Include/Exits/Trailing/BreakevenTrail.mqh"
#include "../Include/Exits/Trailing/TrailingDispatcher.mqh"
#include "../Include/Core/TesterMetric.mqh"
#include "../Include/Context/NewsTimes.mqh"
CTrade trade;
ITradeAdapter *g_trade_adapter = NULL;
TrailingConfig g_trail_cfg;

//── Входные параметры ─────────────────────────────────────────────────
// Все расстояния — в пунктах: на золоте 1000 пт = 1.00 USD цены. Время — серверное.

input group "── Новости ──"
input bool   UseNfpDefault = true;  // Встроенные даты NFP 2025–2026
input string NfpExtraTimes = "";    // Добавить даты: "ГГГГ.ММ.ДД ЧЧ:ММ;…" (время сервера)
input int    MinutesBefore = 2;     // Выставить ордера за N минут до выхода
input int    ExpireMinutes = 5;     // Снять неисполненные через N минут после выхода
input int    HoldMinutes   = 60;    // Закрыть позицию через N минут после выхода (0 = не закрывать)

input group "── Ордера ──"
input double DistancePoints = 1500;  // Стоп-ордера на таком расстоянии от цены
input double SLPoints       = 3000;  // Стоп от входа
input double RiskReward     = 2.0;   // Тейк = N × стоп (0 = без тейка)

input group "── Управление капиталом ──"
input int    MagicNumber      = 71011;
input double RiskPercent      = 1.0;
input double MaxRiskOvershoot = 1.5;

input group "── Трейлинг (по умолчанию выключен) ──"
input ENUM_TRAILING_MODE_EX TrailingMode          = TRAILING_OFF_EX;
input double                TrailingStartFactor   = 0.5;
input double                BreakevenOffsetPoints = 175;
input double                SyncTrailStepPoints   = 0.0;

//── Состояние ─────────────────────────────────────────────────────────

BrokerContext g_broker;
datetime      g_nfp[];
datetime      g_doneFor = 0;   // выход, для которого ордера уже выставлялись
datetime      g_evt     = 0;   // текущий выход (пока активны ордера/позиция)
ulong         g_buyTicket = 0, g_sellTicket = 0;
bool          g_filled  = false; // по текущему выходу открылась позиция
int g_cntEvents = 0, g_cntFilled = 0, g_cntExpired = 0, g_cntTimeClose = 0, g_cntBoth = 0;

ulong PlaceStop(const int dir, const double price)
  {
   const double pt  = g_broker.adjustedPoint;
   const double sl  = price - dir * SLPoints * pt;
   const double tp  = (RiskReward > 0.0) ? price + dir * RiskReward * SLPoints * pt : 0.0;
   const double lot = BrokerCalcLot(g_broker, RiskPercent, SLPoints, LOT_BY_TICK_VALUE, MaxRiskOvershoot);
   if(lot <= 0.0)
      return 0;
   TradeOrderRequest req;
   req.orderType       = (dir == 1) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   req.price           = price;
   req.sl              = sl;
   req.tp              = tp;
   req.lot             = lot;
   req.comment         = StringFormat("NFP %s %s", dir == 1 ? "up" : "down", TimeToString(g_evt, TIME_DATE));
   req.maxSpreadToSL   = 0.0;   // на новостях спред широкий — для отложек не фильтруем
   req.maxSlippageToSL = 0.0;
   const TradeResult res = TradeExecutorSend(trade, g_broker, req);
   if(!res.success)
      return 0;
   // Цена уже за уровнем — ордер стал рыночным, тикета отложки нет.
   return (req.orderType == ORDER_TYPE_BUY_STOP || req.orderType == ORDER_TYPE_SELL_STOP) ? res.ticket : 0;
  }

void DeletePending()
  {
   if(g_buyTicket != 0 && PositionGuardPendingExists(g_buyTicket) && trade.OrderDelete(g_buyTicket))
      g_buyTicket = 0;
   if(g_sellTicket != 0 && PositionGuardPendingExists(g_sellTicket) && trade.OrderDelete(g_sellTicket))
      g_sellTicket = 0;
   if(g_buyTicket != 0 && !PositionGuardPendingExists(g_buyTicket))
      g_buyTicket = 0;
   if(g_sellTicket != 0 && !PositionGuardPendingExists(g_sellTicket))
      g_sellTicket = 0;
  }

// Ближайший будущий выход, для которого пора выставлять ордера.
datetime DueEvent(const datetime now)
  {
   for(int i = 0; i < ArraySize(g_nfp); i++)
      if(g_nfp[i] > now && g_nfp[i] - now <= MinutesBefore * 60)
         return g_nfp[i];
   return 0;
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

   const int n = NewsParseTimes((UseNfpDefault ? NEWS_NFP_DEFAULT + ";" : "") + NfpExtraTimes, g_nfp);
   PrintFormat("✅ Hybrid NFP Straddle v1.0 | Magic:%d | выходов в списке: %d | за %d мин, ±%.2f USD, стоп %.2f USD, RR %.1f, держать %d мин",
               MagicNumber, n, MinutesBefore, DistancePoints / 1000.0, SLPoints / 1000.0, RiskReward, HoldMinutes);
   return (n > 0) ? INIT_SUCCEEDED : INIT_PARAMETERS_INCORRECT;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("📊 Выходов NFP: %d | сработал ордер: %d (оба сразу: %d) | ордера сняты без исполнения: %d | закрыто по времени: %d",
               g_cntEvents, g_cntFilled, g_cntBoth, g_cntExpired, g_cntTimeClose);
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
   const datetime now = TimeCurrent();
   ENUM_POSITION_TYPE type;
   const bool hasPos = PositionGuardHasOpen(MagicNumber, type);

   // Выставить ордера перед выходом.
   const datetime due = DueEvent(now);
   if(due != 0 && due != g_doneFor && !hasPos)
     {
      g_doneFor = due;
      g_evt     = due;
      g_cntEvents++;
      g_filled = false;
      const double pt = g_broker.adjustedPoint;
      g_buyTicket  = PlaceStop(1,  SymbolInfoDouble(_Symbol, SYMBOL_ASK) + DistancePoints * pt);
      g_sellTicket = PlaceStop(-1, SymbolInfoDouble(_Symbol, SYMBOL_BID) - DistancePoints * pt);
      PrintFormat("📰 NFP %s: выставлены стоп-ордера ±%.2f USD", TimeToString(due), DistancePoints / 1000.0);
      return;
     }
   if(g_evt == 0)
      return;

   // Сработал один — второй снимаем (если сработали оба — лишнюю позицию закрываем).
   if(hasPos && !g_filled)
     {
      g_filled = true;
      g_cntFilled++;
     }
   if(hasPos && (g_buyTicket != 0 || g_sellTicket != 0))
      DeletePending();
   if(PositionsTotal() > 1)
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         const ulong t = PositionGetTicket(i);
         if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;
         if(++n > 1 && trade.PositionClose(t))
            g_cntBoth++;
        }
     }

   // Срок ордеров и удержания позиции.
   if(now > g_evt + ExpireMinutes * 60 && (g_buyTicket != 0 || g_sellTicket != 0))
     {
      DeletePending();
      if(!g_filled)
         g_cntExpired++;
     }
   if(hasPos && HoldMinutes > 0 && now >= g_evt + HoldMinutes * 60)
     {
      if(PositionGuardCloseAll(trade, MagicNumber) > 0)
         g_cntTimeClose++;
     }
   if(!hasPos && g_buyTicket == 0 && g_sellTicket == 0 && now > g_evt + ExpireMinutes * 60)
      g_evt = 0;
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
