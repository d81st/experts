//+------------------------------------------------------------------+
//|                                                  CrtDetector.mqh |
//|                                                                  |
//|  CRT Detector — чистая функция детекции CRT-паттернов на         |
//|  тройке свечей (prev, imb, doji).                                |
//|                                                                  |
//|  This header declares:                                           |
//|   - CrtDetectorConfig — иммутабельная конфигурация детектора     |
//|   - CrtPatternFlags   — флаги разрешения паттернов               |
//|   - CrtSignal         — результат детекции                       |
//|   - прототип публичной функции модуля:                           |
//|       CrtDetectorDetect                                          |
//|   - прототипы приватных хелперов с префиксом CrtDetector_*:      |
//|       CrtDetector_IsConfigInRange                                |
//|       CrtDetector_IsBodyInsideBody                               |
//|       CrtDetector_HasFVG                                         |
//|       CrtDetector_HasBreakout                                    |
//|       CrtDetector_IsFullyInsideImbRange                          |
//|                                                                  |
//|  Модуль соответствует требованиям модульной изоляции:            |
//|  include-guard уникален,                                         |
//|  конфигурация и флаги передаются только через const-struct       |
//|  аргументы, `input`-объявления в этом файле отсутствуют,         |
//|  глобальное состояние на уровне модуля отсутствует — детектор    |
//|  является чистой функцией от пяти входов в один выходной         |
//|  signal.                                                         |
//+------------------------------------------------------------------+
#ifndef CRTDETECTOR_MQH
#define CRTDETECTOR_MQH

//+------------------------------------------------------------------+
//| CrtDetectorConfig — иммутабельная конфигурация детектора.        |
//|                                                                  |
//|  Ровно шесть полей типа double; каждое валидно в диапазоне       |
//|  [0.0, 1.0] включительно.                                        |
//|  При нарушении                                                   |
//|  диапазона хотя бы одного поля CrtDetectorDetect возвращает      |
//|  signal с начальными значениями и не выполняет детекцию.         |
//|                                                                  |
//|  ImbBodyRatio         — мин. доля тела IMB от полного диапазона  |
//|                          IMB.                                    |
//|  DojiThreshold        — макс. доля тела Doji от полного          |
//|                          диапазона Doji.                         |
//|  DojiToImbSizeRatio   — макс. доля тела Doji относительно тела   |
//|                          IMB.                                    |
//|  DojiToImbRangeRatio  — макс. доля диапазона Doji относительно   |
//|                          диапазона IMB. Дефолт у потребителей    |
//|                          1.00.                                   |
//|  OpenTolerance        — допуск равенства doji.open ≈ imb.close,  |
//|                          выраженный как доля от |imb body|.      |
//|  BareImbWickTolerance — допуск «нет тени IMB со стороны Doji»,   |
//|                          выраженный как доля от                  |
//|                          |imb.close - imb.open|.                 |
//|                          0.0 = строгое равенство экстремума IMB  |
//|                          границе тела на bare-стороне;           |
//|                          дефолт у потребителей 0.05.             |
//|                                                                  |
//|  Передаётся в CrtDetectorDetect через const &; модуль не         |
//|  модифицирует поля cfg.                                          |
//+------------------------------------------------------------------+
struct CrtDetectorConfig
  {
   double ImbBodyRatio;         // [0.0, 1.0]
   double DojiThreshold;        // [0.0, 1.0]
   double DojiToImbSizeRatio;   // [0.0, 1.0]
   double DojiToImbRangeRatio;  // [0.0, 1.0]
   double OpenTolerance;        // [0.0, 1.0]
   double BareImbWickTolerance; // [0.0, 1.0]
  };

