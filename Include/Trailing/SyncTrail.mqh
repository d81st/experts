//+------------------------------------------------------------------+
//|                                                   SyncTrail.mqh  |
//|                                                                  |
//|  Synchronized SL/TP Trailing — common types and pure helpers     |
//|                                                                  |
//|  This header declares:                                           |
//|   - ENUM_TRAILING_MODE  — режим трейлинга                        |
//|   - SyncTrailState      — per-ticket состояние                   |
//|   - прототипы pure-хелперов трейлинга                            |
//|                                                                  |
//|  Тела pure-хелперов реализованы ниже в этом же файле.            |
//|  Хелперы НЕ обращаются ни к терминалу, ни к trade.*  — все       |
//|  входы и выходы передаются параметрами.                          |
//+------------------------------------------------------------------+
#ifndef SYNCTRAIL_MQH
#define SYNCTRAIL_MQH

//+------------------------------------------------------------------+
//| Режим трейлинга (входной параметр TrailingMode).                 |
//|                                                                  |
//|   TRAILING_OFF       — без трейлинга                             |
//|   TRAILING_BREAKEVEN — однократный перевод в безубыток           |
//|                        (текущая логика ManageStopLoss)           |
//|   TRAILING_SYNC      — синхронный трейлинг блока SL/TP           |
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
//|                                                                  |
//|   ticket              — тикет позиции                            |
//|   dir                 — +1 для BUY, -1 для SELL                  |
//|   openPrice           — POSITION_PRICE_OPEN на момент первого    |
//|                         наблюдения                               |
//|   initialSL           — POSITION_SL на момент первого            |
//|                         наблюдения                               |
//|   activated           — флаг «трейлинг активирован»              |
//|   blockSize           — |TP - SL| на момент активации,           |
//|                         фиксируется один раз                    |
//|   lastSL              — последний успешно применённый SL         |
//|                         (для дельты в логах)                     |
//|   modificationSkipped — анти-спам логирования при нарушении      |
//|                         MinBrokerDistance                       |
//|   warnedNoStops       — анти-спам предупреждения «нет SL/TP»     |
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
//| Все функции — детерминированные,                                 |
//| без побочных эффектов; не читают глобальное состояние и не       |
//| обращаются к терминалу.                                          |
//+------------------------------------------------------------------+

//--- Вычисляет кандидата SL без учёта брокерских и шаговых проверок.
//    BUY  (dir=+1): candidateSL = currentBid - (openPrice - initialSL)
//    SELL (dir=-1): candidateSL = currentAsk + (initialSL - openPrice)
double ComputeCandidateSL(const int    dir,
                          const double currentBid,
                          const double currentAsk,
                          const double openPrice,
                          const double initialSL);

//--- Поднимает (BUY) / опускает (SELL) candidateSL до openPrice, если
//    он нарушает условие монотонности относительно цены открытия.
double ClampToBreakeven(const int    dir,
                        const double candidateSL,
                        const double openPrice);

//--- Проверяет шаговый порог. При stepPoints == 0 — всегда true
//    (любое улучшение допустимо).
bool   ImprovementMeetsStep(const int    dir,
                            const double candidateSL,
                            const double currentSL,
                            const double point,
                            const double stepPoints);

//--- Возвращает true, если candidateSL строго «лучше» currentSL:
//    BUY  → candidateSL > currentSL
//    SELL → candidateSL < currentSL
bool   IsStrictImprovement(const int    dir,
                           const double candidateSL,
                           const double currentSL);

//--- Вычисляет newTP от newSL и зафиксированного blockSize.
//    BUY  → newSL + blockSize
//    SELL → newSL - blockSize
double ComputeNewTP(const int    dir,
                    const double newSL,
                    const double blockSize);

//--- Возвращает true, если minBrokerDistance соблюдена для пары
//    (newSL, newTP) относительно текущих цен.
//    BUY  → currentBid - newSL >= minBrokerDistance И
//           newTP - currentBid >= minBrokerDistance
//    SELL → newSL - currentAsk >= minBrokerDistance И
//           currentAsk - newTP >= minBrokerDistance
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
//| vectors совпадали с MQL5-реализацией для одних и                 |
//| тех же входов (IEEE-754, одинаковая алгебра).                    |
//+------------------------------------------------------------------+

//--- Кандидат SL без брокерских / шаговых проверок.
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

//--- Клампинг кандидата к openPrice (нельзя «ниже безубытка»).
double ClampToBreakeven(const int    dir,
                        const double candidateSL,
                        const double openPrice)
  {
   if(dir == 1)
      return MathMax(candidateSL, openPrice);
   return MathMin(candidateSL, openPrice);
  }

//--- Строгое улучшение SL (без epsilon).
bool IsStrictImprovement(const int    dir,
                         const double candidateSL,
                         const double currentSL)
  {
   if(dir == 1)
      return candidateSL > currentSL;
   return candidateSL < currentSL;
  }

//--- Шаговый порог. stepPoints == 0 ⇒ всегда true.
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

//--- newTP от newSL и зафиксированного blockSize.
double ComputeNewTP(const int    dir,
                    const double newSL,
                    const double blockSize)
  {
   if(dir == 1)
      return newSL + blockSize;
   return newSL - blockSize;
  }

//--- Проверка обеих брокерских дистанций.
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
