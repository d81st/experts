//+------------------------------------------------------------------+
//|                                                  CrtDetector.mqh |
//|                                                                  |
//|  CRT Detector — чистая функция детекции CRT-паттернов на         |
//|  тройке свечей (prev, imb, doji).                                |
//|                                                                  |
//|  Feature: crt-push-modularization                                |
//|  Spec:    .kiro/specs/crt-push-modularization/design.md          |
//|           (Components and Interfaces → 1. Include/CrtDetector)   |
//|                                                                  |
//|  This header declares:                                           |
//|   - CrtDetectorConfig — иммутабельная конфигурация детектора     |
//|                          (Req 1.2)                               |
//|   - CrtPatternFlags   — флаги разрешения паттернов (Req 1.3)     |
//|   - CrtSignal         — результат детекции (Req 1.4)             |
//|   - прототип публичной функции модуля:                           |
//|       CrtDetectorDetect (Req 1.1, 1.5..1.8, 2.*, 3.*, 4.*, 5.*,  |
//|                          15.1, 19.*)                             |
//|   - прототипы приватных хелперов с префиксом CrtDetector_*       |
//|     (Req 17.7):                                                  |
//|       CrtDetector_IsConfigInRange       (Req 1.6)                |
//|       CrtDetector_IsBodyInsideBody      (Req 4.9)                |
//|       CrtDetector_HasFVG                (Req 5.6, 5.7, 5.9)      |
//|       CrtDetector_HasBreakout           (Req 4.1, 4.2)           |
//|       CrtDetector_IsFullyInsideImbRange (Req 4.5)                |
//|                                                                  |
//|  Модуль соответствует требованиям модульной изоляции             |
//|  (Req 17.1, 17.4, 17.5, 17.6): include-guard уникален,           |
//|  конфигурация и флаги передаются только через const-struct       |
//|  аргументы, `input`-объявления в этом файле отсутствуют,         |
//|  глобальное состояние на уровне модуля отсутствует — детектор    |
//|  является чистой функцией от пяти входов в один выходной         |
//|  signal (Req 1.7, 19.1, 19.2).                                   |
//|                                                                  |
//|  Тела функций реализуются в задачах 1.2 (приватные хелперы) и    |
//|  1.3 (CrtDetectorDetect) этой же спеки.                          |
//+------------------------------------------------------------------+
#ifndef CRTDETECTOR_MQH
#define CRTDETECTOR_MQH

//+------------------------------------------------------------------+
//| CrtDetectorConfig — иммутабельная конфигурация детектора.        |
//|                                                                  |
//|  Ровно шесть полей типа double; каждое валидно в диапазоне       |
//|  [0.0, 1.0] включительно (Req 1.2 спеки crt-push-modularization, |
//|  Req 1.1, 1.6 спеки bare-imbalance-pattern). При нарушении       |
//|  диапазона хотя бы одного поля CrtDetectorDetect возвращает      |
//|  signal с начальными значениями и не выполняет детекцию          |
//|  (Req 1.6).                                                      |
//|                                                                  |
//|  ImbBodyRatio         — мин. доля тела IMB от полного диапазона  |
//|                          IMB (Req 2.3).                          |
//|  DojiThreshold        — макс. доля тела Doji от полного          |
//|                          диапазона Doji (Req 2.6).               |
//|  DojiToImbSizeRatio   — макс. доля тела Doji относительно тела   |
//|                          IMB (Req 3.2).                          |
//|  DojiToImbRangeRatio  — макс. доля диапазона Doji относительно   |
//|                          диапазона IMB (Req 3.3). Новое поле     |
//|                          относительно pre-migration Crt_Bot      |
//|                          (Req 14.1); дефолт у потребителей 1.00. |
//|  OpenTolerance        — допуск равенства doji.open ≈ imb.close,  |
//|                          выраженный как доля от |imb body|       |
//|                          (Req 3.4, 4.9).                         |
//|  BareImbWickTolerance — допуск «нет тени IMB со стороны Doji»,   |
//|                          выраженный как доля от                  |
//|                          |imb.close - imb.open| (Req 1.1, 2.3    |
//|                          спеки bare-imbalance-pattern).          |
//|                          0.0 = строгое равенство экстремума IMB  |
//|                          границе тела на bare-стороне (Req 2.4); |
//|                          дефолт у потребителей 0.05.             |
//|                                                                  |
//|  Передаётся в CrtDetectorDetect через const &; модуль не         |
//|  модифицирует поля cfg (Req 17.4, 19.2).                         |
//+------------------------------------------------------------------+
struct CrtDetectorConfig
  {
   double ImbBodyRatio;         // [0.0, 1.0]
   double DojiThreshold;        // [0.0, 1.0]
   double DojiToImbSizeRatio;   // [0.0, 1.0]
   double DojiToImbRangeRatio;  // [0.0, 1.0]
   double OpenTolerance;        // [0.0, 1.0]
   double BareImbWickTolerance; // [0.0, 1.0] — Req 1.1 спеки bare-imbalance-pattern
  };

