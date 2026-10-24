//+------------------------------------------------------------------+
//|                                                    RiskGuard.mqh |
//|  Страж счёта. Пока советник не вызвал RiskGuardConfigure,        |
//|  ничего не делает. Пороги фиксированы, их не подбирают:          |
//|    риск сделки 0.5% баланса, лот ниже минимального — отказ,      |
//|    не подъём до минимума;                                        |
//|    сутки сервера: средства на 2% ниже начала суток — не закрывать|
//|    открытое и не открывать новое до следующих суток;             |
//|    средства на 15% ниже пика — больше не открывать, пока человек |
//|    не вызовет RiskGuardResetKill; пик при сбросе не двигается;   |
//|    лонг запрещён, пока закрытие D1 ниже SMA200 закрытий D1;      |
//|    битый символ, tick value, стоп, спред > 3 медиан или котировка|
//|    старше 60 секунд — отказ.                                      |
//|  Медиана — 128 предыдущих положительных спредов. Пока их меньше, |
//|  входа нет. Первая котировка без предшественника — устаревшая.   |
//|  Состояние пика, kill и начала суток лежит в глобальных          |
//|  переменных терминала. Не записалось — входа нет.                 |
//|  Функции не вызывают PositionClose.                               |
//+------------------------------------------------------------------+
#ifndef RISKGUARD_MQH
#define RISKGUARD_MQH

#define RG_RISK_PERCENT        0.5
#define RG_DAILY_LOSS_PERCENT  2.0
#define RG_MAX_DD_PERCENT      15.0
#define RG_BEAR_PERIOD         200
#define RG_SPREAD_MULT         3.0
#define RG_SPREAD_SAMPLES      128
#define RG_STALE_SECONDS       60

#define RG_OK           0
#define RG_SYMBOL       1
#define RG_TICK_VALUE   2
#define RG_STOPS        3
#define RG_SPREAD       4
#define RG_STALE        5
#define RG_KILL         6
#define RG_DAILY        7
#define RG_BEAR         8

int      g_rgMagic = 0;
string   g_rgSymbol;
bool     g_rgOn = false;
bool     g_rgKilled = false;
double   g_rgPeak = 0.0;
int      g_rgDayKey = 0;
double   g_rgDayEq = 0.0;
bool     g_rgDayBlocked = false;
bool     g_rgDayKnown = false;
datetime g_rgPrevTick = 0;
bool     g_rgStale = true;
double   g_rgSpreadBuf[RG_SPREAD_SAMPLES];
int      g_rgSpreadCount = 0;
int      g_rgSpreadPos = 0;
double   g_rgMedian = 0.0;
bool     g_rgMedianReady = false;
bool     g_rgStoreOk = true;

string RiskGuardName(const string suffix)
  {
   string sym = g_rgSymbol;
   StringReplace(sym, ".", "_");
   StringReplace(sym, " ", "_");
   return StringFormat("RG.%d.%s.%s", g_rgMagic, sym, suffix);
  }

bool RiskGuardStore(const string suffix, const double value)
  {
   const string name = RiskGuardName(suffix);
   if(GlobalVariableSet(name, value) == 0)
     {
      g_rgStoreOk = false;
      return false;
     }
   return true;
  }

void RiskGuardConfigure(const int magic, const string symbol)
  {
   g_rgMagic = magic;
   g_rgSymbol = symbol;
   g_rgOn = true;
   g_rgStoreOk = true;
  }

void RiskGuardResetKill(void)
  {
   if(!g_rgOn)
      return;
   g_rgKilled = false;
   GlobalVariableDel(RiskGuardName("kill"));
   RiskGuardStore("kill", 0.0);
  }

void RiskGuardLoad(void)
  {
   if(!g_rgOn)
      return;
   const string kill = RiskGuardName("kill");
   const string peak = RiskGuardName("peak");
   const string day = RiskGuardName("day");
   const string dayEq = RiskGuardName("dayeq");
   if(GlobalVariableCheck(kill))
      g_rgKilled = GlobalVariableGet(kill) > 0.5;
   if(GlobalVariableCheck(peak))
      g_rgPeak = GlobalVariableGet(peak);
   if(GlobalVariableCheck(day) && GlobalVariableCheck(dayEq))
     {
      g_rgDayKey = (int)MathRound(GlobalVariableGet(day));
      g_rgDayEq = GlobalVariableGet(dayEq);
      g_rgDayKnown = g_rgDayEq > 0.0;
     }
  }

