//+------------------------------------------------------------------+
//|                                             MultiTfScheduler.mqh |
//|                                                                  |
//|  MultiTF Scheduler — управление фиксированным набором десяти     |
//|  таймфреймов: упорядоченный итератор по активным ТФ, конверсия   |
//|  ENUM_TIMEFRAMES → короткое имя, двухслойный антидубль по бару   |
//|  (in-memory + GlobalVariable).                                   |
//|                                                                  |
//|  This header declares:                                           |
//|   - константу MULTITF_SCHEDULER_MAX_TF и массив                  |
//|     MultiTfScheduler_AllTF в фиксированном порядке               |
//|     M1, M5, M15, M30, H1, H4, H8, D1, W1, MN1                    |
//|   - MultiTfSchedulerConfig — десять bool-флагов use<TF>          |
//|   - MultiTfSchedulerState — активный набор + lastCheckedBar      |
//|   - прототипы публичных функций модуля:                          |
//|       MultiTfSchedulerInit                                       |
//|       MultiTfSchedulerActiveCount                                |
//|       MultiTfSchedulerActiveAt                                   |
//|       MultiTfSchedulerTFEnum                                     |
//|       MultiTfSchedulerTFToString                                 |
//|       MultiTfSchedulerIsNewBar                                   |
//|       MultiTfSchedulerLoadLastSignalBar                          |
//|       MultiTfSchedulerSaveLastSignalBar                          |
//|   - прототип приватного хелпера с префиксом MultiTfScheduler_*:  |
//|       MultiTfScheduler_GVarName                                  |
//|                                                                  |
//|  Модуль соответствует требованиям модульной изоляции:            |
//|  include-guard уникален,                                         |
//|  конфигурация и состояние передаются только через struct-        |
//|  аргументы по ссылке, `input`-объявления в этом файле            |
//|  отсутствуют. Глобальное состояние модуля ограничено             |
//|  массивом-константой MultiTfScheduler_AllTF; всё                 |
//|  изменяемое состояние держит вызывающая сторона в                |
//|  MultiTfSchedulerState.                                          |
//|                                                                  |
//|  Стиль файла мирорит TrendFilter.mqh и CrtDetector.mqh.          |
//+------------------------------------------------------------------+
#ifndef MULTITFSCHEDULER_MQH
#define MULTITFSCHEDULER_MQH

//+------------------------------------------------------------------+
//| Константы модуля.                                                |
//|                                                                  |
//|  MULTITF_SCHEDULER_MAX_TF — фиксированное количество             |
//|  поддерживаемых таймфреймов. Менять нельзя: размерность          |
//|  привязана к набору input-флагов в crt-push и к                  |
//|  внутренним массивам MultiTfSchedulerState.                      |
//+------------------------------------------------------------------+
#define MULTITF_SCHEDULER_MAX_TF 10

//+------------------------------------------------------------------+
//| MultiTfScheduler_AllTF — module-private массив ТФ в строго       |
//| фиксированном порядке.                                           |
//|                                                                  |
//|  Порядок соответствует порядку input-флагов Use_<TF> в           |
//|  crt-push: M1, M5, M15, M30, H1, H4, H8, D1, W1, MN1.            |
//|  Менять порядок нельзя — это сломает схему ключа                 |
//|  GlobalVariable для антидубля,                                   |
//|  потому что MultiTfScheduler_GVarName использует индекс tfIdx    |
//|  как ключ в этот массив.                                         |
//|                                                                  |
//|  Массив инициализируется при загрузке модуля и не модифицируется |
//|  никакой из функций модуля (концептуально const — но MQL5 не     |
//|  поддерживает модификатор const для массивов в namespace-scope). |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES MultiTfScheduler_AllTF[MULTITF_SCHEDULER_MAX_TF] =
  {
   PERIOD_M1,  PERIOD_M5,  PERIOD_M15, PERIOD_M30,
   PERIOD_H1,  PERIOD_H4,  PERIOD_H8,
   PERIOD_D1,  PERIOD_W1,  PERIOD_MN1
  };

