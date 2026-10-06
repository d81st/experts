//+------------------------------------------------------------------+
//|                                                BrokerAdapter.mqh |
//|                                                                  |
//|  Модуль брокерских особенностей: fill type, adjustedPoint,       |
//|  размер лота, минимальная брокерская дистанция, нормализация.    |
//+------------------------------------------------------------------+
//
// Кратко:
//   - Lot sizing: LOT_BY_TICK_VALUE — лот от расстояния до SL, риск
//     сделки = riskPercent от баланса (все боты).
//   - Min-SL-distance: TP модулем не модифицируется
//     (ответственность caller'а).
//   - crt-bot caller-side TP recalc: при подтяжке SL к min_dist TP
//     пересчитывается с сохранением implicit-RR старого TP.
//

#ifndef BROKERADAPTER_MQH
#define BROKERADAPTER_MQH

//+------------------------------------------------------------------+
//| BrokerContext — структура брокерских параметров текущего символа.|
//|                                                                  |
//| Заполняется один раз в `BrokerInit()` на основании `_Symbol` и   |
//| дальше передаётся как `const &` во все остальные публичные       |
//| функции модуля. Caller не модифицирует поля напрямую.            |
//|                                                                  |
//|   adjustedPoint     — размер «пункта» с поправкой на digits      |
//|                       (digits ∈ {3,5} → _Point;                  |
//|                        digits ∈ {2,4} → _Point/10.0;             |
//|                        иначе fallback _Point).                   |
//|                       Используется для перевода points ↔ price.  |
//|   minBrokerDistance — минимальная допустимая SL-дистанция в      |
//|                       единицах цены: (SYMBOL_TRADE_STOPS_LEVEL   |
//|                       + 3) * _Point. Используется в              |
//|                       `BrokerEnforceMinSLDist`.                  |
//|   fillType          — режим заливки ордера, выбранный по         |
//|                       приоритету FOK → IOC → RETURN из битовой   |
//|                       маски `SYMBOL_FILLING_MODE`                |
//|                       (fallback).                                |
//+------------------------------------------------------------------+
struct BrokerContext
  {
   double                    adjustedPoint;
   double                    minBrokerDistance;
   ENUM_ORDER_TYPE_FILLING   fillType;
  };

