//+------------------------------------------------------------------+
//|                                                SessionFilter.mqh |
//|                                                                  |
//|  Session filter — конфигурация, состояние и прототипы            |
//|  публичных функций сессионного фильтра.                          |
//|                                                                  |
//|  Этот header объявляет:                                          |
//|   - SessionConfig — входная конфигурация                         |
//|   - SessionState  — заполняется SessionInit, дальше read-only    |
//|   - прототипы SessionInit / SessionIsBoundary /                  |
//|     SessionIsAmericanPreClose / SessionGetEffective              |
//|                                                                  |
//|  Тела функций реализованы ниже в этом же файле.                  |
//|  Модуль НЕ объявляет `input`-переменных и НЕ держит глобального  |
//|  состояния. Вся конфигурация                                     |
//|  и состояние передаются параметрами по ссылке.                   |
//|                                                                  |
//|  Функции модуля обращаются к `SymbolInfoSessionTrade` только     |
//|  внутри SessionInit и не вызывают `trade.*`, `PositionGet*`,     |
//|  `OrderGet*` или иные `SymbolInfo*` в остальных функциях.        |
//+------------------------------------------------------------------+
#ifndef SESSIONFILTER_MQH
#define SESSIONFILTER_MQH

//+------------------------------------------------------------------+
//| SessionConfig — входная конфигурация сессионного фильтра.        |
//|                                                                  |
//| Передаётся вызывающим EA как `const &` во все публичные функции  |
//| модуля. Поля заполняются из `input`-параметров EA и не           |
//| модифицируются модулем.                                          |
//|                                                                  |
//|   enabled             — глобальный switch фильтра. При false все |
//|                         проверочные функции возвращают false.    |
//|   americanCloseHour   — час закрытия Американской сессии         |
//|                         (ручной режим, fallback автодетекта).    |
//|   americanCloseMinute — минута закрытия Американской сессии.     |
//|   asianOpenHour       — час открытия Азиатской сессии (ручной).  |
//|   asianOpenMinute     — минута открытия Азиатской сессии.        |
//|   windowMinutes       — полуширина окна вокруг границы сессии    |
//|                         в минутах, допустимый диапазон [1, 120]. |
//+------------------------------------------------------------------+
struct SessionConfig
  {
   bool              enabled;
   int               americanCloseHour;
   int               americanCloseMinute;
   int               asianOpenHour;
   int               asianOpenMinute;
   int               windowMinutes;
  };

