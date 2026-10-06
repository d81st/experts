//+------------------------------------------------------------------+
//|                                                  PushNotifier.mqh|
//|                                                                  |
//|  Push Notifier — формирование и отправка push-уведомлений о      |
//|  распознанном CRT-сигнале, обновление HUD через Comment,         |
//|  печать диагностики через Print.                                 |
//|                                                                  |
//|  Feature: crt-push-modularization                                |
//|  Spec:    .kiro/specs/crt-push-modularization/design.md          |
//|           (Components and Interfaces → 3. Include/PushNotifier)  |
//|                                                                  |
//|  This header declares:                                           |
//|   - прототип публичной функции модуля:                           |
//|       PushNotifierSendCrt        (Req 8.1..8.5, 9.1..9.3)        |
//|   - прототипы приватных хелперов с префиксом PushNotifier_*      |
//|     (Req 17.9):                                                  |
//|       PushNotifier_BuildMessage      (Req 8.2)                   |
//|       PushNotifier_PrintDiagnostics  (Req 9.2)                   |
//|       PushNotifier_UpdateHud         (Req 9.1)                   |
//|                                                                  |
//|  Модуль соответствует требованиям модульной изоляции             |
//|  (Req 17.3, 17.4, 17.5, 17.6, 17.9): include-guard уникален,     |
//|  все необходимые данные передаются через параметры функций,      |
//|  `input`-объявления в этом файле отсутствуют, модуль не          |
//|  обращается к глобальным переменным EA (Req 9.3, 17.4),          |
//|  глобальное состояние на уровне модуля также отсутствует —       |
//|  PushNotifierSendCrt является функцией от своих аргументов в     |
//|  набор побочных эффектов (SendNotification, Comment, Print).     |
//|                                                                  |
//|  Канал нотификации — только `SendNotification` (Req 18.5).       |
//|  Email/Telegram/иные каналы вне скоупа этой спеки.               |
//|                                                                  |
//|  Тела функций реализуются в задаче 4.2 этой же спеки.            |
//+------------------------------------------------------------------+
#ifndef PUSHNOTIFIER_MQH
#define PUSHNOTIFIER_MQH