//+------------------------------------------------------------------+
//| CrtPatternFlags — флаги разрешения отдельных паттернов.          |
//|                                                                  |
//|  Ровно пять полей типа bool.                                     |
//|  Гейтинг применяется после выбора паттерна в ветке breakout/     |
//|  ghost — выключенный флаг приводит к signal.detected = false для |
//|  соответствующего имени. Поле signal.isFVG не                    |
//|  зависит от флагов.                                              |
//|                                                                  |
//|  AlertTrueRB          — разрешает имя "TrueRB"                   |
//|  AlertInsideWick      — разрешает имя "InsideWick"               |
//|  AlertGhostTrueRB     — разрешает имя "ghostTrueRB"              |
//|  AlertGhostInsideWick — разрешает имя "ghostInsideWick"          |
//|  AlertBareImbalance   — разрешает имя "bareImbalance" — пятое    |
//|                          имя паттерна, замещающее                |
//|                          "TrueRB"/"InsideWick" в breakout-ветке  |
//|                          при выполненном bare-условии.           |
//|                          false → bare-условие не проверяется,    |
//|                          поведение как без bare-паттерна.        |
//|                                                                  |
//|  Передаётся в CrtDetectorDetect через const &; модуль не         |
//|  модифицирует поля flags.                                        |
//+------------------------------------------------------------------+
struct CrtPatternFlags
  {
   bool AlertTrueRB;
   bool AlertInsideWick;
   bool AlertGhostTrueRB;
   bool AlertGhostInsideWick;
   bool AlertBareImbalance;
  };

