//+------------------------------------------------------------------+
//|                                                crt-push_v8.1.mq5 |
//|   RB+CRT Notification Bot v8.1                                   |
//|   Multi-TF | модульная архитектура                               |
//+------------------------------------------------------------------+
//
//  ─── АРХИТЕКТУРА ──────────────────────────────────────────────────
//
//  Тонкий оркестратор поверх трёх stateless-модулей:
//    Include/Levels/CrtDetector.mqh      — чистая функция детекции паттерна
//    Include/Notify/MultiTfScheduler.mqh — управление активным набором ТФ,
//                                   антидубль по бару, GlobalVariable
//    Include/Notify/PushNotifier.mqh     — формирование сообщения, HUD,
//                                   диагностика, SendNotification
//
//  ─── ЛОГИКА ПАТТЕРНОВ ─────────────────────────────────────────────
//
//  Свечи: [3]=prev, [2]=IMB, [1]=Doji
//
//  ── Классические (пробой экстремума тенью Doji):
//    TrueRB     — пробой + тело Doji строго внутри ТЕЛА IMB
//    InsideWick — пробой + тело Doji в диапазоне IMB, но вне тела
//
//  ── Ghost (Doji полностью внутри диапазона IMB, пробоя нет):
//    ghostTrueRB     — тело Doji строго внутри ТЕЛА IMB
//    ghostInsideWick — тело Doji в диапазоне IMB, но вне тела
//
//  ── FVG (суффикс " + FVG" в уведомлении):
//    Бычья IMB:    prev.high < doji.low  — незаполненный гэп
//    Медвежья IMB: prev.low  > doji.high — незаполненный гэп
//
//  ── Направление сигнала:
//    Бычья IMB   (close > open) → SELL
//    Медвежья IMB (close < open) → BUY
//
//+------------------------------------------------------------------+
#property strict
#property description "RB+CRT Notification Bot v8.1 | Multi-TF | модульная архитектура"

#include "Include/Levels/CrtDetector.mqh"
#include "Include/Notify/MultiTfScheduler.mqh"
#include "Include/Notify/PushNotifier.mqh"

input group "── Анализ ──"
input double ImbBodyRatio        = 0.40;  // Мин. доля тела IMB от полного диапазона
input double DojiThreshold       = 0.35;  // Макс. доля тела Doji от полного диапазона
input double DojiToImbSizeRatio  = 0.40;  // Макс. доля ТЕЛА Doji от тела IMB
input double DojiToImbRangeRatio = 1.00;  // Макс. доля ДИАПАЗОНА Doji от диапазона IMB (< 1.0 = строже)
input double OpenTolerance       = 0.01;
input double BareImbWickTolerance = 0.05; // Допуск "нет тени" IMB со стороны Doji (доля тела IMB; 0.0 = строгое равенство)

input group "── Таймфреймы ──"
input bool   Use_M1   = false;
input bool   Use_M5   = false;
input bool   Use_M15  = false;
input bool   Use_M30  = false;
input bool   Use_H1   = true;
input bool   Use_H4   = false;
input bool   Use_H8   = false;
input bool   Use_D1   = false;
input bool   Use_W1   = false;
input bool   Use_MN1  = false;

input group "── Паттерны (классика — с пробоем) ──"
input bool   AlertTrueRB        = true;
input bool   AlertInsideWick    = true;
input bool   AlertBareImbalance = true;

input group "── Паттерны (ghost — без пробоя) ──"
input bool   AlertGhostTrueRB     = true;
input bool   AlertGhostInsideWick = true;

//+------------------------------------------------------------------+
//| Глобальное состояние оркестратора (модули stateless)             |
//+------------------------------------------------------------------+
CrtDetectorConfig     g_detector_cfg;
CrtPatternFlags       g_detector_flags;
MultiTfSchedulerState g_sched_state;