//+------------------------------------------------------------------+
//| Публичный интерфейс PushNotifier (Module 3).                     |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| PushNotifierSendCrt — сформировать и отправить push-уведомление  |
//| о распознанном CRT-сигнале, обновить HUD и напечатать            |
//| диагностику.                                                     |
//|                                                                  |
//|  Сигнатура (Req 8.1): ровно восемь параметров, все входные       |
//|  (модуль не возвращает результат — нотификация это побочный      |
//|  эффект). Строковые параметры и MqlRates передаются как          |
//|  const &, скалярные — по значению.                               |
//|                                                                  |
//|  patternName — имя распознанного паттерна ∈ {"TrueRB",           |
//|                  "InsideWick", "ghostTrueRB", "ghostInsideWick"} |
//|                  (см. CrtSignal.patternName в CrtDetector.mqh).  |
//|  direction   — направление сигнала, строка "BUY" или "SELL".    |
//|                  Формируется вызывающей стороной из              |
//|                  signal.imbDir (+1 → "SELL", -1 → "BUY"; см.     |
//|                  Req 11.7 для Crt_Push_V8 и Req 13.7 для         |
//|                  мигрированного Crt_Bot).                        |
//|  symbol      — торговый инструмент (обычно `_Symbol` на стороне  |
//|                  вызова). Модуль не читает `_Symbol`             |
//|                  самостоятельно — все данные приходят            |
//|                  параметрами (Req 9.3, 17.4).                    |
//|  tfStr       — человеко-читаемое имя ТФ ("M1".."MN"),            |
//|                  сформированное через                            |
//|                  MultiTfSchedulerTFToString вызывающей           |
//|                  стороной (Req 6.7, 15.2). PushNotifier не       |
//|                  зависит от MultiTfScheduler и принимает         |
//|                  готовую строку, чтобы остаться развязанным.    |
//|  dojiTime    — время открытия Doji-свечи (`rates[1].time`);      |
//|                  используется в HUD (Req 9.1).                   |
//|  isFVG       — наличие FVG между prev и doji; добавляет          |
//|                  отметку " + FVG" в сообщение и HUD              |
//|                  (Req 8.2, 9.1). Пробелы вокруг `+` обязательны  |
//|                  для поведенческой эквивалентности с             |
//|                  Crt_Push_V7 (Req 15.1).                         |
//|  imb         — свеча IMB (`rates[2]`); используется в            |
//|                  PushNotifier_PrintDiagnostics для расчёта       |
//|                  IMB body%, sizeRatio% и openDiff% (Req 9.2).    |
//|  doji        — свеча Doji (`rates[1]`); используется в           |
//|                  PushNotifier_PrintDiagnostics для расчёта       |
//|                  Doji body% и rangeRatio% (Req 9.2).             |
//|                                                                  |
//|  Контракт реализации (полный порядок шагов фиксируется в         |
//|  задаче 4.2 этой спеки):                                         |
//|                                                                  |
//|   1. Печать диагностики через                                    |
//|      PushNotifier_PrintDiagnostics (Req 9.2). Выполняется до    |
//|      отправки уведомления, чтобы трассировка причин была         |
//|      доступна даже при сбое SendNotification.                    |
//|   2. Формирование текста сообщения через                         |
//|      PushNotifier_BuildMessage по шаблону                        |
//|      "<patternName>[ + FVG] <direction> | <symbol> | TF:         |
//|      <tfStr>" (Req 8.2). Шаблон побитово копирует формат         |
//|      Crt_Push_V7 — менять нельзя (Req 15.1).                     |
//|   3. Отправка через SendNotification(msg) (Req 8.3):             |
//|        - При возврате false: вывод через PrintFormat сообщения   |
//|          вида "❌ SendNotification ошибка: %d" с GetLastError()  |
//|          (Req 8.4).                                              |
//|        - При возврате true: вывод через PrintFormat              |
//|          подтверждения "🔔 Отправлено: <msg>" (Req 8.5).         |
//|   4. Обновление HUD через PushNotifier_UpdateHud (Req 9.1).      |
//|      Версия в HUD-строке — "v8.1" (см. контракт                  |
//|      PushNotifier_UpdateHud ниже).                               |
//|                                                                  |
//|  Чистота от EA-глобалов и input-переменных (Req 9.3, 17.4):      |
//|  модуль НЕ читает `_Symbol`, НЕ читает `input`-переменные        |
//|  Crt_Push_V8 / Crt_Bot, НЕ обращается к каким-либо переменным    |
//|  на уровне файла или модуля. Все необходимые значения приходят   |
//|  через параметры. Это гарантирует, что модуль можно использовать |
//|  в любом советнике без скрытых зависимостей.                     |
//|                                                                  |
//|  Канал нотификации (Req 18.5): только `SendNotification`.        |
//|  SendMail / SendFTP / Telegram-каналы не используются.           |
//|                                                                  |
//|  Тело реализуется в задаче 4.2.                                  |
//+------------------------------------------------------------------+
void PushNotifierSendCrt(const string   &patternName,
                         const string   &direction,
                         const string   &symbol,
                         const string   &tfStr,
                         const datetime  dojiTime,
                         const bool      isFVG,
                         const MqlRates &imb,
                         const MqlRates &doji);