//+------------------------------------------------------------------+
//| CrtPatternFlags — флаги разрешения отдельных паттернов.          |
//|                                                                  |
//|  Ровно пять полей типа bool (Req 1.3 спеки                       |
//|  crt-push-modularization, Req 1.2 спеки bare-imbalance-pattern). |
//|  Гейтинг применяется после выбора паттерна в ветке breakout/     |
//|  ghost — выключенный флаг приводит к signal.detected = false для |
//|  соответствующего имени (Req 5.1..5.4). Поле signal.isFVG не     |
//|  зависит от флагов (Req 5.8, 19.8).                              |
//|                                                                  |
//|  AlertTrueRB          — разрешает имя "TrueRB"          (Req 5.1)|
//|  AlertInsideWick      — разрешает имя "InsideWick"      (Req 5.2)|
//|  AlertGhostTrueRB     — разрешает имя "ghostTrueRB"     (Req 5.3)|
//|  AlertGhostInsideWick — разрешает имя "ghostInsideWick" (Req 5.4)|
//|  AlertBareImbalance   — разрешает имя "bareImbalance" — пятое    |
//|                          имя паттерна, замещающее                |
//|                          "TrueRB"/"InsideWick" в breakout-ветке  |
//|                          при выполненном bare-условии (Req 1.2,  |
//|                          4.1, 4.2 спеки bare-imbalance-pattern). |
//|                          false → bare-условие не проверяется,    |
//|                          поведение pre-spec (Req 12.1).          |
//|                                                                  |
//|  Передаётся в CrtDetectorDetect через const &; модуль не         |
//|  модифицирует поля flags (Req 17.4, 19.2).                       |
//+------------------------------------------------------------------+
struct CrtPatternFlags
  {
   bool AlertTrueRB;
   bool AlertInsideWick;
   bool AlertGhostTrueRB;
   bool AlertGhostInsideWick;
   bool AlertBareImbalance;   // Req 1.2 спеки bare-imbalance-pattern
  };