//+------------------------------------------------------------------+
//| OnInit — инициализация модулей и проверка конфигурации           |
//+------------------------------------------------------------------+
int OnInit()
{
   // 1. Заполнить g_detector_cfg из input-параметров.
   g_detector_cfg.ImbBodyRatio        = ImbBodyRatio;
   g_detector_cfg.DojiThreshold       = DojiThreshold;
   g_detector_cfg.DojiToImbSizeRatio  = DojiToImbSizeRatio;
   g_detector_cfg.DojiToImbRangeRatio = DojiToImbRangeRatio;
   g_detector_cfg.OpenTolerance       = OpenTolerance;
   g_detector_cfg.BareImbWickTolerance = BareImbWickTolerance;

   // 2. Заполнить g_detector_flags.
   g_detector_flags.AlertTrueRB          = AlertTrueRB;
   g_detector_flags.AlertInsideWick      = AlertInsideWick;
   g_detector_flags.AlertGhostTrueRB     = AlertGhostTrueRB;
   g_detector_flags.AlertGhostInsideWick = AlertGhostInsideWick;
   g_detector_flags.AlertBareImbalance   = AlertBareImbalance;

   // 3. Построить MultiTfSchedulerConfig из десяти Use_* флагов.
   MultiTfSchedulerConfig sched_cfg;
   sched_cfg.useM1  = Use_M1;
   sched_cfg.useM5  = Use_M5;
   sched_cfg.useM15 = Use_M15;
   sched_cfg.useM30 = Use_M30;
   sched_cfg.useH1  = Use_H1;
   sched_cfg.useH4  = Use_H4;
   sched_cfg.useH8  = Use_H8;
   sched_cfg.useD1  = Use_D1;
   sched_cfg.useW1  = Use_W1;
   sched_cfg.useMN1 = Use_MN1;

   if(!MultiTfSchedulerInit(sched_cfg, g_sched_state))
   {
      Alert("Не выбран ни один таймфрейм");
      return INIT_FAILED;
   }

   // 4. Сообщение об активных ТФ через Print.
   string activeList = "";
   const int activeCount = MultiTfSchedulerActiveCount(g_sched_state);
   for(int i = 0; i < activeCount; i++)
   {
      int tfIdx = MultiTfSchedulerActiveAt(g_sched_state, i);
      ENUM_TIMEFRAMES tf = MultiTfSchedulerTFEnum(tfIdx);
      if(StringLen(activeList) > 0) activeList += ", ";
      activeList += MultiTfSchedulerTFToString(tf);
   }
   PrintFormat("RB+CRT v8.1: активных ТФ %d → %s", activeCount, activeList);

   // 5. Предупреждение, если push-уведомления выключены в терминале.
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      Print("⚠ Push-уведомления отключены в терминале — сигналы не будут доставлены на устройство");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick — цикл по активным ТФ, детекция и отправка нотификаций    |
//+------------------------------------------------------------------+
void OnTick()
{
   const int activeCount = MultiTfSchedulerActiveCount(g_sched_state);
   for(int i = 0; i < activeCount; i++)
   {
      const int tfIdx = MultiTfSchedulerActiveAt(g_sched_state, i);
      const ENUM_TIMEFRAMES tf = MultiTfSchedulerTFEnum(tfIdx);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(_Symbol, tf, 0, 4, rates) < 4) continue;

      if(!MultiTfSchedulerIsNewBar(g_sched_state, tfIdx, rates[0].time)) continue;

      const datetime lastSignalBar = MultiTfSchedulerLoadLastSignalBar(g_sched_state, tfIdx);
      if(rates[1].time == lastSignalBar) continue;

      CrtSignal signal;
      CrtDetectorDetect(rates[3], rates[2], rates[1],
                        g_detector_cfg, g_detector_flags, signal);
      if(!signal.detected) continue;

      const string direction = (signal.imbDir == +1) ? "SELL" : "BUY";
      const string tfStr     = MultiTfSchedulerTFToString(tf);
      PushNotifierSendCrt(signal.patternName, direction, _Symbol, tfStr,
                          rates[1].time, signal.isFVG, rates[2], rates[1]);
      MultiTfSchedulerSaveLastSignalBar(g_sched_state, tfIdx, rates[1].time);
   }
}

//+------------------------------------------------------------------+
//| OnDeinit — очистка HUD при выгрузке                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