//+------------------------------------------------------------------+
//| Приватные хелперы модуля (префикс PushNotifier_*, Req 17.9).     |
//|                                                                  |
//|  Не входят в публичный API; используются только телом            |
//|  PushNotifierSendCrt. Префикс предотвращает коллизии с           |
//|  одноимёнными утилитами в EA-файлах и фиксирует                  |
//|  «module-private» семантику в имени.                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| PushNotifier_BuildMessage — формирует текст push-сообщения       |
//| (Req 8.2).                                                       |
//|                                                                  |
//|  Возвращает строку по шаблону:                                   |
//|                                                                  |
//|    StringFormat("%s%s %s | %s | TF: %s",                         |
//|                 patternName,                                     |
//|                 isFVG ? " + FVG" : "",                           |
//|                 direction,                                       |
//|                 symbol,                                          |
//|                 tfStr);                                          |
//|                                                                  |
//|  Замечание о пробелах: вставка " + FVG" с пробелами вокруг `+`   |
//|  — буквальная копия формата `fvgTag = isFVG ? " + FVG" : ""`     |
//|  из crt-push_v7.2.mq5. Любое изменение формата (например, "+FVG" |
//|  без пробелов) нарушит поведенческую эквивалентность с           |
//|  Crt_Push_V7 (Req 15.1).                                         |
//|                                                                  |
//|  Не модифицирует входные строки (const &, Req 17.4). Не имеет    |
//|  побочных эффектов — pure helper. Тело реализуется в             |
//|  задаче 4.2.                                                     |
//+------------------------------------------------------------------+
string PushNotifier_BuildMessage(const string &patternName,
                                 const string &direction,
                                 const string &symbol,
                                 const string &tfStr,
                                 const bool    isFVG);

//+------------------------------------------------------------------+
//| PushNotifier_PrintDiagnostics — печатает диагностическую        |
//| строку с пропорциями IMB и Doji через PrintFormat (Req 9.2).     |
//|                                                                  |
//|  Выводит поля (формулы — буквальная копия PrintDiagnostics из    |
//|  crt-push_v7.2.mq5; Req 15.1):                                   |
//|    - IMB тело%       = |imb.close - imb.open| /                  |
//|                          (imb.high - imb.low) * 100              |
//|    - Doji тело%      = |doji.close - doji.open| /                |
//|                          (doji.high - doji.low) * 100            |
//|    - sizeRatio%      = |doji.close - doji.open| /                |
//|                          |imb.close - imb.open| * 100            |
//|    - openDiff%       = |doji.open - imb.close| /                 |
//|                          |imb.close - imb.open| * 100            |
//|    - rangeRatio%     = (doji.high - doji.low) /                  |
//|                          (imb.high - imb.low) * 100              |
//|                                                                  |
//|  Защита от деления на ноль выполняется по тем же правилам, что   |
//|  и в v7.2. Формат строки и порядок полей сохраняются             |
//|  побитово — это часть наблюдаемого поведения и требуется         |
//|  Req 15.1.                                                       |
//|                                                                  |
//|  Не модифицирует входные данные (const &, Req 17.4). Побочный    |
//|  эффект — единственный вызов PrintFormat. Тело реализуется в     |
//|  задаче 4.2.                                                     |
//+------------------------------------------------------------------+
void PushNotifier_PrintDiagnostics(const string   &patternName,
                                   const string   &direction,
                                   const string   &symbol,
                                   const string   &tfStr,
                                   const MqlRates &imb,
                                   const MqlRates &doji);

//+------------------------------------------------------------------+
//| PushNotifier_UpdateHud — обновляет HUD на графике через         |
//| Comment (Req 9.1).                                               |
//|                                                                  |
//|  Формирует строку по шаблону:                                    |
//|                                                                  |
//|    StringFormat("RB+CRT Bot v8.1 | %s%s %s  %s [%s] @ %s",       |
//|                 patternName,                                     |
//|                 isFVG ? " + FVG" : "",                           |
//|                 direction,                                       |
//|                 symbol,                                          |
//|                 tfStr,                                           |
//|                 TimeToString(dojiTime,                           |
//|                              TIME_DATE | TIME_MINUTES));         |
//|                                                                  |
//|  и передаёт её в `Comment(...)`. Версия в префиксе HUD-строки    |
//|  обновлена на "v8.1" относительно Crt_Push_V7 ("v3.3") —         |
//|  это требование Req 9.1 (явная маркировка нового нотификатора    |
//|  для пользователя). Остальной формат идентичен Crt_Push_V7.      |
//|                                                                  |
//|  Не модифицирует входные данные (const &, Req 17.4). Побочный    |
//|  эффект — единственный вызов Comment. Тело реализуется в         |
//|  задаче 4.2.                                                     |
//+------------------------------------------------------------------+
void PushNotifier_UpdateHud(const string   &patternName,
                            const string   &direction,
                            const string   &symbol,
                            const string   &tfStr,
                            const datetime  dojiTime,
                            const bool      isFVG);