int RiskGuardDayKey(const datetime when)
  {
   MqlDateTime dt;
   TimeToStruct(when, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

double RiskGuardMedian(void)
  {
   if(g_rgSpreadCount < RG_SPREAD_SAMPLES)
      return 0.0;
   double copy[];
   ArrayResize(copy, RG_SPREAD_SAMPLES);
   for(int i = 0; i < RG_SPREAD_SAMPLES; i++)
      copy[i] = g_rgSpreadBuf[i];
   ArraySort(copy);
   return 0.5 * (copy[RG_SPREAD_SAMPLES / 2 - 1] + copy[RG_SPREAD_SAMPLES / 2]);
  }

void RiskGuardPushSpread(const double spread)
  {
   if(!(spread > 0.0))
      return;
   if(g_rgSpreadCount < RG_SPREAD_SAMPLES)
     {
      g_rgSpreadBuf[g_rgSpreadCount] = spread;
      g_rgSpreadCount++;
      return;
     }
   g_rgSpreadBuf[g_rgSpreadPos] = spread;
   g_rgSpreadPos = (g_rgSpreadPos + 1) % RG_SPREAD_SAMPLES;
  }

// Обновить сутки, пик, kill и буфер спреда. Позиции не закрывает.
void RiskGuardOnTick(void)
  {
   if(!g_rgOn)
      return;
   const datetime now = TimeCurrent();
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const int key = RiskGuardDayKey(now);
   const double dayFloor = 1.0 - RG_DAILY_LOSS_PERCENT / 100.0;
   if(g_rgDayKey == 0 || key != g_rgDayKey)
     {
      g_rgDayKey = key;
      g_rgDayEq = equity;
      g_rgDayKnown = equity > 0.0;
      g_rgDayBlocked = false;
      if(!RiskGuardStore("day", key) || !RiskGuardStore("dayeq", equity))
         g_rgDayBlocked = true;
     }
   else if(g_rgDayKnown && g_rgDayEq > 0.0 && equity <= g_rgDayEq * dayFloor + 1e-6)
      g_rgDayBlocked = true;

   if(equity > g_rgPeak)
     {
      g_rgPeak = equity;
      RiskGuardStore("peak", g_rgPeak);
     }
   if(g_rgPeak > 0.0 && equity <= g_rgPeak * (1.0 - RG_MAX_DD_PERCENT / 100.0) + 1e-6)
     {
      if(!g_rgKilled)
        {
         g_rgKilled = true;
         RiskGuardStore("kill", 1.0);
         RiskGuardStore("peak", g_rgPeak);
        }
     }

   g_rgStale = (g_rgPrevTick <= 0 || (now - g_rgPrevTick) > RG_STALE_SECONDS);
   g_rgPrevTick = now;

   const double bid = SymbolInfoDouble(g_rgSymbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_rgSymbol, SYMBOL_ASK);
   g_rgMedianReady = g_rgSpreadCount >= RG_SPREAD_SAMPLES;
   g_rgMedian = g_rgMedianReady ? RiskGuardMedian() : 0.0;
   RiskGuardPushSpread(ask - bid);
  }

bool RiskGuardBear(void)
  {
   double closes[];
   ArraySetAsSeries(closes, true);
   const int got = CopyClose(g_rgSymbol, PERIOD_D1, 1, RG_BEAR_PERIOD, closes);
   if(got < RG_BEAR_PERIOD)
      return true;
   double sum = 0.0;
   for(int i = 0; i < RG_BEAR_PERIOD; i++)
     {
      if(!(closes[i] > 0.0))
         return true;
      sum += closes[i];
     }
   const double sma = sum / RG_BEAR_PERIOD;
   return closes[0] < sma;
  }

int RiskGuardBlock(const int direction, const double entry, const double sl)
  {
   if(!g_rgOn)
      return RG_OK;
   if(!g_rgStoreOk)
      return RG_SYMBOL;
   const double point = SymbolInfoDouble(g_rgSymbol, SYMBOL_POINT);
   const double contract = SymbolInfoDouble(g_rgSymbol, SYMBOL_TRADE_CONTRACT_SIZE);
   const double tickSize = SymbolInfoDouble(g_rgSymbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(g_rgSymbol, SYMBOL_TRADE_TICK_VALUE);
   const double volMin = SymbolInfoDouble(g_rgSymbol, SYMBOL_VOLUME_MIN);
   const double volMax = SymbolInfoDouble(g_rgSymbol, SYMBOL_VOLUME_MAX);
   const double volStep = SymbolInfoDouble(g_rgSymbol, SYMBOL_VOLUME_STEP);
   const long stopsLevel = SymbolInfoInteger(g_rgSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freezeLevel = SymbolInfoInteger(g_rgSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(!(point > 0.0) || !(contract > 0.0) || !(volMin > 0.0) || !(volStep > 0.0) || !(volMax >= volMin) || stopsLevel < 0 || freezeLevel < 0)
      return RG_SYMBOL;
   if(!(tickSize > 0.0) || !(tickValue > 0.0))
      return RG_TICK_VALUE;
   const double bid = SymbolInfoDouble(g_rgSymbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_rgSymbol, SYMBOL_ASK);
   const double spread = ask - bid;
   if(!(bid > 0.0) || !(ask >= bid) || !(spread > 0.0))
      return RG_SYMBOL;
   if(g_rgStale)
      return RG_STALE;
   if(!g_rgMedianReady || !(g_rgMedian > 0.0) || spread > RG_SPREAD_MULT * g_rgMedian)
      return RG_SPREAD;
   if(g_rgKilled)
      return RG_KILL;
   if(!g_rgDayKnown || g_rgDayBlocked)
      return RG_DAILY;
   if(direction > 0 && RiskGuardBear())
      return RG_BEAR;
   if(!(sl > 0.0) || !(entry > 0.0))
      return RG_STOPS;
   const double dist = direction > 0 ? entry - sl : sl - entry;
   const double minDist = MathMax(stopsLevel, freezeLevel) * point;
   if(!(dist > 0.0) || (minDist > 0.0 && dist + 1e-9 < minDist))
      return RG_STOPS;
   return RG_OK;
  }

string RiskGuardReason(const int code)
  {
   if(code == RG_SYMBOL) return "symbol";
   if(code == RG_TICK_VALUE) return "tick_value";
   if(code == RG_STOPS) return "stops";
   if(code == RG_SPREAD) return "spread";
   if(code == RG_STALE) return "stale";
   if(code == RG_KILL) return "kill";
   if(code == RG_DAILY) return "daily";
   if(code == RG_BEAR) return "bear";
   return "ok";
  }

#endif // RISKGUARD_MQH
//+------------------------------------------------------------------+
