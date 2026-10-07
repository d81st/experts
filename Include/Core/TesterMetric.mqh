//+------------------------------------------------------------------+
//|                                                  TesterMetric.mqh |
//|                                                                  |
//|  Критерий для оптимизатора MT5 («Custom max»): PF × √сделок.      |
//|  Ценит и прибыльность, и объём статистики; ноль при малой         |
//|  выборке или большой просадке — такие наборы не выбираются.       |
//+------------------------------------------------------------------+
#ifndef TESTERMETRIC_MQH
#define TESTERMETRIC_MQH

#define TESTER_METRIC_MIN_TRADES 30     // меньше — статистика ненадёжна
#define TESTER_METRIC_MAX_DD_PCT 30.0   // относительная просадка по балансу, %

double TesterMetric()
  {
   const double trades = TesterStatistics(STAT_TRADES);
   const double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   const double ddPct  = TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   if(trades < TESTER_METRIC_MIN_TRADES || ddPct > TESTER_METRIC_MAX_DD_PCT)
      return 0.0;
   return pf * MathSqrt(trades);
  }

#endif // TESTERMETRIC_MQH
//+------------------------------------------------------------------+
