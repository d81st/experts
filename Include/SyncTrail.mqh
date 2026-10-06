//+------------------------------------------------------------------+
//|                                                   SyncTrail.mqh  |
//|                                                                  |
//|  Synchronized SL/TP Trailing — common types and pure helpers     |
//|                                                                  |
//|  Feature: synchronized-sl-tp-trailing                            |
//|  Spec:    .kiro/specs/synchronized-sl-tp-trailing/design.md      |
//|                                                                  |
//|  This header declares:                                           |
//|   - ENUM_TRAILING_MODE  — режим трейлинга (Req 1.1, 1.5)         |
//|   - SyncTrailState      — per-ticket состояние (Req 2.5, 3.1)    |
//|   - прототипы pure-хелперов трейлинга                            |
//|                                                                  |
//|  Тела pure-хелперов реализуются в task 1.2 в этом же файле.      |
//|  Хелперы НЕ обращаются ни к терминалу, ни к trade.*  — все       |
//|  входы и выходы передаются параметрами (см. design.md,           |
//|  "Pure-хелперы для SyncTrailing").                               |
//+------------------------------------------------------------------+
#ifndef SYNCTRAIL_MQH
#define SYNCTRAIL_MQH

//+------------------------------------------------------------------+
//| Режим трейлинга (входной параметр TrailingMode).                 |
//|                                                                  |
//|   TRAILING_OFF       — без трейлинга (Req 1.2)                   |
//|   TRAILING_BREAKEVEN — однократный перевод в безубыток           |
//|                        (текущая логика ManageStopLoss, Req 1.3)  |
//|   TRAILING_SYNC      — синхронный трейлинг блока SL/TP (Req 1.4) |
//+------------------------------------------------------------------+
enum ENUM_TRAILING_MODE
  {
   TRAILING_OFF       = 0,   // Без трейлинга
   TRAILING_BREAKEVEN = 1,   // Перевод SL в безубыток (legacy)
   TRAILING_SYNC      = 2    // Синхронный трейлинг SL и TP
  };

//+------------------------------------------------------------------+
//| Per-ticket состояние SyncTrailing.                               |
//|                                                                  |
//| Поля заполняются в FindOrCreateState / ManageSyncTrailing        |
//| (см. design.md, "Components and Interfaces" и "Data Models").    |
//|                                                                  |
//|   ticket              — тикет позиции (Req 9.2)                  |
//|   dir                 — +1 для BUY, -1 для SELL                  |
//|   openPrice           — POSITION_PRICE_OPEN на момент первого    |
//|                         наблюдения                               |
//|   initialSL           — POSITION_SL на момент первого            |
//|                         наблюдения (Req 9.3)                     |
//|   activated           — флаг «трейлинг активирован» (Req 2.2)    |
//|   blockSize           — |TP - SL| на момент активации,           |
//|                         фиксируется один раз (Req 3.1, 3.2)     |
//|   lastSL              — последний успешно применённый SL         |
//|                         (для дельты в логах)                     |
//|   modificationSkipped — анти-спам логирования при нарушении      |
//|                         MinBrokerDistance (Req 7.2, 7.4)        |
//|   warnedNoStops       — анти-спам предупреждения «нет SL/TP»     |
//|                         (Req 3.4)                                |
//+------------------------------------------------------------------+
struct SyncTrailState
  {
   ulong             ticket;
   int               dir;
   double            openPrice;
   double            initialSL;
   bool              activated;
   double            blockSize;
   double            lastSL;
   bool              modificationSkipped;
   bool              warnedNoStops;
  };

//+------------------------------------------------------------------+
//| Pure-хелперы (прототипы).                                        |
//|                                                                  |
//| Тела добавляются в task 1.2. Все функции — детерминированные,    |
//| без побочных эффектов; не читают глобальное состояние и не       |
//| обращаются к терминалу.                                          |
//+------------------------------------------------------------------+

//--- Вычисляет кандидата SL без учёта брокерских и шаговых проверок.
//    BUY  (dir=+1): candidateSL = currentBid - (openPrice - initialSL)
//    SELL (dir=-1): candidateSL = currentAsk + (initialSL - openPrice)
//    Req 4.1, 4.2.
double ComputeCandidateSL(const int    dir,
                          const double currentBid,
                          const double currentAsk,
                          const double openPrice,
                          const double initialSL);

//--- Поднимает (BUY) / опускает (SELL) candidateSL до openPrice, если
//    он нарушает условие монотонности относительно цены открытия.
//    Req 5.5.
double ClampToBreakeven(const int    dir,
                        const double candidateSL,
                        const double openPrice);

