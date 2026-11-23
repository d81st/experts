//+------------------------------------------------------------------+
//|                                                   risk-guard.mq5 |
//|  Компиляционная проверка Include/Core/RiskGuard.mqh.             |
//|  Не торгует. CI (.github/workflows/compile.yml) собирает этот    |
//|  файл вместе с остальными mq5.                                   |
//+------------------------------------------------------------------+
#property strict
#property description "Risk guard compile check | не торгует"

#include "../Include/Core/RiskGuard.mqh"

void OnStart()
  {
   RiskGuardConfigure(1, _Symbol);
   RiskGuardLoad();
   RiskGuardOnTick();
   const int code = RiskGuardBlock(1, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0.0);
   Print(RiskGuardReason(code));
   // RiskGuardResetKill в этом скрипте не вызывается: он снимает kill на счёте.
  }
//+------------------------------------------------------------------+