//+------------------------------------------------------------------+
//| CrtSignal — выходной результат детекции.                         |
//|                                                                  |
//|  Ровно четыре поля; вся информация о решении детектора           |
//|  передаётся через эту структуру — других каналов вывода у        |
//|  модуля нет.                                                     |
//|                                                                  |
//|  detected    — true тогда и только тогда, когда паттерн          |
//|                  распознан AND соответствующий флаг включён.     |
//|                  Primary-флаг: потребитель обязан                |
//|                  проверять именно его перед использованием       |
//|                  остальных полей.                                |
//|  patternName — строка длиной ≤ 64 символа. При detected==true    |
//|                  ∈ {"TrueRB", "InsideWick", "ghostTrueRB",       |
//|                     "ghostInsideWick", "bareImbalance"}.         |
//|                  При detected==false — пустая                    |
//|                  строка либо имя паттерна, который не прошёл     |
//|                  флаговый гейтинг (потребитель не должен         |
//|                  полагаться на это).                             |
//|  imbDir      — ∈ {-1, 0, +1}. +1 = Bull IMB → SELL;              |
//|                  -1 = Bear IMB → BUY. При detected==true         |
//|                  imbDir != 0. Может быть != 0 даже               |
//|                  при detected==false, если фильтры Doji          |
//|                  отбраковали паттерн после установки imbDir.     |
//|  isFVG       — true ⇔ незаполненный гэп между prev и doji через  |
//|                  тело IMB. Вычисляется                           |
//|                  исключительно из (prev, doji, imbDir) и не      |
//|                  зависит от flags. При                           |
//|                  imbDir==0 → false.                              |
//|                                                                  |
//|  Все поля инициализируются на старте CrtDetectorDetect           |
//|  начальными значениями {false, "", 0, false} до выполнения       |
//|  любой проверки — это гарантирует, что ранний return             |
//|  оставит структуру в согласованном состоянии.                    |
//+------------------------------------------------------------------+
struct CrtSignal
  {
   bool   detected;     // primary-флаг
   string patternName;  // ∈ {"", "TrueRB", "InsideWick", "ghostTrueRB", "ghostInsideWick", "bareImbalance"}
   int    imbDir;       // ∈ {-1, 0, +1}
   bool   isFVG;
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс CrtDetector.                                 |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CrtDetectorDetect — определить наличие CRT-паттерна на тройке    |
//| свечей.                                                          |
//|                                                                  |
//|  Сигнатура: ровно шесть параметров в указанном                   |
//|  порядке — три const &-входа со свечами, два const &-входа с     |
//|  config/flags, один out-параметр signal.                         |
//|                                                                  |
//|  prev   — свеча rates[3] (предшествующая IMB).                   |
//|  imb    — свеча rates[2] (импульс).                              |
//|  doji   — свеча rates[1] (последняя закрытая, ближайшая к        |
//|             текущей).                                            |
//|  config — конфигурация детектора. Поля валидируются              |
//|             на [0.0, 1.0]; при нарушении — ранний возврат с      |
//|             начальным signal.                                    |
//|  flags  — флаги разрешения паттернов. Применяются                |
//|             после выбора имени; не влияют на signal.isFVG.       |
//|  signal — выходной результат. На старте функции                  |
//|             БЕЗУСЛОВНО инициализируется значениями               |
//|             {detected=false, patternName="", imbDir=0,           |
//|              isFVG=false}.                                       |
//|                                                                  |
//|  Контракт реализации:                                            |
//|                                                                  |
//|   1. Безусловная инициализация signal.                           |
//|   2. Валидация диапазонов config через                           |
//|      CrtDetector_IsConfigInRange; при провале — ранний return.   |
//|   3. Базовые фильтры IMB и Doji:                                 |
//|        - imb.high - imb.low > 0; иначе return.                   |
//|        - doji.high - doji.low > 0; иначе return.                 |
//|        - |imb.close - imb.open| / (imb.high - imb.low) >=        |
//|          ImbBodyRatio; иначе return.                             |
//|        - imbDir = +1 при imb.close > imb.open,                   |
//|          -1 при imb.close < imb.open.                            |
//|        - |doji.close - doji.open| / (doji.high - doji.low) <     |
//|          DojiThreshold; иначе return.                            |
//|   4. Установка signal.isFVG через CrtDetector_HasFVG.            |
//|   5. Фильтры сопоставления Doji ↔ IMB:                           |
//|        - |imb.close - imb.open| > 0 (защита от ÷0).              |
//|        - |doji.close - doji.open| / |imb.close - imb.open| <     |
//|          DojiToImbSizeRatio.                                     |
//|        - (doji.high - doji.low) < (imb.high - imb.low) *         |
//|          DojiToImbRangeRatio.                                    |
//|        - |doji.open - imb.close| <= OpenTolerance *              |
//|          |imb.close - imb.open|.                                 |
//|        - min(doji.open, doji.close) > imb.low AND                |
//|          max(doji.open, doji.close) < imb.high.                  |
//|   6. insideBody = CrtDetector_IsBodyInsideBody(imb, doji,        |
//|        OpenTolerance).                                           |
//|   7. Ветка breakout: при                                         |
//|      CrtDetector_HasBreakout(imb, doji, imbDir) выбрать имя      |
//|      "TrueRB" (insideBody) или "InsideWick" (иначе), затем       |
//|      гейтинг по flags.AlertTrueRB / flags.AlertInsideWick.       |
//|   8. Ветка ghost: активна только если ветка                      |
//|      breakout не сработала AND                                   |
//|      CrtDetector_IsFullyInsideImbRange(imb, doji). Выбрать       |
//|      имя "ghostTrueRB" (insideBody) или "ghostInsideWick"        |
//|      (иначе), затем гейтинг по flags.AlertGhostTrueRB /          |
//|      flags.AlertGhostInsideWick.                                 |
//|   9. Если ни ветка breakout, ни ветка ghost не активна —         |
//|      signal.detected = false, signal.patternName = "".           |
//|  10. После успешного выбора паттерна с пройденным флагом —       |
//|      signal.detected = true.                                     |
//|                                                                  |
//|  Свойства корректности:                                          |
//|   - Детерминированность: два вызова с                            |
//|     побитово одинаковыми входами возвращают одинаковый signal.   |
//|     Достигается отсутствием глобального состояния, чтения        |
//|     input-переменных, GlobalVariable, индикаторных хэндлов и     |
//|     иных источников недетерминизма.                              |
//|   - Чистота: cfg/flags объявлены const & —                       |
//|     компилятор гарантирует немодифицируемость; входные свечи     |
//|     prev/imb/doji также const &.                                 |
//|   - Соответствие направления: при detected ==                    |
//|     true imbDir ∈ {-1, +1} и согласуется со знаком               |
//|     (imb.close - imb.open).                                      |
//|   - Эквивалентность ghost ⇔ отсутствие пробоя:                   |
//|     обеспечивается порядком веток (8 запускается только если 7   |
//|     не сработала).                                               |
//|   - Замкнутое множество имён: при detected == true               |
//|     patternName ∈ {"TrueRB", "InsideWick", "ghostTrueRB",        |
//|                    "ghostInsideWick"}.                           |
//|   - FVG ⇒ направление определено: isFVG = true                   |
//|     возможен только после установки imbDir != 0 в шаге 3.        |
//|   - Порядок проверок, формулы фильтров и операторы               |
//|     сравнения (`<` vs `<=`) фиксированы — менять их нельзя,      |
//|     иначе изменится набор сигналов.                              |
//+------------------------------------------------------------------+
void CrtDetectorDetect(const MqlRates          &prev,
                       const MqlRates          &imb,
                       const MqlRates          &doji,
                       const CrtDetectorConfig &config,
                       const CrtPatternFlags   &flags,
                       CrtSignal               &signal);

//+------------------------------------------------------------------+
//| Приватные хелперы модуля (префикс CrtDetector_*).                |
//|                                                                  |
//|  Не входят в публичный API; используются только телом            |
//|  CrtDetectorDetect. Префикс предотвращает коллизии с             |
//|  одноимёнными утилитами в EA-файлах и фиксирует «module-private» |
//|  семантику в имени.                                              |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CrtDetector_IsConfigInRange — проверяет, что все шесть полей     |
//| CrtDetectorConfig лежат в диапазоне [0.0, 1.0] включительно.     |
//|                                                                  |
//|  Возвращает true ⇔ ImbBodyRatio, DojiThreshold,                  |
//|  DojiToImbSizeRatio, DojiToImbRangeRatio, OpenTolerance,         |
//|  BareImbWickTolerance ∈ [0.0, 1.0].                              |
//|                                                                  |
//|  Не модифицирует cfg (const &).                                  |
//+------------------------------------------------------------------+
bool CrtDetector_IsConfigInRange(const CrtDetectorConfig &cfg);

//+------------------------------------------------------------------+
//| CrtDetector_IsBodyInsideBody — проверяет, что тело Doji          |
//| находится внутри тела IMB с допуском openTolerance.              |
//|                                                                  |
//|  Формула:                                                        |
//|                                                                  |
//|    imbBody     = |imb.close - imb.open|                          |
//|    imbBodyHi   = max(imb.open, imb.close) + openTolerance*imbBody|
//|    imbBodyLo   = min(imb.open, imb.close) - openTolerance*imbBody|
//|    dojiBodyHi  = max(doji.open, doji.close)                      |
//|    dojiBodyLo  = min(doji.open, doji.close)                      |
//|    return (dojiBodyLo >= imbBodyLo) AND (dojiBodyHi <= imbBodyHi)|
//|                                                                  |
//|  Используется обоими ветками breakout и ghost для различения     |
//|  пары паттернов ("TrueRB"/"InsideWick" в breakout,               |
//|  "ghostTrueRB"/"ghostInsideWick" в ghost).                       |
//|                                                                  |
//|  Не модифицирует imb/doji (const &).                             |
//+------------------------------------------------------------------+
bool CrtDetector_IsBodyInsideBody(const MqlRates &imb,
                                  const MqlRates &doji,
                                  const double    openTolerance);

//+------------------------------------------------------------------+
//| CrtDetector_HasFVG — определяет наличие FVG между prev и doji.   |
//|                                                                  |
//|  Семантика:                                                      |
//|    imbDir == +1  →  return prev.high < doji.low                  |
//|    imbDir == -1  →  return prev.low  > doji.high                 |
//|    imbDir == 0   →  return false                                 |
//|                                                                  |
//|  Не зависит от flags — отсюда инвариант «isFVG не зависит от     |
//|  Alert-флагов». Гарантирует «FVG ⇒ направление                   |
//|  определено»: при imbDir == 0 функция возвращает                 |
//|  false, поэтому signal.isFVG = true возможен только при          |
//|  imbDir ∈ {-1, +1}.                                              |
//|                                                                  |
//|  Не модифицирует prev/doji (const &).                            |
//+------------------------------------------------------------------+
bool CrtDetector_HasFVG(const MqlRates &prev,
                        const MqlRates &doji,
                        const int       imbDir);

//+------------------------------------------------------------------+
//| CrtDetector_HasBreakout — проверяет «пробой экстремума IMB»      |
//| тенью Doji.                                                      |
//|                                                                  |
//|  Семантика:                                                      |
//|    (imbDir == +1 AND doji.high > imb.high)                       |
//|    OR                                                            |
//|    (imbDir == -1 AND doji.low  < imb.low)                        |
//|                                                                  |
//|  Используется в шаге 7 CrtDetectorDetect для выбора ветки        |
//|  breakout и в инварианте                                         |
//|  («ghost ⇔ NOT breakout»). Сравнения строгие (`>` / `<`).        |
//|                                                                  |
//|  Не модифицирует imb/doji (const &).                             |
//+------------------------------------------------------------------+
bool CrtDetector_HasBreakout(const MqlRates &imb,
                             const MqlRates &doji,
                             const int       imbDir);

//+------------------------------------------------------------------+
//| CrtDetector_IsFullyInsideImbRange — Doji полностью внутри        |
//| диапазона IMB.                                                   |
//|                                                                  |
//|  Семантика:                                                      |
//|    return (doji.high <= imb.high) AND (doji.low >= imb.low)      |
//|                                                                  |
//|  Используется в шаге 8 CrtDetectorDetect как условие активации   |
//|  ветки ghost. Сравнения нестрогие (`<=` / `>=`).                 |
//|                                                                  |
//|  Не модифицирует imb/doji (const &).                             |
//+------------------------------------------------------------------+
bool CrtDetector_IsFullyInsideImbRange(const MqlRates &imb,
                                       const MqlRates &doji);

//+------------------------------------------------------------------+
//| CrtDetector_IsBareImb — проверяет «нет тени IMB со стороны Doji».|
//|                                                                  |
//|  Семантика:                                                      |
//|    imbDir == -1 (bear IMB → BUY) — bare-сторона нижняя:          |
//|      bareWick = MathMin(imb.open, imb.close) - imb.low           |
//|    imbDir == +1 (bull IMB → SELL) — bare-сторона верхняя:        |
//|      bareWick = imb.high - MathMax(imb.open, imb.close)          |
//|    bareCondition = (bareWick <= wickTolerance *                  |
//|                      MathAbs(imb.close - imb.open))              |
//|                                                                  |
//|  При wickTolerance == 0.0 неравенство сводится к bareWick <= 0,  |
//|  что для неотрицательных wick'ов по построению геометрии свечи   |
//|  эквивалентно строгому равенству bareWick == 0.0.                |
//|                                                                  |
//|  Чистая функция от (imb, imbDir, wickTolerance) — не читает      |
//|  prev/doji/flags/остальные поля config.                          |
//|                                                                  |
//|  При imbDir == 0 возвращает false: bare-сторона                  |
//|  (нижняя или верхняя) не определена без известного направления   |
//|  IMB, поэтому формулы bare-стороны неприменимы; этот ранний      |
//|  выход поддерживает инвариант «bareImbalance ⇒ imbDir ∈ {-1,+1}».|
//|                                                                  |
//|  Стилистически симметричен CrtDetector_IsBodyInsideBody:         |
//|  тот же префикс CrtDetector_*, та же передача                    |
//|  допуска через параметр const double, та же формула              |
//|  wickTolerance * MathAbs(imb.close - imb.open) для масштаба      |
//|  допуска от модуля тела IMB.                                     |
//|                                                                  |
//|  Не модифицирует imb (const &).                                  |
//+------------------------------------------------------------------+
bool CrtDetector_IsBareImb(const MqlRates &imb,
                           const int       imbDir,
                           const double    wickTolerance);

//+------------------------------------------------------------------+
//| Implementations                                                  |
//|                                                                  |
//|  Реализация выполняется в том же .mqh-файле, в соответствии со   |
//|  стилем существующих модулей Include/* (см.                      |
//|  TrendFilter.mqh как канонический пример).                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CrtDetector_IsConfigInRange — приватный хелпер.                  |
//|                                                                  |
//|  Проверяет, что все шесть полей CrtDetectorConfig лежат в        |
//|  диапазоне [0.0, 1.0] включительно.                              |
//|  Используется в шаге 2                                           |
//|  CrtDetectorDetect для раннего отказа при невалидной             |
//|  конфигурации.                                                   |
//+------------------------------------------------------------------+
bool CrtDetector_IsConfigInRange(const CrtDetectorConfig &cfg)
  {
   if(cfg.ImbBodyRatio         < 0.0 || cfg.ImbBodyRatio         > 1.0) return false;
   if(cfg.DojiThreshold        < 0.0 || cfg.DojiThreshold        > 1.0) return false;
   if(cfg.DojiToImbSizeRatio   < 0.0 || cfg.DojiToImbSizeRatio   > 1.0) return false;
   if(cfg.DojiToImbRangeRatio  < 0.0 || cfg.DojiToImbRangeRatio  > 1.0) return false;
   if(cfg.OpenTolerance        < 0.0 || cfg.OpenTolerance        > 1.0) return false;
   if(cfg.BareImbWickTolerance < 0.0 || cfg.BareImbWickTolerance > 1.0) return false; // допуск вне [0.0, 1.0]
   return true;
  }

//+------------------------------------------------------------------+
//| CrtDetector_IsBodyInsideBody — приватный хелпер.                 |
//|                                                                  |
//|  Допуск передаётся параметром openTolerance, а не читается       |
//|  из глобального input.                                           |
//+------------------------------------------------------------------+
bool CrtDetector_IsBodyInsideBody(const MqlRates &imb,
                                  const MqlRates &doji,
                                  const double    openTolerance)
  {
   double imbBody    = MathAbs(imb.close - imb.open);
   double tolerance  = openTolerance * imbBody;
   double imbBodyHi  = MathMax(imb.open,  imb.close) + tolerance;
   double imbBodyLo  = MathMin(imb.open,  imb.close) - tolerance;
   double dojiBodyHi = MathMax(doji.open, doji.close);
   double dojiBodyLo = MathMin(doji.open, doji.close);
   return (dojiBodyLo >= imbBodyLo) && (dojiBodyHi <= imbBodyHi);
  }

//+------------------------------------------------------------------+
//| CrtDetector_HasFVG — приватный хелпер.                           |
//|                                                                  |
//|  Сравнения строгие (`<` / `>`).                                  |
//|  При imbDir == 0 возвращает false, что обеспечивает инвариант    |
//|  «FVG ⇒ направление определено».                                 |
//+------------------------------------------------------------------+
bool CrtDetector_HasFVG(const MqlRates &prev,
                        const MqlRates &doji,
                        const int       imbDir)
  {
   if(imbDir ==  1) return prev.high < doji.low;   // бычий гэп
   if(imbDir == -1) return prev.low  > doji.high;  // медвежий гэп
   return false;
  }

//+------------------------------------------------------------------+
//| CrtDetector_HasBreakout — приватный хелпер.                      |
//|                                                                  |
//|  Сравнения строгие (`>` / `<`).                                  |
//+------------------------------------------------------------------+
bool CrtDetector_HasBreakout(const MqlRates &imb,
                             const MqlRates &doji,
                             const int       imbDir)
  {
   if(imbDir ==  1) return doji.high > imb.high;
   if(imbDir == -1) return doji.low  < imb.low;
   return false;
  }

//+------------------------------------------------------------------+
//| CrtDetector_IsFullyInsideImbRange — приватный хелпер.            |
//|                                                                  |
//|  Сравнения нестрогие (`<=` / `>=`).                              |
//+------------------------------------------------------------------+
bool CrtDetector_IsFullyInsideImbRange(const MqlRates &imb,
                                       const MqlRates &doji)
  {
   return (doji.high <= imb.high) && (doji.low >= imb.low);
  }

//+------------------------------------------------------------------+
//| CrtDetector_IsBareImb — приватный хелпер.                        |
//|                                                                  |
//|  Проверяет bare-условие «нет тени IMB со стороны Doji» как       |
//|  чистую функцию от (imb, imbDir, wickTolerance).                 |
//|                                                                  |
//|  При imbDir == 0 — ранний выход с false: без                     |
//|  определённого направления IMB bare-сторона не определена.       |
//|                                                                  |
//|  Формулы:                                                        |
//|    imbDir == -1  →  bareWick = min(imb.open, imb.close) - imb.low|
//|    imbDir == +1  →  bareWick = imb.high - max(imb.open, imb.close)|
//|    return (bareWick <= wickTolerance * |imb.close - imb.open|)   |
//|                                                                  |
//|  Стиль и масштаб допуска симметричны CrtDetector_IsBodyInsideBody:|
//|  тот же префикс CrtDetector_*, тот же const double               |
//|  параметр допуска, тот же множитель MathAbs(imb.close-imb.open). |
//+------------------------------------------------------------------+
bool CrtDetector_IsBareImb(const MqlRates &imb,
                           const int       imbDir,
                           const double    wickTolerance)
  {
   if(imbDir == 0)
      return false;

   double imbBody = MathAbs(imb.close - imb.open);
   double bareWick;
   if(imbDir == -1)                                         // BUY: нижняя сторона
      bareWick = MathMin(imb.open, imb.close) - imb.low;
   else                                                     // SELL: верхняя сторона; imbDir == +1
      bareWick = imb.high - MathMax(imb.open, imb.close);

   return (bareWick <= wickTolerance * imbBody);
  }

//+------------------------------------------------------------------+
//| CrtDetectorDetect — публичная функция модуля.                    |
//|                                                                  |
//|  Полный контракт шагов зафиксирован в шапке файла; здесь —       |
//|  трансляция в код с точными операторами сравнения                |
//|  (`>=` / `<` / `<=` / `>`).                                      |
//+------------------------------------------------------------------+
void CrtDetectorDetect(const MqlRates          &prev,
                       const MqlRates          &imb,
                       const MqlRates          &doji,
                       const CrtDetectorConfig &config,
                       const CrtPatternFlags   &flags,
                       CrtSignal               &signal)
  {
   //--- Step 1: безусловная инициализация signal.
   signal.detected    = false;
   signal.patternName = "";
   signal.imbDir      = 0;
   signal.isFVG       = false;

   //--- Step 2: валидация диапазонов config.
   if(!CrtDetector_IsConfigInRange(config))
      return;

   //--- Step 3: базовые фильтры IMB и Doji.
   double imbRange  = imb.high  - imb.low;
   if(imbRange <= 0.0)
      return;
   double dojiRange = doji.high - doji.low;
   if(dojiRange <= 0.0)
      return;

   double imbBody = MathAbs(imb.close - imb.open);
   if(imbBody / imbRange < config.ImbBodyRatio)
      return;

   if(imb.close > imb.open)
      signal.imbDir =  1;
   else if(imb.close < imb.open)
      signal.imbDir = -1;

   double dojiBody = MathAbs(doji.close - doji.open);
   if(dojiBody / dojiRange >= config.DojiThreshold)
      return;

   //--- Step 4: signal.isFVG.
   //   Вычисляется до фильтров сопоставления и не зависит от flags —
   //   это гарантирует «isFVG не зависит от Alert-флагов».
   signal.isFVG = CrtDetector_HasFVG(prev, doji, signal.imbDir);

   //--- Step 5: фильтры сопоставления Doji ↔ IMB.
   if(imbBody <= 0.0)                                                  // защита от ÷0
      return;
   if(dojiBody / imbBody >= config.DojiToImbSizeRatio)
      return;
   if(dojiRange >= imbRange * config.DojiToImbRangeRatio)
      return;
   if(MathAbs(doji.open - imb.close) > config.OpenTolerance * imbBody)
      return;
   double dojiBodyLo = MathMin(doji.open, doji.close);
   double dojiBodyHi = MathMax(doji.open, doji.close);
   if(!(dojiBodyLo > imb.low && dojiBodyHi < imb.high))
      return;

   //--- Step 6: insideBody.
   bool insideBody = CrtDetector_IsBodyInsideBody(imb, doji, config.OpenTolerance);

   //--- Step 7: ветка breakout.
   if(CrtDetector_HasBreakout(imb, doji, signal.imbDir))
     {
      //--- Step 7a: приоритетная bare-проверка. Гейтинг через
      //    flags.AlertBareImbalance проверяется первым операндом —
      //    короткое замыкание `&&` гарантирует, что при выключенном
      //    флаге CrtDetector_IsBareImb НЕ вызывается, а поле
      //    config.BareImbWickTolerance НЕ читается (что
      //    даёт побитовую эквивалентность с поведением без bare-паттерна).
      //
      //    bare-условие имеет приоритет над выбором TrueRB/InsideWick:
      //    при выполнении имя "bareImbalance" замещает классические
      //    имена независимо от flags.AlertTrueRB / flags.AlertInsideWick.
      //    Также bare-замещение НЕ зависит от insideBody:
      //    тело Doji может быть как внутри тела IMB, так
      //    и снаружи — в обоих случаях имя одно и то же.
      if(flags.AlertBareImbalance &&
         CrtDetector_IsBareImb(imb, signal.imbDir, config.BareImbWickTolerance))
        {
         signal.patternName = "bareImbalance";
         signal.detected    = true;
         return;
        }

      //--- Step 7b: существующая логика TrueRB/InsideWick.
      if(insideBody)
        {
         if(!flags.AlertTrueRB)
            return;
         signal.patternName = "TrueRB";
        }
      else
        {
         if(!flags.AlertInsideWick)
            return;
         signal.patternName = "InsideWick";
        }
      signal.detected = true;
      return;
     }

   //--- Step 8: ветка ghost.
   //   Активируется только если ветка breakout не сработала —
   //   обеспечивает инвариант «ghost ⇔ NOT breakout».
   if(CrtDetector_IsFullyInsideImbRange(imb, doji))
     {
      if(insideBody)
        {
         if(!flags.AlertGhostTrueRB)
            return;
         signal.patternName = "ghostTrueRB";
        }
      else
        {
         if(!flags.AlertGhostInsideWick)
            return;
         signal.patternName = "ghostInsideWick";
        }
      signal.detected = true;
      return;
     }

   //--- Step 9: ни одна ветка не активна.
   //   signal.detected уже false, signal.patternName уже пуст —
   //   функция просто завершается. signal.imbDir и signal.isFVG
   //   сохраняют значения, установленные в шагах 3 и 4.
  }

#endif // CRTDETECTOR_MQH
//+------------------------------------------------------------------+