//--- Проверяет шаговый порог. При stepPoints == 0 — всегда true
//    (любое улучшение допустимо). Req 6.2, 6.3, 6.4.
bool   ImprovementMeetsStep(const int    dir,
                            const double candidateSL,
                            const double currentSL,
                            const double point,
                            const double stepPoints);

//--- Возвращает true, если candidateSL строго «лучше» currentSL:
//    BUY  → candidateSL > currentSL
//    SELL → candidateSL < currentSL
//    Req 5.1, 5.2, 5.6.
bool   IsStrictImprovement(const int    dir,
                           const double candidateSL,
                           const double currentSL);

//--- Вычисляет newTP от newSL и зафиксированного blockSize.
//    BUY  → newSL + blockSize
//    SELL → newSL - blockSize
//    Req 3.3.
double ComputeNewTP(const int    dir,
                    const double newSL,
                    const double blockSize);

//--- Возвращает true, если minBrokerDistance соблюдена для пары
//    (newSL, newTP) относительно текущих цен.
//    BUY  → currentBid - newSL >= minBrokerDistance И
//           newTP - currentBid >= minBrokerDistance
//    SELL → newSL - currentAsk >= minBrokerDistance И
//           currentAsk - newTP >= minBrokerDistance
//    Req 7.1, 7.2, 7.3.
bool   BrokerDistanceOk(const int    dir,
                        const double currentBid,
                        const double currentAsk,
                        const double newSL,
                        const double newTP,
                        const double minBrokerDistance);

//+------------------------------------------------------------------+
//| Pure-хелперы — реализация.                                       |
//|                                                                  |
//| Каждая функция — детерминированная и без побочных эффектов:      |
//| ни Print, ни SymbolInfo*, ни PositionGet*, ни trade.*.           |
//|                                                                  |
//| Порядок арифметических выражений сохранён побитово с             |
//| Python-эталоном tests/python/sync_trail_ref.py, чтобы golden-    |
//| vectors из task 11.1 совпадали с MQL5-реализацией для одних и    |
//| тех же входов (IEEE-754, одинаковая алгебра).                    |
//+------------------------------------------------------------------+

//--- Кандидат SL без брокерских / шаговых проверок. Req 4.1, 4.2.
double ComputeCandidateSL(const int    dir,
                          const double currentBid,
                          const double currentAsk,
                          const double openPrice,
                          const double initialSL)
  {
   if(dir == 1)
      return currentBid - (openPrice - initialSL);
   return currentAsk + (initialSL - openPrice);
  }

//--- Клампинг кандидата к openPrice (нельзя «ниже безубытка»). Req 5.5.
double ClampToBreakeven(const int    dir,
                        const double candidateSL,
                        const double openPrice)
  {
   if(dir == 1)
      return MathMax(candidateSL, openPrice);
   return MathMin(candidateSL, openPrice);
  }

//--- Строгое улучшение SL (без epsilon). Req 5.1, 5.2, 5.6.
bool IsStrictImprovement(const int    dir,
                         const double candidateSL,
                         const double currentSL)
  {
   if(dir == 1)
      return candidateSL > currentSL;
   return candidateSL < currentSL;
  }

//--- Шаговый порог. stepPoints == 0 ⇒ всегда true. Req 6.2, 6.3, 6.4.
bool ImprovementMeetsStep(const int    dir,
                          const double candidateSL,
                          const double currentSL,
                          const double point,
                          const double stepPoints)
  {
   if(stepPoints == 0.0)
      return true;
   double improvement;
   if(dir == 1)
      improvement = (candidateSL - currentSL) / point;
   else
      improvement = (currentSL - candidateSL) / point;
   return improvement >= stepPoints;
  }

//--- newTP от newSL и зафиксированного blockSize. Req 3.3, 4.3, 4.4.
double ComputeNewTP(const int    dir,
                    const double newSL,
                    const double blockSize)
  {
   if(dir == 1)
      return newSL + blockSize;
   return newSL - blockSize;
  }

//--- Проверка обеих брокерских дистанций. Req 7.1, 7.2, 7.3.
bool BrokerDistanceOk(const int    dir,
                      const double currentBid,
                      const double currentAsk,
                      const double newSL,
                      const double newTP,
                      const double minBrokerDistance)
  {
   if(dir == 1)
      return (currentBid - newSL) >= minBrokerDistance
          && (newTP - currentBid) >= minBrokerDistance;
   return (newSL - currentAsk) >= minBrokerDistance
       && (currentAsk - newTP) >= minBrokerDistance;
  }

#endif // SYNCTRAIL_MQH
//+------------------------------------------------------------------+
