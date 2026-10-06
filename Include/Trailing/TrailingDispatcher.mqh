//+------------------------------------------------------------------+
//|                                          TrailingDispatcher.mqh  |
//|                                                                  |
//|  Trailing mode dispatcher — единая точка вызова трейлинга:        |
//|  switch по `ENUM_TRAILING_MODE_EX` между OFF / BREAKEVEN / SYNC. |
//|                                                                  |
//|  Объявляет ENUM_TRAILING_MODE_EX, TrailingConfig и прототип      |
//|  TrailingManage. Реализация делегирует в подмодули:              |
//|   - OFF       → no-op                                            |
//|   - BREAKEVEN → BreakevenTrailManage                             |
//|   - SYNC      → менеджер из SyncTrail.mqh (см. ниже — пока no-op)|
//|                                                                  |
//|  Модуль НЕ объявляет input-переменных и НЕ держит состояния.     |
//|  Cross-magic фильтрация — в подмодулях.                          |
//+------------------------------------------------------------------+
#ifndef TRAILINGDISPATCHER_MQH
#define TRAILINGDISPATCHER_MQH

#include "../TradeAdapter.mqh"
#include "../BrokerAdapter.mqh"
#include "SyncTrail.mqh"
#include "BreakevenTrail.mqh"

//+------------------------------------------------------------------+
//| ENUM_TRAILING_MODE_EX — расширенный режим трейлинга.              |
//|                                                                  |
//| `_EX`-суффикс намеренно отличается от ENUM_TRAILING_MODE в       |
//| SyncTrail.mqh для избежания конфликта при одновременном include. |
//|                                                                  |
//|   TRAILING_OFF_EX       — без трейлинга                          |
//|   TRAILING_BREAKEVEN_EX — однократный breakeven + offset         |
//|                          (делегирует BreakevenTrail)             |
//|   TRAILING_SYNC_EX      — синхронный трейлинг блока SL/TP        |
//|                          (делегирует SyncTrail)                  |
//+------------------------------------------------------------------+
enum ENUM_TRAILING_MODE_EX
  {
   TRAILING_OFF_EX       = 0,
   TRAILING_BREAKEVEN_EX = 1,
   TRAILING_SYNC_EX      = 2
  };

//+------------------------------------------------------------------+
//| TrailingConfig — параметры трейлинга. Заполняется в OnInit EA из |
//| input-переменных, далее передаётся неизменно. Диспетчер cfg не   |
//| модифицирует.                                                     |
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
//| TrailingManage — диспетчер режимов трейлинга.                     |
//|                                                                  |
//|   adapter — ITradeAdapter (production RealTradeAdapter, тесты —  |
//|             mock). При NULL диспетчер выполняет no-op.           |
//|   broker  — заполненный BrokerContext (adjustedPoint /           |
//|             minBrokerDistance используются в подмодулях).        |
//|   magic   — POSITION_MAGIC фильтр. При magic <= 0 — no-op.       |
//|   cfg     — конфигурация (см. TrailingConfig).                   |
//|                                                                  |
//| Поведение:                                                       |
//|   OFF                  → no-op                                   |
//|   BREAKEVEN            → BreakevenTrailManage(adapter, broker,   |
//|                          magic, startFactor, breakevenOffset)    |
//|   SYNC                 → see implementation (currently no-op)    |
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
         // Известное ограничение: SyncTrail.mqh пока экспортирует только pure-хелперы,
         // а per-ticket state-машина SYNC-трейлинга живёт в EA (crt-bot::ManageSyncTrailing).
         // До экспорта SyncTrailManage(magic, startFactor, trailStep) диспетчер
         // физически не может делегировать SYNC сюда — попытка приведёт к потере
         // per-ticket контекста. Поэтому здесь no-op, а SYNC обслуживается EA напрямую.
         // Cross-magic фильтрация для SYNC обеспечивается EA-side фильтром по POSITION_MAGIC.
         return;

      default:
         return;
     }
  }

#endif // TRAILINGDISPATCHER_MQH
//+------------------------------------------------------------------+
