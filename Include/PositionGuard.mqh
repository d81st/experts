//+------------------------------------------------------------------+
//|                                                PositionGuard.mqh  |
//|                                                                  |
//|  Безопасные операции над позициями и pending-ордерами текущего   |
//|  символа и магического номера.                                   |
//|                                                                  |
//|  Feature: ea-modular-architecture                                |
//|  Spec:    .kiro/specs/ea-modular-architecture/design.md          |
//|                                                                  |
//|  Champion: crt-bot — `PendingOrderStillExists(ulong ticket)` с   |
//|  явным тикетом. Модуль не читает глобалов EA — ticket передаётся |
//|  параметром. Engulfing после миграции передаёт свой              |
//|  g_pending_ticket явно при каждом вызове.                        |
//+------------------------------------------------------------------+
#ifndef POSITIONGUARD_MQH
#define POSITIONGUARD_MQH

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Публичный интерфейс (прототипы).                                 |
//|                                                                  |
//| Все функции — детерминированные относительно (_Symbol, magic,    |
//| состояние терминала на момент вызова), без глобального состояния |
//| модуля. Cross-magic safety: фильтр POSITION/ORDER_SYMBOL и       |
//| POSITION/ORDER_MAGIC перед каждой мутирующей операцией.          |
//+------------------------------------------------------------------+

//--- Проверка «есть ли открытая позиция нашего символа и magic».
//    Обходит `PositionsTotal()` по индексу от `0` до `total-1`.
//    При первом совпадении `POSITION_SYMBOL == _Symbol` и
//    `POSITION_MAGIC == magic` записывает `ENUM_POSITION_TYPE`
//    позиции в `type` и возвращает `true`, прекращая дальнейший
//    обход (Req 4.1).
//    При полном обходе без совпадений (включая `PositionsTotal() == 0`)
//    возвращает `false` и оставляет `type` идентичным значению
//    на входе в функцию (Req 4.2).
//    Не вызывает `trade.*`, не модифицирует глобальные переменные
//    вызывающего EA и не изменяет торговое состояние терминала
//    (Req 4.9, 4.10).
bool PositionGuardHasOpen(const long          magic,
                          ENUM_POSITION_TYPE &type);

//--- Закрытие всех открытых позиций нашего символа и magic.
//    Обходит `PositionsTotal()` от `total-1` к `0` включительно.
//    Для каждого тикета с `POSITION_SYMBOL == _Symbol` и
//    `POSITION_MAGIC == magic` вызывает `trade.PositionClose(ticket)`
//    ровно один раз; продолжает итерацию при отказе отдельного
//    вызова и фиксирует неудачу через `Print` (Req 4.3, 12.9).
//    Возвращает количество вызовов `trade.PositionClose`,
//    вернувших `true` (Req 4.3).
//    Никогда не вызывает `trade.PositionClose` для тикетов с
//    `POSITION_SYMBOL != _Symbol` или `POSITION_MAGIC != magic`
//    (Req 4.5, 12.1, 12.2).
//    При `magic <= 0` возвращается без обхода `PositionsTotal()`
//    и без единого вызова `trade.PositionClose` (Req 12.8).
//    При `PositionsTotal() == 0` или отсутствии совпадений по
//    фильтру — завершается без мутирующих вызовов и без записи
//    ошибок (Req 12.7).
int PositionGuardCloseAll(CTrade     &tr,
                          const long  magic);

//--- Проверка «pending-ордер с данным тикетом всё ещё существует».
//    Возвращает `true` тогда и только тогда, когда одновременно:
//      OrderSelect(ticket) == true,
//      OrderGetInteger(ORDER_TYPE) ∈ { ORDER_TYPE_BUY_LIMIT,
//        ORDER_TYPE_SELL_LIMIT, ORDER_TYPE_BUY_STOP,
//        ORDER_TYPE_SELL_STOP, ORDER_TYPE_BUY_STOP_LIMIT,
//        ORDER_TYPE_SELL_STOP_LIMIT },
//      OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED
//    (Req 4.7).
//    При `OrderSelect(ticket) == false` возвращает `false` без
//    последующих вызовов `OrderGet*` по этому тикету (Req 4.8).
//    Не вызывает `trade.*`, не модифицирует глобальные переменные
//    вызывающего EA и не изменяет торговое состояние терминала
//    (Req 4.9, 4.10).
//    Тикет всегда передаётся явно — модуль не читает глобальных
//    ticket-флагов EA (champion: crt-bot, §10.7).
bool PositionGuardPendingExists(const ulong ticket);

//--- Отмена всех pending-ордеров нашего символа и magic.
//    Обходит `OrdersTotal()` от `total-1` к `0` включительно.
//    Для каждого тикета с `ORDER_SYMBOL == _Symbol` и
//    `ORDER_MAGIC == magic` вызывает `trade.OrderDelete(ticket)`
//    ровно один раз; продолжает итерацию при отказе отдельного
//    вызова и фиксирует неудачу через `Print` (Req 4.4, 12.9).
//    Возвращает количество вызовов `trade.OrderDelete`,
//    вернувших `true` (Req 4.4).
//    Никогда не вызывает `trade.OrderDelete` для тикетов с
//    `ORDER_SYMBOL != _Symbol` или `ORDER_MAGIC != magic`
//    (Req 4.6, 12.3, 12.4).
//    При `magic <= 0` возвращается без обхода `OrdersTotal()`
//    и без единого вызова `trade.OrderDelete` (Req 12.8).
//    При `OrdersTotal() == 0` или отсутствии совпадений по
//    фильтру — завершается без мутирующих вызовов и без записи
//    ошибок (Req 12.7).
int PositionGuardCancelAllPending(CTrade     &tr,
                                  const long  magic);

