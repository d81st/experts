//+------------------------------------------------------------------+
//|                                                  AccountRisk.mqh |
//|                                                                  |
//|  Общий риск счёта: сколько % баланса потеряется, если сработают  |
//|  стопы всех открытых позиций — всех ботов и символов, включая    |
//|  ручные сделки. Перед входом бот проверяет: открытый риск +      |
//|  риск новой сделки ≤ лимита. Лимитки бот проверяет при           |
//|  постановке и на каждом баре (AccountRiskAllows), а не после     |
//|  исполнения: между проверками другой бот может войти, так что    |
//|  лимит соблюдается с точностью до одного бара.                   |
//|  Позиция без стопа — риск неизвестен: считаем её как noSlPercent |
//|  (по умолчанию 100 % — блокирует новые входы, пока стопа нет).   |
//+------------------------------------------------------------------+
#ifndef ACCOUNTRISK_MQH
#define ACCOUNTRISK_MQH

// Убыток (в валюте счёта, ≥ 0), если позиция/ордер закроется по стопу.
double AccountRiskMoney(const string sym, const bool buy, const double volume, const double open, const double sl)
  {
   double pr = 0.0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, volume, open, sl, pr))
      return 0.0;
   return MathMax(0.0, -pr);
  }

// Открытый риск счёта, % баланса.
double AccountRiskOpenPercent(const double noSlPercent = 100.0)
  {
   const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0)
      return 0.0;
   double money = 0.0, pct = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      const double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
        {
         pct += noSlPercent;
         continue;
        }
      money += AccountRiskMoney(PositionGetString(POSITION_SYMBOL),
                                PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY,
                                PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN), sl);
     }
   return pct + money / bal * 100.0;
  }

// Можно ли добавить сделку с риском newMoney при лимите maxPercent (0 — без лимита).
bool AccountRiskAllows(const double newMoney, const double maxPercent, double &openPct, double &newPct)
  {
   openPct = 0.0; newPct = 0.0;
   if(maxPercent <= 0.0)
      return true;
   const double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   openPct = AccountRiskOpenPercent();
   newPct  = bal > 0.0 ? newMoney / bal * 100.0 : 0.0;
   return openPct + newPct <= maxPercent + 1e-9;
  }

#endif // ACCOUNTRISK_MQH
//+------------------------------------------------------------------+