//+------------------------------------------------------------------+
//| ENUM_LOT_STRATEGY — стратегия расчёта объёма в `BrokerCalcLot`.  |
//|                                                                  |
//| См. шапку этого файла, раздел «Lot sizing».                      |
//|                                                                  |
//|   LOT_BY_TICK_VALUE — «SL-аккуратный» сайзинг: лот обратно       |
//|                       пропорционален SL-дистанции, реальный      |
//|                       риск-в-деньгах ≈ riskPercent от баланса    |
//|                       вне зависимости от SL.                     |
//|                       Используется во всех ботах.                |
//+------------------------------------------------------------------+
enum ENUM_LOT_STRATEGY
  {
   LOT_BY_TICK_VALUE = 0
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс (прототипы).                                 |
//|                                                                  |
//| Все функции — детерминированные относительно входов и состояния  |
//| `_Symbol` / `AccountInfo*`. Модуль НЕ объявляет `input`-         |
//| переменных и НЕ держит глобального состояния. Конфигурация и     |
//| состояние передаются через `BrokerContext`.                      |
//+------------------------------------------------------------------+

//--- Инициализация BrokerContext по текущему `_Symbol`.
//    Заполняет ctx.adjustedPoint,
//    ctx.minBrokerDistance и ctx.fillType.
//    Должна вызываться один раз в `OnInit()` ДО первой торговой
//    операции.
//    Идемпотентность: повторный вызов для того же `_Symbol` без
//    изменения SYMBOL_DIGITS, SYMBOL_POINT, SYMBOL_TRADE_STOPS_LEVEL
//    и SYMBOL_FILLING_MODE даёт побитово равный BrokerContext
//    относительно первого вызова.
void BrokerInit(BrokerContext &ctx);

//--- Возвращает режим заливки текущего `_Symbol` по приоритету
//    FOK → IOC → RETURN на основе битовой маски
//    `SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)`.
//    Если маска не содержит ни одного из бит FOK/IOC/RETURN —
//    возвращается `ORDER_FILLING_RETURN` как безопасный fallback.
ENUM_ORDER_TYPE_FILLING BrokerGetFillType(void);

//--- Расчёт объёма позиции по выбранной стратегии.
//    При `strategy == LOT_BY_TICK_VALUE` и валидных входах
//    (slPoints > 0, tickValue > 0, tickSize > 0,
//     0 < riskPercent <= 100): лот считается как
//        riskMoney / ((slPoints * ctx.adjustedPoint / tickSize) * tickValue),
//    где riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) *
//                    riskPercent / 100.0.
//    Возвращаемое значение ограничивается диапазоном
//    [SYMBOL_VOLUME_MIN, SYMBOL_VOLUME_MAX] и округляется вниз до
//    кратности SYMBOL_VOLUME_STEP.
//    Защита от деления на 0: если slPoints <= 0, tickValue == 0
//    или tickSize == 0 — возвращается SYMBOL_VOLUME_MIN.
//    maxRiskOvershoot > 0: если даже минимальный
//    лот рискует больше riskMoney * maxRiskOvershoot — возвращается 0,
//    и вызывающий EA должен пропустить сделку. 0 — проверка выключена.
double BrokerCalcLot(const BrokerContext     &ctx,
                     const double             riskPercent,
                     const double             slPoints,
                     const ENUM_LOT_STRATEGY  strategy,
                     const double             maxRiskOvershoot = 0.0);

//--- Принуждение минимальной SL-дистанции.
//    Если |entry - sl| < ctx.minBrokerDistance — модифицирует
//    `sl` так, что |entry - sl| == ctx.minBrokerDistance, сохраняя
//    направление SL относительно `entry` для типа `orderType`
//    (BUY/BUY_LIMIT: sl < entry; SELL/SELL_LIMIT: sl > entry).
//    Если |entry - sl| >= ctx.minBrokerDistance — `sl` остаётся
//    без изменений.
//    TP не модифицируется: пересчёт TP — ответственность caller'а
//    по EA-специфичной формуле (RR или абсолют от паттерна),
//    см. BrokerEnforceMinSLDist ниже.
void BrokerEnforceMinSLDist(const BrokerContext   &ctx,
                            const ENUM_ORDER_TYPE  orderType,
                            const double           entry,
                            double                &sl);

//+------------------------------------------------------------------+
//| Реализации.                                                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| BrokerGetFillType                                                |
//|                                                                  |
//| Читает SYMBOL_FILLING_MODE для _Symbol; возвращает по приоритету |
//| FOK → IOC → RETURN. RETURN — безопасный fallback:                |
//| бит SYMBOL_FILLING_RETURN в маске у большинства                  |
//| брокеров отсутствует, но режим RETURN исполняется всегда.        |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING BrokerGetFillType(void)
  {
   const uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;

   // Fallback SYMBOL_FILLING_RETURN-бит может отсутствовать
   // в маске, но режим RETURN — гарантированно исполнимый по биржевой
   // спецификации MQL5, поэтому используется как безопасный fallback.
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| BrokerInit                                                       |
//|                                                                  |
//| Заполняет BrokerContext по текущему _Symbol:                     |
//|   ctx.fillType          = BrokerGetFillType()                    |
//|   ctx.adjustedPoint     — по SYMBOL_DIGITS:                      |
//|     digits ∈ {3,5} → _Point                                      |
//|     digits ∈ {2,4} → _Point / 10.0                               |
//|     иначе         → _Point (fallback)                            |
//|   ctx.minBrokerDistance = (SYMBOL_TRADE_STOPS_LEVEL + 3) * _Point|
//|                                                                  |
//| Идемпотентность гарантирована тем, что все поля заполняются      |
//| детерминированно из свойств _Symbol — повторный вызов при        |
//| неизменных свойствах даёт побитово равный результат.             |
//+------------------------------------------------------------------+
void BrokerInit(BrokerContext &ctx)
  {
   //--- 1. Fill type
   ctx.fillType = BrokerGetFillType();

   //--- 2. AdjustedPoint по правилам digits
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
      ctx.adjustedPoint = _Point;
   else if(digits == 4 || digits == 2)
      ctx.adjustedPoint = _Point / 10.0;
   else
      ctx.adjustedPoint = _Point;                 // fallback

   //--- 3. Min broker distance
   const long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   ctx.minBrokerDistance  = (stops_level + 3) * _Point;
  }

//+------------------------------------------------------------------+
//| BrokerCalcLot                                                    |
//|                                                                  |
//| LOT_BY_TICK_VALUE:                                               |
//|   moneyPerLot = (slPoints * adjustedPoint / tickSize) * tickValue|
//|   lot = riskMoney / moneyPerLot                                  |
//|   Защита: slPoints<=0 / tickValue==0 / tickSize==0               |
//|   → volMin.                                                      |
//|   maxRiskOvershoot > 0: риск минимального лота                   |
//|   > riskMoney * maxRiskOvershoot → 0 (сделку пропустить).        |
//|                                                                  |
//| Клампинг: сначала floor до volStep, затем clamp в                |
//| [volMin, volMax]. Порядок важен: floor может дать значение       |
//| меньше volMin — его поднимаем обратно.                           |
//+------------------------------------------------------------------+
double BrokerCalcLot(const BrokerContext     &ctx,
                     const double             riskPercent,
                     const double             slPoints,
                     const ENUM_LOT_STRATEGY  strategy,
                     const double             maxRiskOvershoot)
  {
   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * riskPercent / 100.0;
   const double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = volMin;

   if(strategy == LOT_BY_TICK_VALUE)
     {
      const double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      const double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      //--- защита от деления на 0 / невалидного SL.
      //    Возврат volMin.
      if(slPoints <= 0.0 || tickValue == 0.0 || tickSize == 0.0)
         return volMin;
      const double moneyPerLot = (slPoints * ctx.adjustedPoint / tickSize) * tickValue;
      if(moneyPerLot <= 0.0)
         return volMin;
      lot = riskMoney / moneyPerLot;

      //--- минимальный лот рискует слишком много — сделку пропускаем.
      const double minLotRisk = moneyPerLot * volMin;
      if(maxRiskOvershoot > 0.0 && minLotRisk > riskMoney * maxRiskOvershoot)
        {
         PrintFormat("🚫 Лот %.2f рискует %.2f %s > %.2f (%.1f%% × %.1f) — сделка пропущена",
                     volMin, minLotRisk, AccountInfoString(ACCOUNT_CURRENCY),
                     riskMoney * maxRiskOvershoot, riskPercent, maxRiskOvershoot);
         return 0.0;
        }
     }

   //--- округление ВНИЗ до volStep, затем клампинг в
   //    [volMin, volMax]. Порядок важен: floor может дать значение
   //    меньше volMin, его необходимо поднять обратно до volMin.
   if(volStep > 0.0)
      lot = MathFloor(lot / volStep) * volStep;
   if(lot < volMin) lot = volMin;
   if(lot > volMax) lot = volMax;
   return lot;
  }

//+------------------------------------------------------------------+
//| BrokerEnforceMinSLDist                                           |
//|                                                                  |
//|   |entry - sl| >= minBrokerDistance → no-op                      |
//|   иначе sl = entry ∓ minBrokerDistance (BUY/BUY_LIMIT            |
//|             sl < entry; SELL/SELL_LIMIT sl > entry)              |
//|   TP НИКОГДА не модифицируется этим модулем                      |
//|                                                                  |
//| Пересчёт TP по EA-специфичной формуле — на стороне caller'а:     |
//|   engulfing → CalcTPByRR (RR сохраняется)                        |
//|   liq-grab  → tp = entry ± slPoints * rrRatio                    |
//|   crt-bot   → tp = entry + sign(tp_old - entry)                  |
//|                        * minDist * RR_old                        |
//+------------------------------------------------------------------+
void BrokerEnforceMinSLDist(const BrokerContext   &ctx,
                            const ENUM_ORDER_TYPE  orderType,
                            const double           entry,
                            double                &sl)
  {
   //--- дистанция уже достаточна — no-op
   if(MathAbs(entry - sl) >= ctx.minBrokerDistance)
      return;

   //--- подтянуть sl до min-дистанции, сохранив направление
   if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_LIMIT)
     {
      // BUY/BUY_LIMIT: sl должен быть НИЖЕ entry
      sl = entry - ctx.minBrokerDistance;
     }
   else if(orderType == ORDER_TYPE_SELL || orderType == ORDER_TYPE_SELL_LIMIT)
     {
      // SELL/SELL_LIMIT: sl должен быть ВЫШЕ entry
      sl = entry + ctx.minBrokerDistance;
     }
   // Иначе (defensive, unreachable в production-пайплайне): sl без
   // изменений. TP не трогается ни в одной ветке.
  }

#endif // BROKERADAPTER_MQH
//+------------------------------------------------------------------+