//+------------------------------------------------------------------+
//| Implementations                                                  |
//|                                                                  |
//|  Тела трёх приватных хелперов PushNotifier_* и публичной         |
//|  функции PushNotifierSendCrt — задача 4.2 спеки                  |
//|  crt-push-modularization.                                        |
//|                                                                  |
//|  Реализация выполняется в том же .mqh-файле, в соответствии со   |
//|  стилем существующих модулей Include/* (Req 17.6; см.            |
//|  TrendFilter.mqh / CrtDetector.mqh как канонические примеры).    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| PushNotifier_BuildMessage — приватный хелпер.                    |
//|                                                                  |
//|  Реализация задачи 4.2. Шаблон сообщения побитово эквивалентен   |
//|  формату из Crt_Push_V7 (см. `msg` в SendSignal в                |
//|  crt-push_v7.2.mq5) — Req 8.2, 15.1. Пробелы вокруг `+` в        |
//|  fvg-метке обязательны: без них наблюдаемый текст уведомления    |
//|  отличался бы от v7.2.                                           |
//|                                                                  |
//|  Чистая функция: побочных эффектов нет, входные строки не        |
//|  модифицируются (Req 17.4).                                      |
//+------------------------------------------------------------------+
string PushNotifier_BuildMessage(const string &patternName,
                                 const string &direction,
                                 const string &symbol,
                                 const string &tfStr,
                                 const bool    isFVG)
  {
   return StringFormat("%s%s %s | %s | TF: %s",
                       patternName,
                       isFVG ? " + FVG" : "",
                       direction,
                       symbol,
                       tfStr);
  }

//+------------------------------------------------------------------+
//| PushNotifier_PrintDiagnostics — приватный хелпер.                |
//|                                                                  |
//|  Реализация задачи 4.2. Формулы пропорций и формат               |
//|  PrintFormat-строки побитово эквивалентны PrintDiagnostics из    |
//|  crt-push_v7.2.mq5 (Req 9.2, 15.1). Защита от деления на ноль    |
//|  применена к каждой формуле для безопасного переиспользования    |
//|  модуля вне основного потока CrtDetectorDetect; в нормальном     |
//|  потоке (`signal.detected==true`) фильтры детектора гарантируют  |
//|  `imbBody > 0`, `imbRange > 0`, `dojiRange > 0`, поэтому         |
//|  guard'ы никогда не срабатывают и наблюдаемый вывод идентичен    |
//|  v7.2.                                                           |
//|                                                                  |
//|  Побочный эффект — единственный вызов PrintFormat. Входные       |
//|  данные не модифицируются (const &, Req 17.4).                   |
//+------------------------------------------------------------------+
void PushNotifier_PrintDiagnostics(const string   &patternName,
                                   const string   &direction,
                                   const string   &symbol,
                                   const string   &tfStr,
                                   const MqlRates &imb,
                                   const MqlRates &doji)
  {
   double imbBody    = MathAbs(imb.close  - imb.open);
   double imbRange   = imb.high  - imb.low;
   double dojiBody   = MathAbs(doji.close - doji.open);
   double dojiRange  = doji.high - doji.low;

   double imbBodyPct    = (imbRange  > 0.0) ? imbBody  / imbRange  * 100.0 : 0.0;
   double dojiBodyPct   = (dojiRange > 0.0) ? dojiBody / dojiRange * 100.0 : 0.0;
   double sizeRatioPct  = (imbBody   > 0.0) ? dojiBody / imbBody   * 100.0 : 0.0;
   double openDiffPct   = (imbBody   > 0.0) ? MathAbs(doji.open - imb.close) / imbBody * 100.0 : 0.0;
   double rangeRatioPct = (imbRange  > 0.0) ? dojiRange / imbRange * 100.0 : 0.0;

   PrintFormat("📊 %s %s | %s [%s] | IMB тело=%.0f%% | Doji тело=%.0f%% размер=%.0f%%_от_IMB | Open≈Close Δ=%.1f%% | Диап.Doji/IMB=%.0f%%",
               patternName, direction, symbol, tfStr,
               imbBodyPct, dojiBodyPct, sizeRatioPct, openDiffPct, rangeRatioPct);
  }