//+------------------------------------------------------------------+
//| CrtSignal — выходной результат детекции (Req 1.4).               |
//|                                                                  |
//|  Ровно четыре поля; вся информация о решении детектора           |
//|  передаётся через эту структуру — других каналов вывода у        |
//|  модуля нет (Req 1.7, 19.2).                                     |
//|                                                                  |
//|  detected    — true тогда и только тогда, когда паттерн          |
//|                  распознан AND соответствующий флаг включён      |
//|                  (Req 5.5). Primary-флаг: потребитель обязан     |
//|                  проверять именно его перед использованием       |
//|                  остальных полей.                                |
//|  patternName — строка длиной ≤ 64 символа. При detected==true    |
//|                  ∈ {"TrueRB", "InsideWick", "ghostTrueRB",       |
//|                     "ghostInsideWick", "bareImbalance"}          |
//|                  (Req 1.4 спеки crt-push-modularization, Req 1.4 |
//|                  спеки bare-imbalance-pattern; см. также         |
//|                  Req 19.10, 13.8). При detected==false — пустая  |
//|                  строка либо имя паттерна, который не прошёл     |
//|                  флаговый гейтинг (потребитель не должен         |
//|                  полагаться на это).                             |
//|  imbDir      — ∈ {-1, 0, +1} (Req 1.4). +1 = Bull IMB → SELL;    |
//|                  -1 = Bear IMB → BUY. При detected==true         |
//|                  imbDir != 0 (Req 19.4). Может быть != 0 даже    |
//|                  при detected==false, если фильтры Doji          |
//|                  отбраковали паттерн после установки imbDir.     |
//|  isFVG       — true ⇔ незаполненный гэп между prev и doji через  |
//|                  тело IMB (Req 5.6, 5.7). Вычисляется            |
//|                  исключительно из (prev, doji, imbDir) и не      |
//|                  зависит от flags (Req 5.8, 19.8). При           |
//|                  imbDir==0 → false (Req 5.9).                    |
//|                                                                  |
//|  Все поля инициализируются на старте CrtDetectorDetect           |
//|  начальными значениями {false, "", 0, false} до выполнения       |
//|  любой проверки (Req 1.5) — это гарантирует, что ранний return   |
//|  оставит структуру в согласованном состоянии.                    |
//+------------------------------------------------------------------+
struct CrtSignal
  {
   bool   detected;     // primary-флаг: см. Req 1.4, 5.5
   string patternName;  // ∈ {"", "TrueRB", "InsideWick", "ghostTrueRB", "ghostInsideWick", "bareImbalance"}
   int    imbDir;       // ∈ {-1, 0, +1}; Req 1.4, 19.4
   bool   isFVG;        // Req 5.6, 5.7, 5.8, 5.9
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс CrtDetector (Module 1).                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CrtDetectorDetect — определить наличие CRT-паттерна на тройке    |
//| свечей.                                                          |
//|                                                                  |
//|  Сигнатура (Req 1.1): ровно шесть параметров в указанном         |
//|  порядке — три const &-входа со свечами, два const &-входа с     |
//|  config/flags, один out-параметр signal.                         |
//|                                                                  |
//|  prev   — свеча rates[3] (предшествующая IMB).                   |
//|  imb    — свеча rates[2] (импульс).                              |
//|  doji   — свеча rates[1] (последняя закрытая, ближайшая к        |
//|             текущей).                                            |
//|  config — конфигурация детектора (Req 1.2). Поля валидируются    |
//|             на [0.0, 1.0]; при нарушении — ранний возврат с      |
//|             начальным signal (Req 1.6).                          |
//|  flags  — флаги разрешения паттернов (Req 1.3). Применяются      |
//|             после выбора имени; не влияют на signal.isFVG        |
//|             (Req 5.8, 19.8).                                     |
//|  signal — выходной результат (Req 1.4). На старте функции        |
//|             БЕЗУСЛОВНО инициализируется значениями               |
//|             {detected=false, patternName="", imbDir=0,           |
//|              isFVG=false} (Req 1.5).                             |
//|                                                                  |
//|  Контракт реализации (полный порядок шагов фиксируется в         |
//|  задаче 1.3 этой спеки):                                         |
//|                                                                  |
//|   1. Безусловная инициализация signal (Req 1.5).                 |
//|   2. Валидация диапазонов config через                           |
//|      CrtDetector_IsConfigInRange; при провале — ранний return    |
//|      (Req 1.6).                                                  |
//|   3. Базовые фильтры IMB и Doji (Req 2.1..2.6):                  |
//|        - imb.high - imb.low > 0; иначе return (Req 2.1).         |
//|        - doji.high - doji.low > 0; иначе return (Req 2.2).       |
//|        - |imb.close - imb.open| / (imb.high - imb.low) >=        |
//|          ImbBodyRatio; иначе return (Req 2.3).                   |
//|        - imbDir = +1 при imb.close > imb.open (Req 2.4),         |
//|          -1 при imb.close < imb.open (Req 2.5).                  |
//|        - |doji.close - doji.open| / (doji.high - doji.low) <     |
//|          DojiThreshold; иначе return (Req 2.6).                  |
//|   4. Установка signal.isFVG через CrtDetector_HasFVG             |
//|      (Req 5.6, 5.7, 5.9, 19.8).                                  |
//|   5. Фильтры сопоставления Doji ↔ IMB (Req 3.1..3.5):            |
//|        - |imb.close - imb.open| > 0 (защита от ÷0; Req 3.1).     |
//|        - |doji.close - doji.open| / |imb.close - imb.open| <     |
//|          DojiToImbSizeRatio (Req 3.2).                           |
//|        - (doji.high - doji.low) < (imb.high - imb.low) *         |
//|          DojiToImbRangeRatio (Req 3.3).                          |
//|        - |doji.open - imb.close| <= OpenTolerance *              |
//|          |imb.close - imb.open| (Req 3.4).                       |
//|        - min(doji.open, doji.close) > imb.low AND                |
//|          max(doji.open, doji.close) < imb.high (Req 3.5).        |
//|   6. insideBody = CrtDetector_IsBodyInsideBody(imb, doji,        |
//|        OpenTolerance) (Req 4.9).                                 |
//|   7. Ветка breakout (Req 4.1..4.4): при                          |
//|      CrtDetector_HasBreakout(imb, doji, imbDir) выбрать имя      |
//|      "TrueRB" (insideBody) или "InsideWick" (иначе), затем       |
//|      гейтинг по flags.AlertTrueRB / flags.AlertInsideWick        |
//|      (Req 5.1, 5.2).                                             |
//|   8. Ветка ghost (Req 4.5..4.7): активна только если ветка       |
//|      breakout не сработала AND                                   |
//|      CrtDetector_IsFullyInsideImbRange(imb, doji). Выбрать       |
//|      имя "ghostTrueRB" (insideBody) или "ghostInsideWick"        |
//|      (иначе), затем гейтинг по flags.AlertGhostTrueRB /          |
//|      flags.AlertGhostInsideWick (Req 5.3, 5.4).                  |
//|   9. Если ни ветка breakout, ни ветка ghost не активна —         |
//|      signal.detected = false, signal.patternName = ""            |
//|      (Req 4.8).                                                  |
//|  10. После успешного выбора паттерна с пройденным флагом —       |
//|      signal.detected = true (Req 5.5).                           |
//|                                                                  |
//|  Свойства корректности (Req 19):                                 |
//|   - Детерминированность (Req 1.8, 19.1): два вызова с            |
//|     побитово одинаковыми входами возвращают одинаковый signal.   |
//|     Достигается отсутствием глобального состояния, чтения        |
//|     input-переменных, GlobalVariable, индикаторных хэндлов и     |
//|     иных источников недетерминизма (Req 1.7).                    |
//|   - Чистота (Req 19.2): cfg/flags объявлены const & —            |
//|     компилятор гарантирует немодифицируемость; входные свечи     |
//|     prev/imb/doji также const &.                                 |
//|   - Соответствие направления (Req 19.3, 19.4): при detected ==   |
//|     true imbDir ∈ {-1, +1} и согласуется со знаком               |
//|     (imb.close - imb.open).                                      |
//|   - Эквивалентность ghost ⇔ отсутствие пробоя (Req 19.5):        |
//|     обеспечивается порядком веток (8 запускается только если 7   |
//|     не сработала).                                               |
//|   - Замкнутое множество имён (Req 19.10): при detected == true   |
//|     patternName ∈ {"TrueRB", "InsideWick", "ghostTrueRB",        |
//|                    "ghostInsideWick"}.                           |
//|   - FVG ⇒ направление определено (Req 19.11): isFVG = true       |
//|     возможен только после установки imbDir != 0 в шаге 3.        |
//|   - Поведенческая эквивалентность с Crt_Push_V7 (Req 15.1,       |
//|     19.12): порядок проверок, формулы фильтров и операторы       |
//|     сравнения (`<` vs `<=`) буквально копируют                   |
//|     CheckPatternOnTF из crt-push_v7.2.mq5.                       |
//|                                                                  |
//|  Тело реализуется в задаче 1.3.                                  |
//+------------------------------------------------------------------+
void CrtDetectorDetect(const MqlRates          &prev,
                       const MqlRates          &imb,
                       const MqlRates          &doji,
                       const CrtDetectorConfig &config,
                       const CrtPatternFlags   &flags,
                       CrtSignal               &signal);

//+------------------------------------------------------------------+
//| Приватные хелперы модуля (префикс CrtDetector_*, Req 17.7).      |
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
//|  BareImbWickTolerance ∈ [0.0, 1.0] (Req 1.2, 1.6 спеки           |
//|  crt-push-modularization; Req 1.1, 1.6 спеки                     |
//|  bare-imbalance-pattern).                                        |
//|                                                                  |
//|  Не модифицирует cfg (const &, Req 17.4, 19.2). Тело             |
//|  реализуется в задаче 1.2.                                       |
//+------------------------------------------------------------------+
bool CrtDetector_IsConfigInRange(const CrtDetectorConfig &cfg);

//+------------------------------------------------------------------+
//| CrtDetector_IsBodyInsideBody — проверяет, что тело Doji          |
//| находится внутри тела IMB с допуском openTolerance (Req 4.9).    |
//|                                                                  |
//|  Формула (буквальная копия IsDojiBodyInsideImbBody из            |
//|  crt-push_v7.2.mq5 — обеспечивает поведенческую                  |
//|  эквивалентность, Req 15.1, 19.12):                              |
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
//|  "ghostTrueRB"/"ghostInsideWick" в ghost) (Req 4.3, 4.4, 4.6,    |
//|  4.7, 19.6, 19.7).                                               |
//|                                                                  |
//|  Не модифицирует imb/doji (const &, Req 17.4, 19.2). Тело        |
//|  реализуется в задаче 1.2.                                       |
//+------------------------------------------------------------------+
bool CrtDetector_IsBodyInsideBody(const MqlRates &imb,
                                  const MqlRates &doji,
                                  const double    openTolerance);

//+------------------------------------------------------------------+
//| CrtDetector_HasFVG — определяет наличие FVG между prev и doji.   |
//|                                                                  |
//|  Семантика (Req 5.6, 5.7, 5.9):                                  |
//|    imbDir == +1  →  return prev.high < doji.low                  |
//|    imbDir == -1  →  return prev.low  > doji.high                 |
//|    imbDir == 0   →  return false                                 |
//|                                                                  |
//|  Не зависит от flags — отсюда инвариант «isFVG не зависит от     |
//|  Alert-флагов» (Req 5.8, 19.8). Гарантирует «FVG ⇒ направление   |
//|  определено» (Req 19.11): при imbDir == 0 функция возвращает     |
//|  false, поэтому signal.isFVG = true возможен только при          |
//|  imbDir ∈ {-1, +1}.                                              |
//|                                                                  |
//|  Не модифицирует prev/doji (const &, Req 17.4, 19.2). Тело       |
//|  реализуется в задаче 1.2.                                       |
//+------------------------------------------------------------------+
bool CrtDetector_HasFVG(const MqlRates &prev,
                        const MqlRates &doji,
                        const int       imbDir);

//+------------------------------------------------------------------+
//| CrtDetector_HasBreakout — проверяет «пробой экстремума IMB»      |
//| тенью Doji (Req 4.1, 4.2).                                       |
//|                                                                  |
//|  Семантика:                                                      |
//|    (imbDir == +1 AND doji.high > imb.high)                       |
//|    OR                                                            |
//|    (imbDir == -1 AND doji.low  < imb.low)                        |
//|                                                                  |
//|  Используется в шаге 7 CrtDetectorDetect для выбора ветки        |
//|  breakout (Req 4.1, 4.2, 4.3, 4.4) и в инварианте Req 19.5       |
//|  («ghost ⇔ NOT breakout»). Сравнения строгие (`>` / `<`) —       |
//|  как в HasExtremumBreakout из crt-push_v7.2.mq5 (Req 15.1).      |
//|                                                                  |
//|  Не модифицирует imb/doji (const &, Req 17.4, 19.2). Тело        |
//|  реализуется в задаче 1.2.                                       |
//+------------------------------------------------------------------+
bool CrtDetector_HasBreakout(const MqlRates &imb,
                             const MqlRates &doji,
                             const int       imbDir);

//+------------------------------------------------------------------+
//| CrtDetector_IsFullyInsideImbRange — Doji полностью внутри        |
//| диапазона IMB (Req 4.5).                                         |
//|                                                                  |
//|  Семантика:                                                      |
//|    return (doji.high <= imb.high) AND (doji.low >= imb.low)      |
//|                                                                  |
//|  Используется в шаге 8 CrtDetectorDetect как условие активации   |
//|  ветки ghost (Req 4.5, 4.6, 4.7). Сравнения нестрогие            |
//|  (`<=` / `>=`) — копия IsFullyInsideImbRange из                  |
//|  crt-push_v7.2.mq5 (Req 15.1).                                   |
//|                                                                  |
//|  Не модифицирует imb/doji (const &, Req 17.4, 19.2). Тело        |
//|  реализуется в задаче 1.2.                                       |
//+------------------------------------------------------------------+
bool CrtDetector_IsFullyInsideImbRange(const MqlRates &imb,
                                       const MqlRates &doji);

//+------------------------------------------------------------------+
//| CrtDetector_IsBareImb — проверяет «нет тени IMB со стороны Doji» |
//| (Req 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.7, 10.1, 10.2 спеки         |
//| bare-imbalance-pattern).                                         |
//|                                                                  |
//|  Семантика (Req 2.1, 2.2, 2.3, 2.4):                             |
//|    imbDir == -1 (bear IMB → BUY) — bare-сторона нижняя:          |
//|      bareWick = MathMin(imb.open, imb.close) - imb.low           |
//|    imbDir == +1 (bull IMB → SELL) — bare-сторона верхняя:        |
//|      bareWick = imb.high - MathMax(imb.open, imb.close)          |
//|    bareCondition = (bareWick <= wickTolerance *                  |
//|                      MathAbs(imb.close - imb.open))              |
//|                                                                  |
//|  При wickTolerance == 0.0 неравенство сводится к bareWick <= 0,  |
//|  что для неотрицательных wick'ов по построению геометрии свечи   |
//|  эквивалентно строгому равенству bareWick == 0.0 (Req 2.4).      |
//|                                                                  |
//|  Чистая функция от (imb, imbDir, wickTolerance) — не читает      |
//|  prev/doji/flags/остальные поля config (Req 2.5, 10.2, 13.12).   |
//|                                                                  |
//|  При imbDir == 0 возвращает false (Req 2.6, 3.7): bare-сторона   |
//|  (нижняя или верхняя) не определена без известного направления   |
//|  IMB, поэтому формулы Req 2.1–2.2 неприменимы; этот ранний       |
//|  выход поддерживает инвариант «bareImbalance ⇒ imbDir ∈ {-1,+1}» |
//|  (Req 13.4).                                                     |
//|                                                                  |
//|  Стилистически симметричен CrtDetector_IsBodyInsideBody          |
//|  (Req 10.1): тот же префикс CrtDetector_*, та же передача        |
//|  допуска через параметр const double, та же формула              |
//|  wickTolerance * MathAbs(imb.close - imb.open) для масштаба      |
//|  допуска от модуля тела IMB.                                     |
//|                                                                  |
//|  Не модифицирует imb (const &, Req 17.4, 19.2).                  |
//+------------------------------------------------------------------+
bool CrtDetector_IsBareImb(const MqlRates &imb,
                           const int       imbDir,
                           const double    wickTolerance);

//+------------------------------------------------------------------+
//| Implementations                                                  |
//|                                                                  |
//|  Тела приватных хелперов CrtDetector_* реализуются в задаче 1.2; |
//|  тело публичной функции CrtDetectorDetect — в задаче 1.3 этой    |
//|  же спеки (crt-push-modularization).                             |
//|                                                                  |
//|  Реализация выполняется в том же .mqh-файле, в соответствии со   |
//|  стилем существующих модулей Include/* (Req 17.6; см.            |
//|  TrendFilter.mqh как канонический пример).                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CrtDetector_IsConfigInRange — приватный хелпер.                  |
//|                                                                  |
//|  Проверяет, что все шесть полей CrtDetectorConfig лежат в        |
//|  диапазоне [0.0, 1.0] включительно (Req 1.2, 1.6 спеки           |
//|  crt-push-modularization; Req 1.1, 1.6 спеки                     |
//|  bare-imbalance-pattern). Используется в шаге 2                  |
//|  CrtDetectorDetect для раннего отказа при невалидной             |
//|  конфигурации (Req 1.6).                                         |
//+------------------------------------------------------------------+
bool CrtDetector_IsConfigInRange(const CrtDetectorConfig &cfg)
  {
   if(cfg.ImbBodyRatio         < 0.0 || cfg.ImbBodyRatio         > 1.0) return false;
   if(cfg.DojiThreshold        < 0.0 || cfg.DojiThreshold        > 1.0) return false;
   if(cfg.DojiToImbSizeRatio   < 0.0 || cfg.DojiToImbSizeRatio   > 1.0) return false;
   if(cfg.DojiToImbRangeRatio  < 0.0 || cfg.DojiToImbRangeRatio  > 1.0) return false;
   if(cfg.OpenTolerance        < 0.0 || cfg.OpenTolerance        > 1.0) return false;
   if(cfg.BareImbWickTolerance < 0.0 || cfg.BareImbWickTolerance > 1.0) return false; // Req 1.6 (bare-imbalance-pattern)
   return true;
  }

//+------------------------------------------------------------------+
//| CrtDetector_IsBodyInsideBody — приватный хелпер.                 |
//|                                                                  |
//|  Буквальная копия IsDojiBodyInsideImbBody из crt-push_v7.2.mq5,  |
//|  с единственным отличием: допуск передаётся параметром           |
//|  openTolerance вместо чтения глобального input (Req 17.4, 17.5). |
//|  Семантика, операторы сравнения и порядок вычислений сохранены   |
//|  побитово (Req 4.9, 15.1, 19.12).                                |
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
//|  Буквальная копия HasFVG из crt-push_v7.2.mq5 (Req 5.6, 5.7,     |
//|  5.9, 15.1). Сравнения строгие (`<` / `>`) — как в оракуле.      |
//|  При imbDir == 0 возвращает false, что обеспечивает инвариант    |
//|  «FVG ⇒ направление определено» (Req 5.9, 19.11).                |
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
//|  Буквальная копия HasExtremumBreakout из crt-push_v7.2.mq5       |
//|  (Req 4.1, 4.2, 15.1). Сравнения строгие (`>` / `<`) —           |
//|  как в оракуле.                                                  |
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
//|  Буквальная копия IsFullyInsideImbRange из crt-push_v7.2.mq5     |
//|  (Req 4.5, 15.1). Сравнения нестрогие (`<=` / `>=`) — как в      |
//|  оракуле.                                                        |
//+------------------------------------------------------------------+
bool CrtDetector_IsFullyInsideImbRange(const MqlRates &imb,
                                       const MqlRates &doji)
  {
   return (doji.high <= imb.high) && (doji.low >= imb.low);
  }

//+------------------------------------------------------------------+
//| CrtDetector_IsBareImb — приватный хелпер.                        |
//|                                                                  |
//|  Реализация задачи 2.1 спеки bare-imbalance-pattern. Проверяет   |
//|  bare-условие «нет тени IMB со стороны Doji» как чистую функцию  |
//|  от (imb, imbDir, wickTolerance) (Req 2.5, 10.2, 13.12).         |
//|                                                                  |
//|  При imbDir == 0 — ранний выход с false (Req 2.6, 3.7): без      |
//|  определённого направления IMB bare-сторона не определена.       |
//|                                                                  |
//|  Формулы (Req 2.1, 2.2, 2.3, 2.4):                               |
//|    imbDir == -1  →  bareWick = min(imb.open, imb.close) - imb.low|
//|    imbDir == +1  →  bareWick = imb.high - max(imb.open, imb.close)|
//|    return (bareWick <= wickTolerance * |imb.close - imb.open|)   |
//|                                                                  |
//|  Стиль и масштаб допуска симметричны CrtDetector_IsBodyInsideBody|
//|  (Req 10.1): тот же префикс CrtDetector_*, тот же const double   |
//|  параметр допуска, тот же множитель MathAbs(imb.close-imb.open). |
//+------------------------------------------------------------------+
bool CrtDetector_IsBareImb(const MqlRates &imb,
                           const int       imbDir,
                           const double    wickTolerance)
  {
   if(imbDir == 0)                                          // Req 2.6, 3.7
      return false;

   double imbBody = MathAbs(imb.close - imb.open);
   double bareWick;
   if(imbDir == -1)                                         // Req 2.1 (BUY: нижняя сторона)
      bareWick = MathMin(imb.open, imb.close) - imb.low;
   else                                                     // Req 2.2 (SELL: верхняя сторона; imbDir == +1)
      bareWick = imb.high - MathMax(imb.open, imb.close);

   return (bareWick <= wickTolerance * imbBody);            // Req 2.3, 2.4
  }

//+------------------------------------------------------------------+
//| CrtDetectorDetect — публичная функция модуля.                    |
//|                                                                  |
//|  Реализация задачи 1.3 спеки crt-push-modularization. Полный     |
//|  контракт шагов зафиксирован в шапке файла; здесь — буквальная   |
//|  трансляция в код. Логика и порядок проверок побитово            |
//|  эквивалентны CheckPatternOnTF из crt-push_v7.2.mq5 (Req 15.1,   |
//|  19.12) с сохранением точных операторов сравнения (`>=` / `<` /  |
//|  `<=` / `>`).                                                    |
//+------------------------------------------------------------------+
void CrtDetectorDetect(const MqlRates          &prev,
                       const MqlRates          &imb,
                       const MqlRates          &doji,
                       const CrtDetectorConfig &config,
                       const CrtPatternFlags   &flags,
                       CrtSignal               &signal)
  {
   //--- Step 1: безусловная инициализация signal (Req 1.5).
   signal.detected    = false;
   signal.patternName = "";
   signal.imbDir      = 0;
   signal.isFVG       = false;

   //--- Step 2: валидация диапазонов config (Req 1.6).
   if(!CrtDetector_IsConfigInRange(config))
      return;

   //--- Step 3: базовые фильтры IMB и Doji (Req 2.1..2.6).
   double imbRange  = imb.high  - imb.low;
   if(imbRange <= 0.0)                                                 // Req 2.1
      return;
   double dojiRange = doji.high - doji.low;
   if(dojiRange <= 0.0)                                                // Req 2.2
      return;

   double imbBody = MathAbs(imb.close - imb.open);
   if(imbBody / imbRange < config.ImbBodyRatio)                        // Req 2.3
      return;

   if(imb.close > imb.open)                                            // Req 2.4
      signal.imbDir =  1;
   else if(imb.close < imb.open)                                       // Req 2.5
      signal.imbDir = -1;

   double dojiBody = MathAbs(doji.close - doji.open);
   if(dojiBody / dojiRange >= config.DojiThreshold)                    // Req 2.6
      return;

   //--- Step 4: signal.isFVG (Req 5.6, 5.7, 5.8, 5.9, 19.8).
   //   Вычисляется до фильтров сопоставления и не зависит от flags —
   //   это гарантирует «isFVG не зависит от Alert-флагов» (Req 5.8).
   signal.isFVG = CrtDetector_HasFVG(prev, doji, signal.imbDir);

   //--- Step 5: фильтры сопоставления Doji ↔ IMB (Req 3.1..3.5).
   if(imbBody <= 0.0)                                                  // Req 3.1 (защита от ÷0)
      return;
   if(dojiBody / imbBody >= config.DojiToImbSizeRatio)                 // Req 3.2
      return;
   if(dojiRange >= imbRange * config.DojiToImbRangeRatio)              // Req 3.3
      return;
   if(MathAbs(doji.open - imb.close) > config.OpenTolerance * imbBody) // Req 3.4
      return;
   double dojiBodyLo = MathMin(doji.open, doji.close);
   double dojiBodyHi = MathMax(doji.open, doji.close);
   if(!(dojiBodyLo > imb.low && dojiBodyHi < imb.high))                // Req 3.5
      return;

   //--- Step 6: insideBody (Req 4.9).
   bool insideBody = CrtDetector_IsBodyInsideBody(imb, doji, config.OpenTolerance);

   //--- Step 7: ветка breakout (Req 4.1..4.4, 5.1, 5.2; Req 3.1..3.8,
   //    4.1..4.3, 9.1, 9.2 спеки bare-imbalance-pattern).
   if(CrtDetector_HasBreakout(imb, doji, signal.imbDir))
     {
      //--- Step 7a: приоритетная bare-проверка (Req 3.1, 3.2, 4.2
      //    спеки bare-imbalance-pattern). Гейтинг через
      //    flags.AlertBareImbalance проверяется первым операндом —
      //    короткое замыкание `&&` гарантирует, что при выключенном
      //    флаге CrtDetector_IsBareImb НЕ вызывается, а поле
      //    config.BareImbWickTolerance НЕ читается (Req 12.2, что
      //    даёт побитовую эквивалентность с pre-spec, Req 4.1).
      //
      //    bare-условие имеет приоритет над выбором TrueRB/InsideWick:
      //    при выполнении имя "bareImbalance" замещает классические
      //    имена независимо от flags.AlertTrueRB / flags.AlertInsideWick
      //    (Req 4.2). Также bare-замещение НЕ зависит от insideBody
      //    (Req 13.14): тело Doji может быть как внутри тела IMB, так
      //    и снаружи — в обоих случаях имя одно и то же.
      if(flags.AlertBareImbalance &&
         CrtDetector_IsBareImb(imb, signal.imbDir, config.BareImbWickTolerance))
        {
         signal.patternName = "bareImbalance";                         // Req 3.1, 4.2
         signal.detected    = true;                                    // Req 3.1
         return;
        }

      //--- Step 7b: существующая логика TrueRB/InsideWick (Req 3.3,
      //    4.3, 9.1 спеки bare-imbalance-pattern; поведение pre-spec
      //    без изменений — Req 11.3, 11.5).
      if(insideBody)
        {
         if(!flags.AlertTrueRB)                                        // Req 5.1
            return;
         signal.patternName = "TrueRB";
        }
      else
        {
         if(!flags.AlertInsideWick)                                    // Req 5.2
            return;
         signal.patternName = "InsideWick";
        }
      signal.detected = true;                                          // Req 5.5
      return;
     }

   //--- Step 8: ветка ghost (Req 4.5..4.7, 5.3, 5.4).
   //   Активируется только если ветка breakout не сработала —
   //   обеспечивает инвариант «ghost ⇔ NOT breakout» (Req 19.5).
   if(CrtDetector_IsFullyInsideImbRange(imb, doji))
     {
      if(insideBody)
        {
         if(!flags.AlertGhostTrueRB)                                   // Req 5.3
            return;
         signal.patternName = "ghostTrueRB";
        }
      else
        {
         if(!flags.AlertGhostInsideWick)                               // Req 5.4
            return;
         signal.patternName = "ghostInsideWick";
        }
      signal.detected = true;                                          // Req 5.5
      return;
     }

   //--- Step 9: ни одна ветка не активна (Req 4.8).
   //   signal.detected уже false, signal.patternName уже пуст —
   //   функция просто завершается. signal.imbDir и signal.isFVG
   //   сохраняют значения, установленные в шагах 3 и 4.
  }

#endif // CRTDETECTOR_MQH
//+------------------------------------------------------------------+