//+------------------------------------------------------------------+
//| SessionState — состояние, заполняемое SessionInit.               |
//|                                                                  |
//| После успешного SessionInit состояние трактуется как read-only:  |
//| SessionIsBoundary / SessionIsAmericanPreClose / SessionGetEffective
//| не модифицируют ни одного поля.                                  |
//|                                                                  |
//|   useAuto    — true, если SessionInit получил валидную           |
//|                информацию о сессиях от брокера через             |
//|                SymbolInfoSessionTrade и заполнил amCloseSec /    |
//|                asOpenSec из брокера.                             |
//|                false — если использован ручной fallback из cfg   |
//| либо невалидный cfg.                                             |
//|   amCloseSec — секунда суток (0..86399) закрытия Американской    |
//|                сессии. При useAuto=true — от брокера; иначе —    |
//|                из cfg.americanCloseHour/Minute.                  |
//|   asOpenSec  — секунда суток (0..86399) открытия Азиатской       |
//|                сессии. При useAuto=true — от брокера; иначе —    |
//|                из cfg.asianOpenHour/Minute.                      |
//+------------------------------------------------------------------+
struct SessionState
  {
   bool              useAuto;
   long              amCloseSec;
   long              asOpenSec;
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс (прототипы).                                 |
//|                                                                  |
//| Все функции — детерминированные                                  |
//| относительно (cfg, state, TimeCurrent()), без скрытого           |
//| глобального состояния.                                           |
//+------------------------------------------------------------------+

//--- Инициализация state по cfg.
//    1) Пробует автодетект через SymbolInfoSessionTrade по дням
//       MONDAY..FRIDAY; при успехе устанавливает state.useAuto=true
//       и возвращает true.
//    2) Иначе при валидных cfg.amCloseSec/asOpenSec — записывает их
//       в state, ставит useAuto=false, возвращает false.
//    3) Иначе оставляет amCloseSec/asOpenSec в state без изменений,
//       ставит useAuto=false, возвращает false.
//    Идемпотентность: повторный вызов с тем же cfg и без изменения
//    брокерской информации даёт идентичный state.
bool SessionInit(const SessionConfig &cfg,
                 SessionState        &state);

//--- Проверка «сейчас граница какой-либо сессии».
//    Возвращает true, если TimeCurrent() % 86400 находится в окне
//    ±(cfg.windowMinutes * 60) секунд от state.amCloseSec или от
//    state.asOpenSec с циркулярной арифметикой по модулю 86400.
//    При cfg.enabled=false — всегда false.
//    При невалидных cfg.windowMinutes или state.amCloseSec /
//    state.asOpenSec — false.
bool SessionIsBoundary(const SessionConfig &cfg,
                       const SessionState  &state);

//--- Проверка «сейчас окно перед закрытием Американской».
//    Возвращает true, если TimeCurrent() % 86400 находится в
//    полу-открытом окне (state.amCloseSec - cfg.windowMinutes*60,
//    state.amCloseSec] с циркулярной арифметикой по модулю 86400.
//    При cfg.enabled=false — всегда false.
//    При невалидных cfg.windowMinutes или state.amCloseSec — false.
bool SessionIsAmericanPreClose(const SessionConfig &cfg,
                               const SessionState  &state);

//--- Возвращает эффективные секунды суток сессионных границ
//    (для логирования / диагностики). Не модифицирует cfg/state.
void SessionGetEffective(const SessionConfig &cfg,
                         const SessionState  &state,
                         long                &amCloseSec,
                         long                &asOpenSec);

//+------------------------------------------------------------------+
//| trading-session-filter — новый публичный API.                    |
//|                                                                  |
//| Этот блок объявляет:                                             |
//|   - ENUM_DST_MODE — режим обработки часового пояса и DST         |
//|   - константы SELECTED_SESSIONS_*                                |
//|   - SelectedSessionsConfig — иммутабельная конфигурация фильтра  |
//|     выбранных сессий                                             |
//|   - SelectedSessionsState — мутабельное состояние фильтра        |
//|                                                                  |
//| Существующие декларации SessionConfig / SessionState и прототипы |
//| старого API сохраняются без изменений сигнатур.                  |
//+------------------------------------------------------------------+

//--- Режим обработки часового пояса и DST.
//    DST_AUTO   — effectiveGmtOffsetSec вычисляется как
//                 TimeTradeServer() − TimeGMT(), округлённый до
//                 15 минут.
//    DST_MANUAL — effectiveGmtOffsetSec фиксируется равным
//                 SelectedSessionsConfig.gmtOffsetSeconds.
enum ENUM_DST_MODE
  {
   DST_AUTO   = 0,
   DST_MANUAL = 1
  };

//--- Сентинелы и границы для нового API.
//    SEC_PER_DAY    — 24 часа в секундах (модуль секунд суток UTC).
//    DST_ROUND_SEC  — шаг округления автодетекта offset (15 минут).
//    DST_LOG_DELTA  — порог логирования изменения offset между
//                     тиками (30 минут).
//    GMT_MIN_SEC    — нижняя граница допустимого offset (UTC−12).
//    GMT_MAX_SEC    — верхняя граница допустимого offset (UTC+14).
#define SELECTED_SESSIONS_SEC_PER_DAY    86400L
#define SELECTED_SESSIONS_DST_ROUND_SEC  900L
#define SELECTED_SESSIONS_DST_LOG_DELTA  1800L
#define SELECTED_SESSIONS_GMT_MIN_SEC    (-43200L)
#define SELECTED_SESSIONS_GMT_MAX_SEC    (50400L)

//+------------------------------------------------------------------+
//| SelectedSessionsConfig — иммутабельная конфигурация фильтра.     |
//|                                                                  |
//| Заполняется EA в OnInit из input-параметров и передаётся в       |
//| публичные функции по `const &`. Модуль не модифицирует поля.     |
//|                                                                  |
//|   enabled                     — глобальный switch фильтра. При   |
//|                                  false `SelectedSessionsIsInside`|
//|                                  всегда возвращает false.        |
//|   useAsian, useLondon,        — флаги выбранных сессий из        |
//|   useNewYork                    Selected_Session_Set.            |
//|   asianStartSec, asianEndSec, — границы сессий в секундах суток  |
//|   londonStartSec, londonEndSec, UTC, диапазон [0, 86399]. Случай |
//|   nyStartSec, nyEndSec          start == end трактуется как      |
//|                                  пустая сессия.                  |
//|   gmtOffsetSeconds            — ручное смещение сервер→UTC в    |
//|                                  секундах, [-43200, 50400].      |
//|   dstMode                     — режим обработки часового пояса. |
//|   closeOnSessionExit          — флаг закрытия позиций при       |
//|                                  Session_Exit_Event.             |
//|   useBrokerSessionsAsFallback — опциональный broker-fallback для |
//|                                  London/NewYork границ.          |
//+------------------------------------------------------------------+
struct SelectedSessionsConfig
  {
   bool              enabled;
   bool              useAsian;
   bool              useLondon;
   bool              useNewYork;
   long              asianStartSec;
   long              asianEndSec;
   long              londonStartSec;
   long              londonEndSec;
   long              nyStartSec;
   long              nyEndSec;
   long              gmtOffsetSeconds;
   ENUM_DST_MODE     dstMode;
   bool              closeOnSessionExit;
   bool              useBrokerSessionsAsFallback;
  };

//+------------------------------------------------------------------+
//| SelectedSessionsState — мутабельное состояние фильтра.           |
//|                                                                  |
//| Обновляется только функциями SelectedSessions*.                  |
//|                                                                  |
//|   effectiveGmtOffsetSec     — текущее эффективное смещение       |
//|                                сервер→UTC в секундах. DST_AUTO   |
//|                                пересчитывает на каждом тике;    |
//|                                DST_MANUAL фиксирует в Init.      |
//|   wasInsideOnPreviousTick   — edge-trigger состояние для        |
//|                                Session_Exit_Event.               |
//|   lastEvaluatedUtcSec       — последний оценённый utcNowSec,    |
//|                                для диагностики.                  |
//|   lastEffectiveGmtOffsetSec — предыдущее значение offset, для   |
//|                                DST_AUTO change-detect.           |
//|   timeGmtFallbackLogged     — антиспам-флаг для предупреждения  |
//|                                «TimeGMT=0 → DST_MANUAL».         |
//+------------------------------------------------------------------+
struct SelectedSessionsState
  {
   long              effectiveGmtOffsetSec;
   bool              wasInsideOnPreviousTick;
   long              lastEvaluatedUtcSec;
   long              lastEffectiveGmtOffsetSec;
   bool              timeGmtFallbackLogged;
  };

//+------------------------------------------------------------------+
//| Реализации.                                                      |
//|                                                                  |
//| Приватный хелпер циркулярного расстояния и тела четырёх          |
//| публичных функций. Хелпер имеет уникальный префикс имени, чтобы  |
//| не конфликтовать с локальными утилитами вызывающих EA до         |
//| полного перевода на модуль.                                      |
//+------------------------------------------------------------------+

//--- Циркулярное расстояние между секундами суток t1 и t2 по        |
//    модулю 86400. Эквивалент эталонной формулы с базой 43200       |:
//    |
//        MathMin((t1 - t2 + 86400) % 86400,                         |
//                (t2 - t1 + 86400) % 86400)                         |
//    Возвращаемое значение в [0, 43200].                            |
long SessionFilter_CircularDist(const long t1, const long t2)
  {
   const long d1 = ((t1 - t2) % 86400 + 86400) % 86400;
   const long d2 = ((t2 - t1) % 86400 + 86400) % 86400;
   return (d1 < d2) ? d1 : d2;
  }

//--- Проверка валидности секунды суток.                             |
bool SessionFilter_IsValidSecOfDay(const long secOfDay)
  {
   return (secOfDay >= 0 && secOfDay <= 86399);
  }

//--- Компоновка H+M → секунда суток. Валидна, если результат в      |
//    [0, 86399] (что эквивалентно H ∈ [0,23] и M ∈ [0,59] для       |
//    нормальных входов; защищает от отрицательных и переполнения).  |
long SessionFilter_ComposeHM(const int hour, const int minute)
  {
   return (long)hour * 3600L + (long)minute * 60L;
  }

//--- SessionInit ----------------------------------------------------
//
// Алгоритм:
//
// 1) Перебираем дни MONDAY..FRIDAY (ENUM_DAY_OF_WEEK значения 1..5).
//    Для каждого дня сканируем все сессии по индексу через
//    SymbolInfoSessionTrade. При первой паре (from, to), у которой
//    from, to ∈ [0, 86399] и from != to, выходим из всех циклов,
//    выставляем state.useAuto = true, state.amCloseSec = to,
//    state.asOpenSec = from и возвращаем true.
//
// 2) Если автодетект не дал ни одной валидной пары — пытаемся
//    fallback на cfg. Компонуем cfgAm = americanCloseHour*3600 +
//    americanCloseMinute*60 и cfgAs = asianOpenHour*3600 +
//    asianOpenMinute*60. Если оба ∈ [0, 86399] — пишем их в state,
//    state.useAuto = false, возвращаем false.
//
// 3) Иначе оставляем state.amCloseSec / state.asOpenSec без
//    модификаций, ставим state.useAuto = false, возвращаем
//    false.
//
// SymbolInfoSessionTrade — единственное обращение к SymbolInfo* в
// модуле.
bool SessionInit(const SessionConfig &cfg,
                 SessionState        &state)
  {
   for(int day = MONDAY; day <= FRIDAY; day++)
     {
      uint     sessionIdx = 0;
      datetime sessFrom   = 0;
      datetime sessTo     = 0;
      while(SymbolInfoSessionTrade(_Symbol,
                                   (ENUM_DAY_OF_WEEK)day,
                                   sessionIdx,
                                   sessFrom,
                                   sessTo))
        {
         const long from = (long)sessFrom;
         const long to   = (long)sessTo;
         if(SessionFilter_IsValidSecOfDay(from) &&
            SessionFilter_IsValidSecOfDay(to)   &&
            from != to)
           {
            state.useAuto    = true;
            state.amCloseSec = to;
            state.asOpenSec  = from;
            return true;
           }
         sessionIdx++;
        }
     }
   // Автодетект не сработал — пробуем fallback на cfg.
   const long cfgAm = SessionFilter_ComposeHM(cfg.americanCloseHour,
                                              cfg.americanCloseMinute);
   const long cfgAs = SessionFilter_ComposeHM(cfg.asianOpenHour,
                                              cfg.asianOpenMinute);
   if(SessionFilter_IsValidSecOfDay(cfgAm) &&
      SessionFilter_IsValidSecOfDay(cfgAs))
     {
      state.useAuto    = false;
      state.amCloseSec = cfgAm;
      state.asOpenSec  = cfgAs;
      return false;
     }
   // cfg тоже невалиден — amCloseSec/asOpenSec в state не трогаем.
   state.useAuto = false;
   return false;
  }

//--- SessionIsBoundary ---------------------------------------------
//
// Возвращает true, если now = TimeCurrent() % 86400 находится в
// окне ±(cfg.windowMinutes * 60) секунд от state.amCloseSec или
// state.asOpenSec по циркулярной арифметике mod 86400.
//
// При cfg.enabled = false — false.
// При невалидных cfg.windowMinutes ∉ [1, 120] или state.amCloseSec /
// state.asOpenSec ∉ [0, 86399] — false без модификаций.
//
// Не вызывает trade.*, PositionGet*, OrderGet*, SymbolInfo*.
bool SessionIsBoundary(const SessionConfig &cfg,
                       const SessionState  &state)
  {
   if(!cfg.enabled)
      return false;
   if(cfg.windowMinutes < 1 || cfg.windowMinutes > 120)
      return false;
   if(!SessionFilter_IsValidSecOfDay(state.amCloseSec) ||
      !SessionFilter_IsValidSecOfDay(state.asOpenSec))
      return false;
   const long windowSec = (long)cfg.windowMinutes * 60L;
   const long now       = ((long)TimeCurrent() % 86400 + 86400) % 86400;
   if(SessionFilter_CircularDist(now, state.amCloseSec) <= windowSec)
      return true;
   if(SessionFilter_CircularDist(now, state.asOpenSec) <= windowSec)
      return true;
   return false;
  }

//--- SessionIsAmericanPreClose -------------------------------------
//
// Возвращает true, если now = TimeCurrent() % 86400 находится в
// полу-открытом окне (state.amCloseSec - windowSec, state.amCloseSec]
// с циркулярной арифметикой mod 86400.
//
// Эквивалентно: forwardDist(now → amCloseSec) ∈ [0, windowSec), где
// forwardDist = (amCloseSec - now + 86400) % 86400.
//
// При cfg.enabled = false — false.
// Те же guard'ы, что и в SessionIsBoundary.
bool SessionIsAmericanPreClose(const SessionConfig &cfg,
                               const SessionState  &state)
  {
   if(!cfg.enabled)
      return false;
   if(cfg.windowMinutes < 1 || cfg.windowMinutes > 120)
      return false;
   if(!SessionFilter_IsValidSecOfDay(state.amCloseSec) ||
      !SessionFilter_IsValidSecOfDay(state.asOpenSec))
      return false;
   const long windowSec   = (long)cfg.windowMinutes * 60L;
   const long now         = ((long)TimeCurrent() % 86400 + 86400) % 86400;
   const long forwardDist = ((state.amCloseSec - now) % 86400 + 86400) % 86400;
   return (forwardDist < windowSec);
  }

//--- SessionGetEffective -------------------------------------------
//
// Просто копирует state.amCloseSec / state.asOpenSec в out-параметры.
// Не модифицирует cfg / state. cfg оставлен в сигнатуре для будущего
// диагностического логирования (например, useAuto-флага).
void SessionGetEffective(const SessionConfig &cfg,
                         const SessionState  &state,
                         long                &amCloseSec,
                         long                &asOpenSec)
  {
   amCloseSec = state.amCloseSec;
   asOpenSec  = state.asOpenSec;
  }

//+------------------------------------------------------------------+
//| trading-session-filter — приватные чистые хелперы.               |
//|                                                                  |
//| Module-private утилиты, используемые только реализациями         |
//| SelectedSessions* публичных функций. Не объявляются в публичном  |
//| блоке прототипов и не предполагают вызова с EA-уровня (префикс   |
//| `SelectedSessions_*` маркирует internal API).                    |
//|                                                                  |
//| Контракты этих функций детерминированы относительно входных      |
//| параметров и (для ComputeUtcNowSec / TryBrokerFallback) одного   |
//| вызова платформенного API (`TimeTradeServer` / `_Symbol` +       |
//| `SymbolInfoSessionTrade`). Никаких обращений к `trade.*`,        |
//| `PositionGet*`, `OrderGet*`, `PositionSelect`, `OrderSelect`,    |
//| `HistorySelect`, `ExpertRemove`.                                 |
//+------------------------------------------------------------------+

//--- SelectedSessions_NormalizeSecOfDay -----------------------------
//
// Положительный остаток по модулю 86400. Для любого `long sec`
// возвращает значение в [0, 86399]. Используется при вычислении
// utcNowSec в ComputeUtcNowSec, где разность `TimeTradeServer() -
// offset` может быть отрицательной (при offset > server) или сильно
// превышать сутки (большие datetime-значения).
long SelectedSessions_NormalizeSecOfDay(const long sec)
  {
   return ((sec % SELECTED_SESSIONS_SEC_PER_DAY)
           + SELECTED_SESSIONS_SEC_PER_DAY)
          % SELECTED_SESSIONS_SEC_PER_DAY;
  }

//--- SelectedSessions_IsInOneSession --------------------------------
//
// Принадлежность секунды суток `t` к полу-открытому интервалу
// `[startSec, endSec)` на окружности Z/86400Z.
// Случаи:
//   - startSec == endSec → false (пустая сессия)
//   - startSec <  endSec → startSec ≤ t < endSec
//   - startSec >  endSec → t ≥ startSec OR t < endSec
//     (пересечение полуночи UTC)
//
// Все три аргумента предполагаются в [0, 86399]; ответственность за
// валидацию диапазона лежит на ValidateConfig.
bool SelectedSessions_IsInOneSession(const long t,
                                     const long startSec,
                                     const long endSec)
  {
   if(startSec == endSec)
      return false;
   if(startSec < endSec)
      return (t >= startSec && t < endSec);
   // startSec > endSec — overnight wrap.
   return (t >= startSec || t < endSec);
  }

//--- SelectedSessions_ComputeUtcNowSec ------------------------------
//
// UTC_Now в секундах суток по формуле:
//   utcNowSec = ((TimeTradeServer() − offset) mod 86400 + 86400)
//                mod 86400
//
// Гарантирует utcNowSec ∈ [0, 86399] для любого валидного offset
// в диапазоне [-43200, 50400] и любого корректного TimeTradeServer.
// `TimeTradeServer()` — единственное обращение к платформенному
// времени в этой функции; других побочных эффектов нет.
long SelectedSessions_ComputeUtcNowSec(const long effectiveGmtOffsetSec)
  {
   const long serverSec = (long)TimeTradeServer();
   return SelectedSessions_NormalizeSecOfDay(serverSec - effectiveGmtOffsetSec);
  }

//--- SelectedSessions_RoundOffsetToQuarterHour ----------------------
//
// Округление сырого offset (`TimeTradeServer() − TimeGMT()`) к
// ближайшим 900 секундам (15 минут) и clamp в диапазон
// [SELECTED_SESSIONS_GMT_MIN_SEC, SELECTED_SESSIONS_GMT_MAX_SEC].
//
// Round-half-away-from-zero на целочисленной арифметике:
//   raw ≥ 0  → ((raw + 450) / 900) * 900
//   raw <  0 → -(((-raw) + 450) / 900) * 900
//
// При корректном входе |rounded − raw| ≤ 450; после clamp могут
// возникать большие отклонения, но clamp сохраняет инвариант
// границ offset.
long SelectedSessions_RoundOffsetToQuarterHour(const long rawOffsetSec)
  {
   const long half = SELECTED_SESSIONS_DST_ROUND_SEC / 2;
   long       rounded;
   if(rawOffsetSec >= 0)
      rounded = ((rawOffsetSec + half) / SELECTED_SESSIONS_DST_ROUND_SEC)
                * SELECTED_SESSIONS_DST_ROUND_SEC;
   else
      rounded = -((( -rawOffsetSec) + half) / SELECTED_SESSIONS_DST_ROUND_SEC)
                * SELECTED_SESSIONS_DST_ROUND_SEC;
   if(rounded < SELECTED_SESSIONS_GMT_MIN_SEC)
      rounded = SELECTED_SESSIONS_GMT_MIN_SEC;
   if(rounded > SELECTED_SESSIONS_GMT_MAX_SEC)
      rounded = SELECTED_SESSIONS_GMT_MAX_SEC;
   return rounded;
  }

//--- SelectedSessions_ValidateConfig --------------------------------
//
// Проверка cfg перед использованием:
//   - Все шесть границ (asianStart/End, londonStart/End, nyStart/End)
//     ∈ [0, 86399].
//   - При dstMode == DST_MANUAL: gmtOffsetSeconds ∈
//     [SELECTED_SESSIONS_GMT_MIN_SEC, SELECTED_SESSIONS_GMT_MAX_SEC].
//
// Возвращает true, если cfg валиден; иначе false и заполняет
// errorMessage диагностической строкой с указанием параметра и
// его значения (используется в SelectedSessionsInit для одного
// Print при провале).
//
// Часы вне [0, 23] и минуты вне [0, 59] на EA-уровне дают
// секунду суток вне [0, 86399] (например, час=24 → 86400), что
// корректно отлавливается проверкой границы. Отдельная валидация
// часов/минут на стороне модуля не нужна (на момент вызова EA уже сложил час*3600 + минута*60).
bool SelectedSessions_ValidateConfig(const SelectedSessionsConfig &cfg,
                                     string                       &errorMessage)
  {
   if(!SessionFilter_IsValidSecOfDay(cfg.asianStartSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid asianStartSec="
                     + IntegerToString(cfg.asianStartSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(!SessionFilter_IsValidSecOfDay(cfg.asianEndSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid asianEndSec="
                     + IntegerToString(cfg.asianEndSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(!SessionFilter_IsValidSecOfDay(cfg.londonStartSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid londonStartSec="
                     + IntegerToString(cfg.londonStartSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(!SessionFilter_IsValidSecOfDay(cfg.londonEndSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid londonEndSec="
                     + IntegerToString(cfg.londonEndSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(!SessionFilter_IsValidSecOfDay(cfg.nyStartSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid nyStartSec="
                     + IntegerToString(cfg.nyStartSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(!SessionFilter_IsValidSecOfDay(cfg.nyEndSec))
     {
      errorMessage = "SelectedSessionsConfig: invalid nyEndSec="
                     + IntegerToString(cfg.nyEndSec)
                     + " (expected [0, 86399])";
      return false;
     }
   if(cfg.dstMode == DST_MANUAL &&
      (cfg.gmtOffsetSeconds < SELECTED_SESSIONS_GMT_MIN_SEC ||
       cfg.gmtOffsetSeconds > SELECTED_SESSIONS_GMT_MAX_SEC))
     {
      errorMessage = "SelectedSessionsConfig: invalid gmtOffsetSeconds="
                     + IntegerToString(cfg.gmtOffsetSeconds)
                     + " for DST_MANUAL (expected ["
                     + IntegerToString(SELECTED_SESSIONS_GMT_MIN_SEC)
                     + ", "
                     + IntegerToString(SELECTED_SESSIONS_GMT_MAX_SEC)
                     + "])";
      return false;
     }
   errorMessage = "";
   return true;
  }

//--- SelectedSessions_TryBrokerFallback -----------------------------
//
// Опциональный broker fallback для London/NewYork границ.
//
// Применяется только когда:
//   - cfg.useBrokerSessionsAsFallback == true (при false
//     SymbolInfoSessionTrade не вызывается),
//   - все шесть кастомных границ нулевые («пустая»
//     конфигурация на стороне EA).
//
// Алгоритм: сканирует MONDAY..FRIDAY через SymbolInfoSessionTrade,
// собирает первые две различные валидные пары (from, to) с
// from, to ∈ [0, 86399] и from != to. Первая пара →
// london{Start,End}Sec, вторая → ny{Start,End}Sec. Asian-границы не
// модифицируются (фоллбэк только для London/NY).
//
// Возвращает true ⇔ заполнены обе пары; в этом случае cfgInOut
// мутирован. False ⇔ либо предусловия не выполнены, либо брокер не
// вернул двух валидных пар. В случае «попытка была, но данные
// невалидны» (предусловия выполнены, пар не нашлось) — один warning
// `Print` и rollback (cfgInOut остаётся нетронутым — мутации
// происходят только после успешного сбора обеих пар).
bool SelectedSessions_TryBrokerFallback(SelectedSessionsConfig &cfgInOut)
  {
   if(!cfgInOut.useBrokerSessionsAsFallback)
      return false;
   if(cfgInOut.asianStartSec  != 0 || cfgInOut.asianEndSec  != 0 ||
      cfgInOut.londonStartSec != 0 || cfgInOut.londonEndSec != 0 ||
      cfgInOut.nyStartSec     != 0 || cfgInOut.nyEndSec     != 0)
      return false;

   long firstFrom  = -1, firstTo  = -1;
   long secondFrom = -1, secondTo = -1;

   for(int day = MONDAY; day <= FRIDAY; day++)
     {
      uint     sessionIdx = 0;
      datetime sessFrom   = 0;
      datetime sessTo     = 0;
      while(SymbolInfoSessionTrade(_Symbol,
                                   (ENUM_DAY_OF_WEEK)day,
                                   sessionIdx,
                                   sessFrom,
                                   sessTo))
        {
         const long from = (long)sessFrom;
         const long to   = (long)sessTo;
         if(SessionFilter_IsValidSecOfDay(from) &&
            SessionFilter_IsValidSecOfDay(to)   &&
            from != to)
           {
            if(firstFrom < 0)
              {
               firstFrom = from;
               firstTo   = to;
              }
            else if(secondFrom < 0 && (from != firstFrom || to != firstTo))
              {
               secondFrom = from;
               secondTo   = to;
              }
           }
         sessionIdx++;
         if(firstFrom >= 0 && secondFrom >= 0)
            break;
        }
      if(firstFrom >= 0 && secondFrom >= 0)
         break;
     }

   if(firstFrom < 0 || secondFrom < 0)
     {
      Print("⚠️ SelectedSessions broker fallback: ",
            "SymbolInfoSessionTrade did not return two valid sessions; ",
            "rolling back to cfg defaults");
      return false;
     }

   cfgInOut.londonStartSec = firstFrom;
   cfgInOut.londonEndSec   = firstTo;
   cfgInOut.nyStartSec     = secondFrom;
   cfgInOut.nyEndSec       = secondTo;
   return true;
  }

//--- SelectedSessions_ResetState ------------------------------------
//
// Полный сброс `SelectedSessionsState` к «cold»-нулю. Используется
// SelectedSessionsInit на пути «невалидный cfg» (no partial init; «выключенный» фильтр через нулевые поля).
// Никаких побочных эффектов, никаких обращений к платформенному API.
void SelectedSessions_ResetState(SelectedSessionsState &state)
  {
   state.effectiveGmtOffsetSec     = 0;
   state.wasInsideOnPreviousTick   = false;
   state.lastEvaluatedUtcSec       = 0;
   state.lastEffectiveGmtOffsetSec = 0;
   state.timeGmtFallbackLogged     = false;
  }

//+------------------------------------------------------------------+
//| SelectedSessionsInit — публичная инициализация фильтра.          |
//|                                                                  |
//| Алгоритм:                                                        |
//|                                                                  |
//| 1. Валидация cfg через `SelectedSessions_ValidateConfig`. При    |
//|    провале — один `Print(errorMessage)`, полный сброс `state`    |
//|    через `SelectedSessions_ResetState`, возврат `false`.         |
//|                                                                  |
//| 2. Опциональный broker fallback: если                            |
//|    `cfg.useBrokerSessionsAsFallback = true` — вызвать            |
//|    `SelectedSessions_TryBrokerFallback`, который сам проверяет   |
//|    «все шесть границ нулевые». При выключенном флаге             |
//|    fallback `SymbolInfoSessionTrade` не вызывается.              |
//|    Rollback на cfg + warning Print реализованы внутри            |
//|    TryBrokerFallback.                                            |
//|                                                                  |
//| 3. Вычислить `state.effectiveGmtOffsetSec` по `cfg.dstMode`:     |
//|    - `DST_AUTO`: rounded `TimeTradeServer() − TimeGMT()` через   |
//|      `SelectedSessions_RoundOffsetToQuarterHour`.                |
//|      Если `TimeGMT() == 0` — fallback на `cfg.gmtOffsetSeconds`  |
//|      без логирования; первое `SelectedSessionsIsInside`         |
//|       отвечает за warning Print + установку                      |
//|      `state.timeGmtFallbackLogged`.                              |
//|    - `DST_MANUAL`: `state.effectiveGmtOffsetSec :=               |
//|      cfg.gmtOffsetSeconds`.                                      |
//|                                                                  |
//| 4. Записать `state.lastEffectiveGmtOffsetSec :=                  |
//|    state.effectiveGmtOffsetSec` (baseline DST-change-detect для  |
//|    `SelectedSessionsIsInside`) и                                 |
//|    `state.timeGmtFallbackLogged := false` (анти-спам флаг        |
//|    стартовый).                                                   |
//|                                                                  |
//| 5. Cold-start sync `state.wasInsideOnPreviousTick`: inline       |
//|    воспроизводим семантику `SelectedSessionsIsInside` на         |
//|    «нулевом тике». При `cfg.enabled = false` —                   |
//|    `wasInsideOnPreviousTick := false`. Иначе                     |
//|    `utcNowSec := SelectedSessions_ComputeUtcNowSec(offset)`,     |
//|    membership через `SelectedSessions_IsInOneSession` по каждой  |
//|    флагованной сессии, OR-объединение.                           |
//|    Полная функция `SelectedSessionsIsInside` (с DST-change       |
//|    логом и TimeGMT==0 fallback warning) реализована ниже;        |
//|    логирующие пути там отрабатывают на первом реальном тике.     |
//|                                                                  |
//| 6. Записать `state.lastEvaluatedUtcSec := utcNowSec`.            |
//|                                                                  |
//| Идемпотентность: два последовательных                            |
//| вызова с одним и тем же `cfg` при фиксированных                  |
//| `TimeTradeServer()` / `TimeGMT()` дают идентичный `state` поле   |
//| в поле. На втором вызове broker-fallback пропускается (его       |
//| внутренняя проверка «все границы нулевые» уже false), все        |
//| остальные операции детерминированы в (`cfg`, `TimeTradeServer`,  |
//| `TimeGMT`).                                                      |
//|                                                                  |
//| Сигнатура: `cfg` принимается по неконстантной ссылке, потому     |
//| что `SelectedSessions_TryBrokerFallback` мутирует поля           |
//| `londonStart/EndSec` и `nyStart/EndSec`. Это                     |
//| осознанное отклонение от `const &`,                              |
//| продиктованное согласованностью с TryBrokerFallback — иначе      |
//| мутации фоллбэка не доживают до первого `IsInside` и фоллбэк     |
//| не работает. `SelectedSessionsIsInside` / `DetectExit` /         |
//| `GetEffective` остаются `const &` по cfg.                        |
//|                                                                  |
//| Запрещённые вызовы: функция не обращается                        |
//| к `trade.*`, `PositionGet*`, `OrderGet*`, `PositionSelect`,      |
//| `OrderSelect`, `HistorySelect`, `ExpertRemove`.                  |
//+------------------------------------------------------------------+
bool SelectedSessionsInit(SelectedSessionsConfig &cfg,
                          SelectedSessionsState  &state)
  {
   // 1. Validate cfg.
   string errorMessage;
   if(!SelectedSessions_ValidateConfig(cfg, errorMessage))
     {
      Print(errorMessage);
      SelectedSessions_ResetState(state);
      return false;
     }

   // 2. Optional broker fallback for London/NY borders. TryBrokerFallback
   //    проверяет precondition «useBrokerSessionsAsFallback=true И все
   //    шесть границ нулевые» внутри, поэтому здесь достаточно тонкого
   //    guard'а по флагу — чтобы при выключенном fallback не вызывать
   //    SymbolInfoSessionTrade ни разу.
   if(cfg.useBrokerSessionsAsFallback)
      SelectedSessions_TryBrokerFallback(cfg);

   // 3. Compute effectiveGmtOffsetSec by dstMode.
   if(cfg.dstMode == DST_AUTO)
     {
      const long rawGmt = (long)TimeGMT();
      if(rawGmt == 0)
        {
         // TimeGMT()==0 → invalid system time. Safe fallback to manual
         // offset; warning will be emitted by the first IsInside tick.
         // state.timeGmtFallbackLogged остаётся false ниже,
         // в шаге 4, чтобы IsInside мог однократно залогировать.
         state.effectiveGmtOffsetSec = cfg.gmtOffsetSeconds;
        }
      else
        {
         const long rawOffset = (long)TimeTradeServer() - rawGmt;
         state.effectiveGmtOffsetSec =
            SelectedSessions_RoundOffsetToQuarterHour(rawOffset);
        }
     }
   else  // DST_MANUAL
     {
      state.effectiveGmtOffsetSec = cfg.gmtOffsetSeconds;
     }

   // 4. Baseline state fields for IsInside:
   //    - lastEffectiveGmtOffsetSec  — DST-change-detect baseline.
   //    - timeGmtFallbackLogged      — anti-spam flag, стартовое false.
   state.lastEffectiveGmtOffsetSec = state.effectiveGmtOffsetSec;
   state.timeGmtFallbackLogged     = false;

   // 5. Cold-start sync of wasInsideOnPreviousTick.
   //    Inline IsInside semantics: validate enabled, compute utcNowSec,
   //    evaluate union membership over flagged sessions.
   const long utcNowSec =
      SelectedSessions_ComputeUtcNowSec(state.effectiveGmtOffsetSec);

   if(!cfg.enabled)
     {
      state.wasInsideOnPreviousTick = false;
     }
   else
     {
      const bool inAsian  = cfg.useAsian &&
                            SelectedSessions_IsInOneSession(utcNowSec,
                                                            cfg.asianStartSec,
                                                            cfg.asianEndSec);
      const bool inLondon = cfg.useLondon &&
                            SelectedSessions_IsInOneSession(utcNowSec,
                                                            cfg.londonStartSec,
                                                            cfg.londonEndSec);
      const bool inNY     = cfg.useNewYork &&
                            SelectedSessions_IsInOneSession(utcNowSec,
                                                            cfg.nyStartSec,
                                                            cfg.nyEndSec);
      state.wasInsideOnPreviousTick = (inAsian || inLondon || inNY);
     }

   // 6. Record lastEvaluatedUtcSec for diagnostics.
   state.lastEvaluatedUtcSec = utcNowSec;

   return true;
  }

//+------------------------------------------------------------------+
//| SelectedSessionsIsInside — публичная проверка принадлежности     |
//|                              UTC_Now к Selected_Union_Interval.  |
//|                                                                  |
//| Алгоритм:                                                        |
//|                                                                  |
//| 1. Switch-off guard: при `cfg.enabled = false` возврат `false`   |
//|    без побочных эффектов на `state`.                             |
//|                                                                  |
//| 2. Пересчёт `state.effectiveGmtOffsetSec` по `cfg.dstMode`:      |
//|    - `DST_AUTO`:                                                 |
//|        a) если `TimeGMT() == 0` (невалидное системное время) —  |
//|           `state.effectiveGmtOffsetSec := cfg.gmtOffsetSeconds`; |
//|           при `state.timeGmtFallbackLogged = false` — один       |
//|           warning `Print` и `state.timeGmtFallbackLogged :=      |
//|           true` (anti-spam).                                     |
//|        b) иначе `state.effectiveGmtOffsetSec :=                  |
//|           SelectedSessions_RoundOffsetToQuarterHour              |
//|           (TimeTradeServer() − TimeGMT())`.                      |
//|        c) DST change detection: если                             |
//|           |state.effectiveGmtOffsetSec −                         |
//|             state.lastEffectiveGmtOffsetSec|                     |
//|           ≥ `SELECTED_SESSIONS_DST_LOG_DELTA` — один `Print` с   |
//|           old/new offset и `state.lastEffectiveGmtOffsetSec :=   |
//|           state.effectiveGmtOffsetSec`. Обновление               |
//|           «last logged» (а не «last seen») гарантирует           |
//|           идемпотентность повторного вызова при том же времени.  |
//|    - `DST_MANUAL`: `state.effectiveGmtOffsetSec` не              |
//|       модифицируется и остаётся равным `cfg.gmtOffsetSeconds`,   |
//|       зафиксированному `SelectedSessionsInit`.                   |
//|                                                                  |
//| 3. Вычислить `utcNowSec` через                                   |
//|    `SelectedSessions_ComputeUtcNowSec(state.effectiveGmtOffsetSec)`
//| и записать в `state.lastEvaluatedUtcSec`.                        |
//|                                                                  |
//| 4. Вычислить членство по каждой флагованной сессии через         |
//|    `SelectedSessions_IsInOneSession` и вернуть OR-объединение.   |
//|    При всех `use*=false` результат —                             |
//|    `false` (edge: пустой union).                                 |
//|                                                                  |
//| Запрещённые вызовы: функция не обращается                        |
//| к `trade.*`, `PositionGet*`, `OrderGet*`, `PositionSelect`,      |
//| `OrderSelect`, `HistorySelect`, `SymbolInfo*`, `TimeCurrent()`   |
//| (`TimeCurrent` — legacy-only). Платформенные вызовы              |
//| ограничены `TimeTradeServer()` и `TimeGMT()`, разрешёнными       |
//|                                                                  |
//| Сигнатура: `cfg` — `const &` (модуль не модифицирует             |
//| конфигурацию здесь; broker-fallback мутации происходят только в  |
//| `SelectedSessionsInit`); `state` — мутабельная ссылка, потому    |
//| что DST-пересчёт и кэширование `utcNowSec` / `lastEvaluated*`    |
//| обновляют поля state на каждом тике.                             |
//+------------------------------------------------------------------+
bool SelectedSessionsIsInside(const SelectedSessionsConfig &cfg,
                              SelectedSessionsState        &state)
  {
   // 1. Switch-off guard: no side effects.
   if(!cfg.enabled)
      return false;

   // 2. Recompute effectiveGmtOffsetSec by dstMode.
   if(cfg.dstMode == DST_AUTO)
     {
      const long rawGmt = (long)TimeGMT();
      if(rawGmt == 0)
        {
         // TimeGMT()==0 → invalid system time. Safe fallback to
         // manual offset; one warning Print per advisor lifetime
         // (anti-spam via state.timeGmtFallbackLogged).
         state.effectiveGmtOffsetSec = cfg.gmtOffsetSeconds;
         if(!state.timeGmtFallbackLogged)
           {
            Print("⚠️ SelectedSessions DST_AUTO: TimeGMT() returned 0; ",
                  "falling back to manual gmtOffsetSeconds=",
                  IntegerToString(cfg.gmtOffsetSeconds), "s");
            state.timeGmtFallbackLogged = true;
           }
        }
      else
        {
         // rounded TimeTradeServer() − TimeGMT() to 15 min.
         const long rawOffset = (long)TimeTradeServer() - rawGmt;
         state.effectiveGmtOffsetSec =
            SelectedSessions_RoundOffsetToQuarterHour(rawOffset);
        }

      // DST change detection. Compare against last *logged*
      // baseline (lastEffectiveGmtOffsetSec); update only on logging
      // event so repeated calls at the same time are idempotent.
      long delta = state.effectiveGmtOffsetSec
                   - state.lastEffectiveGmtOffsetSec;
      if(delta < 0)
         delta = -delta;
      if(delta >= SELECTED_SESSIONS_DST_LOG_DELTA)
        {
         Print("ℹ️ SelectedSessions DST_AUTO offset change: old=",
               IntegerToString(state.lastEffectiveGmtOffsetSec),
               "s new=",
               IntegerToString(state.effectiveGmtOffsetSec), "s");
         state.lastEffectiveGmtOffsetSec = state.effectiveGmtOffsetSec;
        }
     }
   // DST_MANUAL: state.effectiveGmtOffsetSec остаётся равным
   // cfg.gmtOffsetSeconds. Init его уже зафиксировал —
   // здесь намеренно не модифицируем.

   // 3. UTC_Now + cache for diagnostics.
   const long utcNowSec =
      SelectedSessions_ComputeUtcNowSec(state.effectiveGmtOffsetSec);
   state.lastEvaluatedUtcSec = utcNowSec;

   // 4. Union membership over flagged sessions.
   const bool inAsian  = cfg.useAsian &&
                         SelectedSessions_IsInOneSession(utcNowSec,
                                                         cfg.asianStartSec,
                                                         cfg.asianEndSec);
   const bool inLondon = cfg.useLondon &&
                         SelectedSessions_IsInOneSession(utcNowSec,
                                                         cfg.londonStartSec,
                                                         cfg.londonEndSec);
   const bool inNY     = cfg.useNewYork &&
                         SelectedSessions_IsInOneSession(utcNowSec,
                                                         cfg.nyStartSec,
                                                         cfg.nyEndSec);
   return (inAsian || inLondon || inNY);
  }

//+------------------------------------------------------------------+
//| SelectedSessionsDetectExit — edge-trigger детекции Session_Exit_ |
//|                                Event (inside → outside).         |
//|                                                                  |
//| Алгоритм:                                                        |
//|                                                                  |
//| 1. Сохранить `wasInside := state.wasInsideOnPreviousTick`        |
//|    (snapshot до пересчёта; нужен в шаге 4 для оригинального      |
//|    значения «был ли inside на предыдущем тике»).                 |
//|                                                                  |
//| 2. `isInsideNow := SelectedSessionsIsInside(cfg, state)` —       |
//|    делегируем вычисление членства публичной функции, что         |
//|    обеспечивает идентичные DST/UTC семантики и побочные эффекты  |
//|    обновления `state.effectiveGmtOffsetSec` /                    |
//|    `state.lastEvaluatedUtcSec`.                                  |
//|    `SelectedSessionsIsInside` НЕ модифицирует                    |
//|    `state.wasInsideOnPreviousTick`, поэтому порядок snapshot →   |
//|    IsInside корректен.                                           |
//|                                                                  |
//| 3. Обновить `state.wasInsideOnPreviousTick := isInsideNow`.      |
//|    Это превращает функцию в edge-trigger: повторный              |
//|    вызов после `true` без возврата в inside даст `false`,        |
//|    потому что `wasInside` на следующем вызове станет `false`     |
//|    (антиспам закрытия позиций).                                  |
//|                                                                  |
//| 4. Вернуть `wasInside AND NOT isInsideNow` — true тогда и        |
//|    только тогда, когда на предыдущем оценённом тике состояние    |
//|    было `inside`, а на текущем стало `outside`                   |
//|    (Session_Exit_Event).                                         |
//|                                                                  |
//| Запрещённые вызовы: функция не обращается к                      |
//| `trade.*`, `PositionGet*`, `OrderGet*`, `PositionSelect`,        |
//| `OrderSelect`, `HistorySelect`, `SymbolInfo*`. Платформенные     |
//| обращения к `TimeTradeServer()` / `TimeGMT()` выполняются        |
//| транзитивно через `SelectedSessionsIsInside` и разрешены         |
//|                                                                  |
//| Сигнатура: `cfg` — `const &` (модуль не модифицирует             |
//| конфигурацию); `state` — мутабельная ссылка, потому что          |
//| функция обновляет `wasInsideOnPreviousTick` (шаг 3) и через      |
//| вложенный вызов `SelectedSessionsIsInside` — поля,               |
//| относящиеся к DST/UTC кэшу.                                      |
//+------------------------------------------------------------------+
bool SelectedSessionsDetectExit(const SelectedSessionsConfig &cfg,
                                SelectedSessionsState        &state)
  {
   // 1. Snapshot inside-flag with previous-tick semantics.
   const bool wasInside = state.wasInsideOnPreviousTick;

   // 2. Recompute current inside-membership; delegates DST/UTC update
   //    side-effects to the canonical implementation.
   const bool isInsideNow = SelectedSessionsIsInside(cfg, state);

   // 3. Advance edge-trigger state for the next tick.
   state.wasInsideOnPreviousTick = isInsideNow;

   // 4. Edge: previous=inside AND current=outside ⇒ Session_Exit_Event.
   return (wasInside && !isInsideNow);
  }

//+------------------------------------------------------------------+
//| SelectedSessionsGetEffective — диагностический accessor.         |
//|                                                                  |
//| Алгоритм:                                                        |
//|                                                                  |
//| Копирует шесть эффективных секунд суток UTC                      |
//| (`cfg.asianStartSec`, `cfg.asianEndSec`, `cfg.londonStartSec`,   |
//| `cfg.londonEndSec`, `cfg.nyStartSec`, `cfg.nyEndSec`) в          |
//| соответствующие out-параметры. Не модифицирует ни `cfg`, ни      |
//| `state` (обе ссылки — `const &`).                                |
//|                                                                  |
//| Источник истины — поля `cfg`: после `SelectedSessionsInit`       |
//| (включая возможный broker-fallback) они хранят актуальные        |
//| границы. `state` принимается `const &` для симметрии с дизайном  |
//| и возможного будущего расширения (диагностика effective offset / |
//| lastEvaluatedUtcSec), сейчас фактически не читается.             |
//|                                                                  |
//| Запрещённые вызовы: нет обращений к                              |
//| `trade.*`, `PositionGet*`, `OrderGet*`, `PositionSelect`,        |
//| `OrderSelect`, `HistorySelect`, `SymbolInfo*`, `TimeTradeServer`,|
//| `TimeGMT`, `TimeCurrent`. Чистая копия.                          |
//+------------------------------------------------------------------+
void SelectedSessionsGetEffective(const SelectedSessionsConfig &cfg,
                                  const SelectedSessionsState  &state,
                                  long &asianStart,  long &asianEnd,
                                  long &londonStart, long &londonEnd,
                                  long &nyStart,     long &nyEnd)
  {
   asianStart  = cfg.asianStartSec;
   asianEnd    = cfg.asianEndSec;
   londonStart = cfg.londonStartSec;
   londonEnd   = cfg.londonEndSec;
   nyStart     = cfg.nyStartSec;
   nyEnd       = cfg.nyEndSec;
  }

#endif // SESSIONFILTER_MQH
//+------------------------------------------------------------------+