//+------------------------------------------------------------------+
//| MultiTfSchedulerConfig — иммутабельная конфигурация активного    |
//| набора таймфреймов.                                              |
//|                                                                  |
//|  Ровно десять полей типа bool — по одному на каждый ТФ в         |
//|  MultiTfScheduler_AllTF, в том же порядке. Поле useX == true     |
//|  означает «ТФ X активен».                                        |
//|                                                                  |
//|  Передаётся в MultiTfSchedulerInit через const & — модуль НЕ     |
//|  модифицирует поля config. Имена полей повторяют                 |
//|  имена input-флагов в crt-push (`Use_M1`, `Use_H1`, ...),        |
//|  но без префикса `Use_`: модуль не зависит от EA-специфичных     |
//|  имён, а оркестратор отвечает за маппинг `Use_X → useX` при      |
//|  построении config.                                              |
//+------------------------------------------------------------------+
struct MultiTfSchedulerConfig
  {
   bool useM1;
   bool useM5;
   bool useM15;
   bool useM30;
   bool useH1;
   bool useH4;
   bool useH8;
   bool useD1;
   bool useW1;
   bool useMN1;
  };

//+------------------------------------------------------------------+
//| MultiTfSchedulerState — мутабельное состояние планировщика.      |
//|                                                                  |
//|  activeCount       — число активных ТФ ∈ [0, MAX_TF].            |
//|                       0 ⇔ MultiTfSchedulerInit отказал (все      |
//|                       флаги config были false).                  |
//|                                                                  |
//|  activeIndices[]   — упорядоченный список индексов в массиве     |
//|                       MultiTfScheduler_AllTF, для которых        |
//|                       соответствующий флаг config был true.      |
//|                       Валидные позиции —                         |
//|                       [0, activeCount); остальные элементы       |
//|                       массива не определены (вызывающая сторона  |
//|                       обязана итерировать только до              |
//|                       activeCount).                              |
//|                       Порядок строго возрастающий относительно   |
//|                       MultiTfScheduler_AllTF.                    |
//|                                                                  |
//|  lastCheckedBar[]  — in-memory антидубль по бару.                |
//|                       Индексируется значением tfIdx (т.е.        |
//|                       индексом в MultiTfScheduler_AllTF, а НЕ    |
//|                       порядковым номером ordinal в               |
//|                       activeIndices). Это позволяет вызывающей   |
//|                       стороне индексировать lastCheckedBar       |
//|                       тем же tfIdx, что и AllTF, без             |
//|                       дополнительной трансляции.                 |
//|                       Все элементы инициализируются в 0 при      |
//|                       успешном MultiTfSchedulerInit.             |
//|                                                                  |
//|  Структура передаётся в публичные функции по reference; некоторые|
//|  функции принимают её как const & (read-only итерация и          |
//|  GlobalVariable round-trip), некоторые — как mutable &           |
//|  (Init и IsNewBar обновляют поля). Конкретные const-/mutable-    |
//|  контракты зафиксированы в прототипах ниже.                      |
//+------------------------------------------------------------------+
struct MultiTfSchedulerState
  {
   int      activeCount;                                  // [0, MAX_TF]; 0 ⇔ Init failed
   int      activeIndices[MULTITF_SCHEDULER_MAX_TF];      // упорядоченный набор tfIdx
   datetime lastCheckedBar[MULTITF_SCHEDULER_MAX_TF];     // in-memory antidup, индекс = tfIdx
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс MultiTfScheduler.                            |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MultiTfSchedulerInit — построить активный набор ТФ из config.    |
//|                                                                  |
//|  Сигнатура: принимает иммутабельную конфигурацию                 |
//|  через const & и мутабельное состояние через &.                  |
//|                                                                  |
//|  Контракт реализации:                                            |
//|                                                                  |
//|   1. Прочитать десять флагов из config.                          |
//|   2. Если все флаги false — вернуть false и оставить             |
//|      state.activeCount = 0. Атомарность                          |
//|      инициализации: state не должен оказаться в                  |
//|      полу-инициализированном виде.                               |
//|   3. Иначе заполнить state.activeIndices[0..activeCount-1]       |
//|      упорядоченным списком индексов в MultiTfScheduler_AllTF,    |
//|      для которых соответствующий флаг включён.                   |
//|      Порядок — строго возрастающий относительно AllTF: сначала   |
//|      M1, затем M5, ..., MN1.                                     |
//|   4. Обнулить state.lastCheckedBar[tfIdx] для всех tfIdx ∈       |
//|      [0, MAX_TF) — это инициализация in-memory антидубля.        |
//|   5. Вернуть true.                                               |
//|                                                                  |
//|  Возвращаемое значение — true при успешной инициализации с       |
//|  непустым активным набором; false при пустом активном наборе.    |
//|  Оркестратор обязан различать эти два случая и                   |
//|  возвращать INIT_FAILED при false.                               |
//+------------------------------------------------------------------+
bool MultiTfSchedulerInit(const MultiTfSchedulerConfig &config,
                          MultiTfSchedulerState        &state);

//+------------------------------------------------------------------+
//| MultiTfSchedulerActiveCount — число активных ТФ.                 |
//|                                                                  |
//|  Возвращает state.activeCount без модификации state.             |
//|  Используется как верхняя граница цикла итерации:                |
//|                                                                  |
//|    for(int i = 0; i < MultiTfSchedulerActiveCount(state); i++)   |
//|      { int tfIdx = MultiTfSchedulerActiveAt(state, i); ... }     |
//|                                                                  |
//|  При state, полученном из неудачного Init (false возврат),       |
//|  возвращает 0 — цикл итерации в OnTick корректно не              |
//|  выполняется ни разу.                                            |
//+------------------------------------------------------------------+
int MultiTfSchedulerActiveCount(const MultiTfSchedulerState &state);

//+------------------------------------------------------------------+
//| MultiTfSchedulerActiveAt — получить tfIdx по порядковому номеру  |
//| активного ТФ.                                                    |
//|                                                                  |
//|  activeOrdinal ∈ [0, ActiveCount(state)) — порядковый номер в    |
//|  активном наборе (НЕ индекс в MultiTfScheduler_AllTF).           |
//|  Возвращает state.activeIndices[activeOrdinal], т.е. индекс в    |
//|  MultiTfScheduler_AllTF.                                         |
//|                                                                  |
//|  Поведение при activeOrdinal вне диапазона [0, ActiveCount):     |
//|  не специфицировано контрактом — вызывающая сторона обязана      |
//|  итерировать только до ActiveCount(state). Реализация может      |
//|  вернуть значение по умолчанию для безопасности, но              |
//|  семантика «out-of-range → undefined» зафиксирована здесь как    |
//|  контракт.                                                       |
//|                                                                  |
//|  Не модифицирует state (const &).                                |
//+------------------------------------------------------------------+
int MultiTfSchedulerActiveAt(const MultiTfSchedulerState &state,
                             const int                    activeOrdinal);

//+------------------------------------------------------------------+
//| MultiTfSchedulerTFEnum — преобразовать tfIdx в ENUM_TIMEFRAMES.  |
//|                                                                  |
//|  Возвращает MultiTfScheduler_AllTF[tfIdx]. Используется          |
//|  вызывающей стороной для подстановки результата                  |
//|  ActiveAt(state, ordinal) в API MT5, требующее ENUM_TIMEFRAMES   |
//|  (CopyRates, iMA, ...).                                          |
//|                                                                  |
//|  tfIdx ∈ [0, MULTITF_SCHEDULER_MAX_TF). Поведение за пределами   |
//|  диапазона не специфицировано контрактом (см. контракт           |
//|  ActiveAt выше).                                                 |
//|                                                                  |
//|  Не имеет параметров-state — это чистая функция от индекса в     |
//|  модульный массив-константу.                                     |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES MultiTfSchedulerTFEnum(const int tfIdx);

//+------------------------------------------------------------------+
//| MultiTfSchedulerTFToString — человеко-читаемое короткое имя ТФ.  |
//|                                                                  |
//|  Контракт:                                                       |
//|    PERIOD_M1  → "M1"                                             |
//|    PERIOD_M5  → "M5"                                             |
//|    PERIOD_M15 → "M15"                                            |
//|    PERIOD_M30 → "M30"                                            |
//|    PERIOD_H1  → "H1"                                             |
//|    PERIOD_H4  → "H4"                                             |
//|    PERIOD_H8  → "H8"                                             |
//|    PERIOD_D1  → "D1"                                             |
//|    PERIOD_W1  → "W1"                                             |
//|    PERIOD_MN1 → "MN"                                             |
//|    default    → EnumToString(tf)  (fallback)                     |
//|                                                                  |
//|  Формат используется в текстах push-уведомлений — менять         |
//|  его без необходимости не стоит.                                 |
//|                                                                  |
//|  Чистая функция от значения tf; не зависит от state.             |
//+------------------------------------------------------------------+
string MultiTfSchedulerTFToString(const ENUM_TIMEFRAMES tf);

//+------------------------------------------------------------------+
//| MultiTfSchedulerIsNewBar — антидубль по бару (in-memory).        |
//|                                                                  |
//|  Контракт:                                                       |
//|    - Возвращает true ⇔ barTime != state.lastCheckedBar[tfIdx].   |
//|    - При возврате true SHALL обновить state.lastCheckedBar[tfIdx]|
//|      значением barTime до возврата управления.                   |
//|    - При возврате false state НЕ модифицируется.                 |
//|                                                                  |
//|  Семантика: «есть ли новый бар, который мы ещё не обработали     |
//|  на этом tfIdx в течение текущей сессии советника?». В отличие   |
//|  от MultiTfSchedulerLoadLastSignalBar/Save, эта функция работает |
//|  с in-memory копией и сбрасывается при перезапуске EA — поэтому  |
//|  оркестратор использует две проверки последовательно: сначала    |
//|  IsNewBar (защита от лишних CrtDetectorDetect в той же сессии),  |
//|  затем Load/Save (защита от повторной отправки после             |
//|  перезапуска).                                                   |
//|                                                                  |
//|  Параметр state объявлен как mutable & (без const), потому что   |
//|  функция модифицирует state.lastCheckedBar[tfIdx] при первом     |
//|  вызове на новом баре.                                           |
//|                                                                  |
//|  tfIdx ∈ [0, MULTITF_SCHEDULER_MAX_TF). Поведение за пределами   |
//|  диапазона не специфицировано.                                   |
//+------------------------------------------------------------------+
bool MultiTfSchedulerIsNewBar(MultiTfSchedulerState &state,
                              const int             tfIdx,
                              const datetime        barTime);

//+------------------------------------------------------------------+
//| MultiTfSchedulerLoadLastSignalBar — чтение last-signal bar через |
//| GlobalVariable.                                                  |
//|                                                                  |
//|  Контракт:                                                       |
//|    - Формирует имя GlobalVariable через                          |
//|      MultiTfScheduler_GVarName(tfIdx).                           |
//|    - Если GlobalVariableCheck(name) == false — возвращает 0      |
//|      (sentinel «не было ни одной отправки»).                     |
//|    - Иначе возвращает (datetime)GlobalVariableGet(name).         |
//|                                                                  |
//|  Это «персистентный» слой антидубля: переживает перезапуск       |
//|  советника и терминала, в отличие от in-memory                   |
//|  state.lastCheckedBar. Используется оркестратором сразу после    |
//|  IsNewBar.                                                       |
//|                                                                  |
//|  state передаётся как const & — функция не модифицирует          |
//|  state, обращение идёт исключительно к GlobalVariable.           |
//|  Параметр state в сигнатуре зарезервирован для будущих           |
//|  расширений и для симметрии с Save.                              |
//|                                                                  |
//|  tfIdx ∈ [0, MULTITF_SCHEDULER_MAX_TF).                          |
//+------------------------------------------------------------------+
datetime MultiTfSchedulerLoadLastSignalBar(const MultiTfSchedulerState &state,
                                           const int                    tfIdx);

//+------------------------------------------------------------------+
//| MultiTfSchedulerSaveLastSignalBar — запись last-signal bar в     |
//| GlobalVariable.                                                  |
//|                                                                  |
//|  Контракт:                                                       |
//|    - Формирует имя GlobalVariable через                          |
//|      MultiTfScheduler_GVarName(tfIdx).                           |
//|    - Вызывает GlobalVariableSet(name, (double)barTime).          |
//|                                                                  |
//|  Используется оркестратором после успешной отправки push-        |
//|  уведомления, чтобы избежать повторной отправки на               |
//|  том же баре после перезапуска советника.                        |
//|                                                                  |
//|  state передаётся как const & — функция не модифицирует state    |
//|  (вся модификация состояния идёт через GlobalVariable). Параметр |
//|  state в сигнатуре зарезервирован для будущих расширений и для   |
//|  симметрии с Load.                                               |
//|                                                                  |
//|  tfIdx ∈ [0, MULTITF_SCHEDULER_MAX_TF).                          |
//+------------------------------------------------------------------+
void MultiTfSchedulerSaveLastSignalBar(const MultiTfSchedulerState &state,
                                       const int                    tfIdx,
                                       const datetime               barTime);

//+------------------------------------------------------------------+
//| Приватные хелперы модуля (префикс MultiTfScheduler_*).           |
//|                                                                  |
//|  Не входят в публичный API; используются только телами публичных |
//|  функций. Префикс предотвращает коллизии с одноимёнными          |
//|  утилитами в EA-файлах и фиксирует «module-private» семантику в  |
//|  имени.                                                          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MultiTfScheduler_GVarName — формирование имени GlobalVariable    |
//| для антидубля по бару.                                           |
//|                                                                  |
//|  Контракт:                                                       |
//|                                                                  |
//|    return StringFormat("RBCRT_%s_%s_lastBar",                    |
//|                        _Symbol,                                  |
//|                        EnumToString(MultiTfScheduler_AllTF[tfIdx])); |
//|                                                                  |
//|  Менять нельзя — изменение схемы ключа обнулит историю           |
//|  антидубля для уже работающих установок crt-push.                |
//|                                                                  |
//|  Замечание: используется именно EnumToString(tf) (т.е.           |
//|  "PERIOD_H1"), а не короткое имя из MultiTfSchedulerTFToString   |
//|  ("H1"). Это намеренно — историческая схема ключа использует     |
//|  полное имя enum.                                                |
//|                                                                  |
//|  tfIdx ∈ [0, MULTITF_SCHEDULER_MAX_TF). Поведение за пределами   |
//|  диапазона не специфицировано.                                   |
//+------------------------------------------------------------------+
string MultiTfScheduler_GVarName(const int tfIdx);

//+------------------------------------------------------------------+
//| Implementations                                                  |
//|                                                                  |
//|  Реализация выполняется в том же .mqh-файле, в соответствии со   |
//|  стилем существующих модулей Include/* (см.                      |
//|  TrendFilter.mqh и CrtDetector.mqh как канонические примеры).    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MultiTfSchedulerInit (см. контракт в прототипе выше).            |
//|                                                                  |
//|  -                                                               |
//|     читает десять флагов use<TF> из config в порядке             |
//|      MultiTfScheduler_AllTF;                                     |
//|    - при всех флагах false возвращает false и оставляет          |
//|      state.activeCount = 0;                                      |
//|    - иначе заполняет state.activeIndices упорядоченным           |
//|      списком tfIdx, обнуляет state.lastCheckedBar                |
//|      на всём диапазоне [0, MAX_TF) и возвращает true.            |
//+------------------------------------------------------------------+
bool MultiTfSchedulerInit(const MultiTfSchedulerConfig &config,
                          MultiTfSchedulerState        &state)
  {
   // Локальный буфер флагов в порядке MultiTfScheduler_AllTF
   // (M1, M5, M15, M30, H1, H4, H8, D1, W1, MN1).
   bool flags[MULTITF_SCHEDULER_MAX_TF];
   flags[0] = config.useM1;
   flags[1] = config.useM5;
   flags[2] = config.useM15;
   flags[3] = config.useM30;
   flags[4] = config.useH1;
   flags[5] = config.useH4;
   flags[6] = config.useH8;
   flags[7] = config.useD1;
   flags[8] = config.useW1;
   flags[9] = config.useMN1;

   // Сначала проверяем «все флаги false» — это путь отказа.
   // Атомарность инициализации: на этом пути state остаётся пустым
   // (activeCount = 0) и не оказывается в полу-инициализированном виде.
   bool anyActive = false;
   for(int i = 0; i < MULTITF_SCHEDULER_MAX_TF; i++)
     {
      if(flags[i])
        {
         anyActive = true;
         break;
        }
     }

   if(!anyActive)
     {
      state.activeCount = 0;
      // Defensive: обнулим вспомогательные массивы, чтобы вызывающая
      // сторона никогда не видела «мусор» в state даже при отказе.
      for(int i = 0; i < MULTITF_SCHEDULER_MAX_TF; i++)
        {
         state.activeIndices[i]  = 0;
         state.lastCheckedBar[i] = 0;
        }
      return false;
     }

   // Заполнить activeIndices упорядоченным списком включённых tfIdx:
   // обход индексов 0..9 строго возрастающий — порядок
   // в активном наборе совпадает с порядком в MultiTfScheduler_AllTF.
   state.activeCount = 0;
   for(int i = 0; i < MULTITF_SCHEDULER_MAX_TF; i++)
     {
      if(flags[i])
        {
         state.activeIndices[state.activeCount] = i;
         state.activeCount++;
        }
     }

   // Инициализация in-memory антидубля: обнуляем
   // lastCheckedBar на всём диапазоне [0, MAX_TF), а не только
   // на активных индексах — индексируется значением tfIdx, и
   // вызывающая сторона всё равно обращается только к активным.
   for(int i = 0; i < MULTITF_SCHEDULER_MAX_TF; i++)
      state.lastCheckedBar[i] = 0;

   return true;
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerActiveCount (см. контракт в прототипе выше).     |
//|                                                                  |
//|  Чистый аксессор state.activeCount без                           |
//|  модификации state (const &).                                    |
//+------------------------------------------------------------------+
int MultiTfSchedulerActiveCount(const MultiTfSchedulerState &state)
  {
   return state.activeCount;
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerActiveAt (см. контракт в прототипе выше).        |
//|                                                                  |
//|  Возвращает tfIdx по порядковому номеру в                        |
//|  активном наборе. Без bounds-check: контракт фиксирует, что      |
//|  out-of-range — undefined; вызывающая сторона обязана            |
//|  итерировать только до ActiveCount(state).                       |
//+------------------------------------------------------------------+
int MultiTfSchedulerActiveAt(const MultiTfSchedulerState &state,
                             const int                    activeOrdinal)
  {
   return state.activeIndices[activeOrdinal];
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerTFEnum (см. контракт в прототипе выше).          |
//|                                                                  |
//|  Чистая функция от tfIdx → ENUM_TIMEFRAMES.                      |
//|  Используется вызывающей стороной для подстановки результата     |
//|  ActiveAt() в API MT5, требующее ENUM_TIMEFRAMES.                |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES MultiTfSchedulerTFEnum(const int tfIdx)
  {
   return MultiTfScheduler_AllTF[tfIdx];
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerTFToString (см. контракт в прототипе выше).      |
//|                                                                  |
//|  Десять явных кейсов + fallback EnumToString. Формат             |
//|  используется в текстах push-уведомлений.                        |
//+------------------------------------------------------------------+
string MultiTfSchedulerTFToString(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_H8:  return "H8";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
      default:         return EnumToString(tf);
     }
  }

//+------------------------------------------------------------------+
//| MultiTfScheduler_GVarName (см. контракт в прототипе выше).       |
//|                                                                  |
//|  Формат ключа GlobalVariable:                                    |
//|    StringFormat("RBCRT_%s_%s_lastBar",                           |
//|                 _Symbol,                                         |
//|                 EnumToString(MultiTfScheduler_AllTF[tfIdx]))     |
//|  Менять формат нельзя — это обнулит историю антидубля            |
//|  для уже работающих установок crt-push.                          |
//|                                                                  |
//|  Здесь намеренно используется EnumToString(tf) (например         |
//|  "PERIOD_H1"), а НЕ короткое имя из MultiTfSchedulerTFToString   |
//|  ("H1") — историческая схема ключа использует полное имя enum.   |
//+------------------------------------------------------------------+
string MultiTfScheduler_GVarName(const int tfIdx)
  {
   return StringFormat("RBCRT_%s_%s_lastBar",
                       _Symbol,
                       EnumToString(MultiTfScheduler_AllTF[tfIdx]));
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerIsNewBar (см. контракт в прототипе выше).        |
//|                                                                  |
//|  In-memory антидубль по бару.                                    |
//|    - Если state.lastCheckedBar[tfIdx] уже равен barTime,         |
//|      возвращаем false и НЕ модифицируем state.                   |
//|    - Иначе обновляем state.lastCheckedBar[tfIdx] := barTime до   |
//|      возврата управления и возвращаем true.                      |
//|                                                                  |
//|  state передан как mutable & (без const) — именно для обновления |
//|  state.lastCheckedBar[tfIdx] на первом вызове с новым barTime.   |
//+------------------------------------------------------------------+
bool MultiTfSchedulerIsNewBar(MultiTfSchedulerState &state,
                              const int             tfIdx,
                              const datetime        barTime)
  {
   if(state.lastCheckedBar[tfIdx] == barTime)
      return false;
   state.lastCheckedBar[tfIdx] = barTime;
   return true;
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerLoadLastSignalBar (см. контракт в прототипе выше)|
//|                                                                  |
//|  Персистентный слой антидубля через                              |
//|  GlobalVariable.                                                 |
//|    - Имя ключа формируется через MultiTfScheduler_GVarName.      |
//|    - Если GlobalVariableCheck(name) == false — возвращаем 0      |
//|      (sentinel «не было ни одной отправки»).                     |
//|    - Иначе возвращаем (datetime)GlobalVariableGet(name).         |
//|                                                                  |
//|  state передан как const & — функция не модифицирует state;      |
//|  параметр зарезервирован для симметрии с Save и будущих          |
//|  расширений.                                                     |
//+------------------------------------------------------------------+
datetime MultiTfSchedulerLoadLastSignalBar(const MultiTfSchedulerState &state,
                                           const int                    tfIdx)
  {
   string name = MultiTfScheduler_GVarName(tfIdx);
   if(!GlobalVariableCheck(name))
      return 0;
   return (datetime)GlobalVariableGet(name);
  }

//+------------------------------------------------------------------+
//| MultiTfSchedulerSaveLastSignalBar (см. контракт в прототипе выше)|
//|                                                                  |
//|  Запись last-signal bar в GlobalVariable.                        |
//|    - Имя ключа формируется через MultiTfScheduler_GVarName.      |
//|    - Значение сохраняется как (double)barTime через              |
//|      GlobalVariableSet — MT5 хранит GlobalVariable как double,   |
//|      а GlobalVariableGet возвращает double, который Load кастует |
//|      обратно в datetime.                                         |
//|                                                                  |
//|  state передан как const & — функция не модифицирует state;      |
//|  параметр зарезервирован для симметрии с Load и будущих          |
//|  расширений.                                                     |
//+------------------------------------------------------------------+
void MultiTfSchedulerSaveLastSignalBar(const MultiTfSchedulerState &state,
                                       const int                    tfIdx,
                                       const datetime               barTime)
  {
   string name = MultiTfScheduler_GVarName(tfIdx);
   GlobalVariableSet(name, (double)barTime);
  }

#endif // MULTITFSCHEDULER_MQH
//+------------------------------------------------------------------+