//+------------------------------------------------------------------+
//| PushNotifier_UpdateHud — приватный хелпер.                       |
//|                                                                  |
//|  Реализация задачи 4.2. Формат HUD-строки идентичен Crt_Push_V7  |
//|  (см. Comment(...) в SendSignal в crt-push_v7.2.mq5), за         |
//|  исключением версии: "v3.3" → "v8.1" (Req 9.1). Двойной пробел   |
//|  между direction и symbol — буквальная копия v7.2 (не опечатка). |
//|                                                                  |
//|  Побочный эффект — единственный вызов Comment. Входные данные    |
//|  не модифицируются (const &, Req 17.4).                          |
//+------------------------------------------------------------------+
void PushNotifier_UpdateHud(const string   &patternName,
                            const string   &direction,
                            const string   &symbol,
                            const string   &tfStr,
                            const datetime  dojiTime,
                            const bool      isFVG)
  {
   Comment(StringFormat("RB+CRT Bot v8.1 | %s%s %s  %s [%s] @ %s",
                        patternName,
                        isFVG ? " + FVG" : "",
                        direction,
                        symbol,
                        tfStr,
                        TimeToString(dojiTime, TIME_DATE | TIME_MINUTES)));
  }

//+------------------------------------------------------------------+
//| PushNotifierSendCrt — публичная функция модуля.                  |
//|                                                                  |
//|  Реализация задачи 4.2. Порядок шагов фиксирован контрактом      |
//|  в шапке файла:                                                  |
//|    1. диагностика  (Req 9.2)                                     |
//|    2. SendNotification + лог результата (Req 8.3, 8.4, 8.5)      |
//|    3. HUD          (Req 9.1)                                     |
//|                                                                  |
//|  Канал нотификации — только SendNotification (Req 18.5).         |
//|  Модуль не читает `_Symbol`, не обращается к input-переменным    |
//|  EA и не имеет глобального состояния (Req 9.3, 17.4).            |
//+------------------------------------------------------------------+
void PushNotifierSendCrt(const string   &patternName,
                         const string   &direction,
                         const string   &symbol,
                         const string   &tfStr,
                         const datetime  dojiTime,
                         const bool      isFVG,
                         const MqlRates &imb,
                         const MqlRates &doji)
  {
   PushNotifier_PrintDiagnostics(patternName, direction, symbol, tfStr, imb, doji);

   string msg = PushNotifier_BuildMessage(patternName, direction, symbol, tfStr, isFVG);

   if(!SendNotification(msg))
      PrintFormat("❌ SendNotification ошибка: %d", GetLastError());
   else
      PrintFormat("🔔 Отправлено: %s", msg);

   PushNotifier_UpdateHud(patternName, direction, symbol, tfStr, dojiTime, isFVG);
  }

#endif // PUSHNOTIFIER_MQH
//+------------------------------------------------------------------+
