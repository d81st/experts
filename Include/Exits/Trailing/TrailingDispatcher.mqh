//+------------------------------------------------------------------+
//|                                           TrailingDispatcher.mqh |
//|                                                                  |
//|  Trailing mode dispatcher — единая точка вызова трейлинга:       |
//|  switch по `ENUM_TRAILING_MODE_EX` между OFF / BREAKEVEN / SYNC. |
//|                                                                  |
//|  Объявляет ENUM_TRAILING_MODE_EX, TrailingConfig и прототип      |
//|  TrailingManage. Реализация делегирует в подмодули:              |
//|   - OFF       → no-op                                            |
//|   - BREAKEVEN → BreakevenTrailManage                             |
//|   - SYNC      → SyncTrailManage (SyncTrailManager.mqh)           |
//|                                                                  |
//|  Модуль НЕ объявляет input-переменных; состояние SYNC по тикетам |
//|  хранит SyncTrailManager.                                        |
//|  Cross-magic фильтрация — в подмодулях.                          |
//+------------------------------------------------------------------+
#ifndef TRAILINGDISPATCHER_MQH
#define TRAILINGDISPATCHER_MQH

#include "../../Core/TradeAdapter.mqh"
#include "../../Core/BrokerAdapter.mqh"
#include "SyncTrailManager.mqh"
#include "BreakevenTrail.mqh"

//+------------------------------------------------------------------+
//| ENUM_TRAILING_MODE_EX — режим трейлинга (входной параметр ботов).|
//|                                                                  |
//|   TRAILING_OFF_EX       — без трейлинга                          |
//|   TRAILING_BREAKEVEN_EX — однократный breakeven + offset         |
//|                          (делегирует BreakevenTrail)             |
//|   TRAILING_SYNC_EX      — синхронный трейлинг блока SL/TP        |
//|                          (делегирует SyncTrailManage)            |
//+------------------------------------------------------------------+
enum ENUM_TRAILING_MODE_EX
  {
   TRAILING_OFF_EX       = 0,   // Без трейлинга
   TRAILING_BREAKEVEN_EX = 1,   // Перевод SL в безубыток
   TRAILING_SYNC_EX      = 2    // Синхронный трейлинг SL и TP
  };

//+------------------------------------------------------------------+
//| TrailingConfig — параметры трейлинга. Заполняется в OnInit EA из |
//| input-переменных, далее передаётся неизменно. Диспетчер cfg не   |
//| модифицирует.                                                    |
//|                                                                  |
//|   mode            — выбранный режим                              |
//|   startFactor     — порог активации: profitPts >= startFactor *  |
//|                     slDistPts (BREAKEVEN/SYNC)                   |
//|   breakevenOffset — оффсет в пунктах для BREAKEVEN               |
//|   trailStep       — шаг трейлинга в пунктах для SYNC             |
//|                     (0 ⇒ любое улучшение)                        |
//+------------------------------------------------------------------+
struct TrailingConfig
  {
   ENUM_TRAILING_MODE_EX mode;
   double                startFactor;
   double                breakevenOffset;
   double                trailStep;
  };

//+------------------------------------------------------------------+
//| TrailingManage — диспетчер режимов трейлинга.                    |
//|                                                                  |
//|   adapter — ITradeAdapter (RealTradeAdapter). При NULL           |
//|             диспетчер выполняет no-op.                           |
//|   broker  — заполненный BrokerContext (adjustedPoint /           |
//|             minBrokerDistance используются в подмодулях).        |
//|   magic   — POSITION_MAGIC фильтр. При magic <= 0 — no-op.       |
//|   cfg     — конфигурация (см. TrailingConfig).                   |
//|                                                                  |
//| Поведение:                                                       |
//|   OFF                  → no-op                                   |
//|   BREAKEVEN            → BreakevenTrailManage(adapter, broker,   |
//|                          magic, startFactor, breakevenOffset)    |
//|   SYNC                 → SyncTrailManage(adapter, broker, magic, |
//|                          startFactor, trailStep)                 |
//|   unknown / magic<=0   → no-op                                   |
//|                                                                  |
//| Cross-magic фильтрация — в подмодулях.                           |
//+------------------------------------------------------------------+
void TrailingManage(ITradeAdapter      *adapter,
                    const BrokerContext &broker,
                    const long           magic,
                    const TrailingConfig &cfg);

//+------------------------------------------------------------------+
//| TrailingManage — реализация.                                     |
//+------------------------------------------------------------------+
void TrailingManage(ITradeAdapter      *adapter,
                    const BrokerContext &broker,
                    const long           magic,
                    const TrailingConfig &cfg)
  {
   if(magic <= 0)
      return;

   // adapter обязан быть не-NULL для любой реальной работы; для OFF не используется.
   if(adapter == NULL && cfg.mode != TRAILING_OFF_EX)
      return;

   switch(cfg.mode)
     {
      case TRAILING_OFF_EX:
         return;

      case TRAILING_BREAKEVEN_EX:
         BreakevenTrailManage(adapter,
                              broker,
                              magic,
                              cfg.startFactor,
                              cfg.breakevenOffset);
         return;

      case TRAILING_SYNC_EX:
         SyncTrailManage(adapter,
                         broker,
                         magic,
                         cfg.startFactor,
                         cfg.trailStep);
         return;

      default:
         return;
     }
  }

#endif // TRAILINGDISPATCHER_MQH
//+------------------------------------------------------------------+