//+------------------------------------------------------------------+
//| Реализации.                                                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| PositionGuardHasOpen                                             |
//|                                                                  |
//| Обход PositionsTotal() от 0 до total-1. При первом совпадении    |
//| (_Symbol + magic) пишет ENUM_POSITION_TYPE в type и возвращает   |
//| true. При полном обходе без совпадений возвращает false,         |
//| `type` не модифицируется. Никаких trade.* / мутирующих операций. |
//|                                                                  |
//| Защитный continue при ticket == 0 страхует от аномалий терминала.|
//+------------------------------------------------------------------+
bool PositionGuardHasOpen(const long magic, ENUM_POSITION_TYPE &type)
  {
   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| PositionGuardCloseAll                                            |
//|                                                                  |
//| Обход PositionsTotal() от total-1 к 0 (направление обязательно — |
//| tr.PositionClose уменьшает total и сдвигает индексы). Перед      |
//| каждым вызовом — двойной guard _Symbol + magic. Лог при отказе   |
//| отдельного PositionClose не прерывает обход (best-effort).       |
//|                                                                  |
//| Early-exit при magic <= 0: 0 зарезервирован для ручных сделок,   |
//| обход мог бы случайно совпасть с ручными позициями.              |
//+------------------------------------------------------------------+
int PositionGuardCloseAll(CTrade &tr, const long magic)
  {
   if(magic <= 0) return 0;              // Req 12.8: early exit
   int closed = 0;
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      // Req 4.5, 12.1, 12.2: cross-magic guard
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)   continue;
      if(tr.PositionClose(ticket))
         closed++;
      else
         PrintFormat("PositionGuardCloseAll: PositionClose(%I64u) failed, retcode=%u",
                     ticket, tr.ResultRetcode()); // Req 12.9 — log but continue
     }
   return closed;
  }

//+------------------------------------------------------------------+
//| PositionGuardPendingExists                                       |
//|                                                                  |
//| Возвращает true ⇔ OrderSelect(ticket) И тип ∈ {BUY_LIMIT,        |
//| SELL_LIMIT, BUY_STOP, SELL_STOP, BUY_STOP_LIMIT, SELL_STOP_LIMIT}|
//| И ORDER_STATE_PLACED.                                            |
//|                                                                  |
//| При OrderSelect == false — return false БЕЗ последующих          |
//| OrderGet* по этому тикету (защита от «висячего» order-context).  |
//|                                                                  |
//| Тикет передаётся явно — модуль не читает глобалов EA.            |
//+------------------------------------------------------------------+
bool PositionGuardPendingExists(const ulong ticket)
  {
   if(!OrderSelect(ticket))
      return false;                       // Req 4.8: ни одного OrderGet* после false

   const ENUM_ORDER_TYPE  type  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   const ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE);

   const bool isPendingType =
      (type == ORDER_TYPE_BUY_LIMIT       ||
       type == ORDER_TYPE_SELL_LIMIT      ||
       type == ORDER_TYPE_BUY_STOP        ||
       type == ORDER_TYPE_SELL_STOP       ||
       type == ORDER_TYPE_BUY_STOP_LIMIT  ||
       type == ORDER_TYPE_SELL_STOP_LIMIT);

   return (isPendingType && state == ORDER_STATE_PLACED);  // Req 4.7
  }

//+------------------------------------------------------------------+
//| PositionGuardCancelAllPending                                    |
//|                                                                  |
//| Обход OrdersTotal() от total-1 к 0 (tr.OrderDelete сдвигает      |
//| индексы; обратный порядок безопасен). OrderGetTicket(i) выбирает |
//| ордер для последующих OrderGetString/OrderGetInteger без         |
//| отдельного OrderSelect.                                           |
//|                                                                  |
//| Cross-magic guard: tr.OrderDelete только при двойном             |
//| совпадении _Symbol + magic. Early-exit при magic<=0. Отказ       |
//| OrderDelete логируется, но обход продолжается (best-effort).     |
//+------------------------------------------------------------------+
int PositionGuardCancelAllPending(CTrade &tr, const long magic)
  {
   if(magic <= 0) return 0;              // Req 12.8: ранний выход без обхода

   int cancelled = 0;
   const int total = OrdersTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      // Req 4.6, 12.3, 12.4: cross-magic guard — оба фильтра обязательны
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)   continue;

      if(tr.OrderDelete(ticket))
         cancelled++;
      else
         PrintFormat("PositionGuardCancelAllPending: OrderDelete(%I64u) failed, retcode=%u",
                     ticket, tr.ResultRetcode());  // Req 12.9 — log but continue
     }
   return cancelled;
  }

#endif // POSITIONGUARD_MQH
//+------------------------------------------------------------------+
