//+------------------------------------------------------------------+
//|                                                SessionInputs.mqh |
//|                                                                  |
//|  Общие входные параметры сессионных фильтров и их настройка      |
//|  в OnInit для всех ботов.                                        |
//|                                                                  |
//|  Значения по умолчанию, которые отличаются у ботов, задаются     |
//|  макросами ДО подключения файла:                                 |
//|    SESSION_DEFAULT_WINDOW_MINUTES  — окно у стыка сессий, мин    |
//|    SESSION_DEFAULT_SELECTED        — выбор сессий включён        |
//|    SESSION_DEFAULT_LONDON          — торговать в Лондон          |
//|    SESSION_DEFAULT_CLOSE_ON_EXIT   — закрывать при выходе        |
//|                                                                  |
//|  Объявляет глобальные g_session_cfg/state и                      |
//|  g_selected_cfg/state; бот вызывает SessionsSetup() в OnInit.    |
//+------------------------------------------------------------------+
#ifndef SESSIONINPUTS_MQH
#define SESSIONINPUTS_MQH

#include "../SessionFilter.mqh"

#ifndef SESSION_DEFAULT_WINDOW_MINUTES
#define SESSION_DEFAULT_WINDOW_MINUTES 5
#endif
#ifndef SESSION_DEFAULT_SELECTED
#define SESSION_DEFAULT_SELECTED true
#endif
#ifndef SESSION_DEFAULT_LONDON
#define SESSION_DEFAULT_LONDON true
#endif
#ifndef SESSION_DEFAULT_CLOSE_ON_EXIT
#define SESSION_DEFAULT_CLOSE_ON_EXIT true
#endif

input group "── Сессионный фильтр ──"
input bool UseSessionFilter     = true;  // Окно у стыка Америка/Азия (legacy)
input int  AmericanCloseHour    = 21;    // Час закрытия Американской (серв.)
input int  AmericanCloseMinute  = 0;     // Минута закрытия Американской
input int  AsianOpenHour        = 0;     // Час открытия Азиатской (серв.)
input int  AsianOpenMinute      = 0;     // Минута открытия Азиатской
input int  SessionWindowMinutes = SESSION_DEFAULT_WINDOW_MINUTES; // Окно блокировки вокруг границы, мин

input group "── Selected Sessions Filter ──"
// Выбор торговых сессий (Asian/London/NewYork) в UTC.
// При UseSelectedSessions=false работает только legacy-окно выше.
input bool          UseSelectedSessions         = SESSION_DEFAULT_SELECTED; // Включить выбор сессий
input bool          UseAsianSession             = false; // Торговать в Asian
input bool          UseLondonSession            = SESSION_DEFAULT_LONDON; // Торговать в London
input bool          UseNewYorkSession           = false; // Торговать в NewYork

input int           AsianStartHour              = 0;   // Asian start UTC [0,23]
input int           AsianStartMinute            = 0;   // Asian start UTC [0,59]
input int           AsianEndHour                = 9;   // Asian end   UTC [0,23]
input int           AsianEndMinute              = 0;   // Asian end   UTC [0,59]

input int           LondonStartHour             = 7;   // London start UTC [0,23]
input int           LondonStartMinute           = 0;   // London start UTC [0,59]
input int           LondonEndHour               = 16;  // London end   UTC [0,23]
input int           LondonEndMinute             = 0;   // London end   UTC [0,59]

input int           NYStartHour                 = 12;  // NewYork start UTC [0,23]
input int           NYStartMinute               = 0;   // NewYork start UTC [0,59]
input int           NYEndHour                   = 21;  // NewYork end   UTC [0,23]
input int           NYEndMinute                 = 0;   // NewYork end   UTC [0,59]

input int           SessionGmtOffsetHours       = 0;        // GMT offset, ч [-12,14]
input ENUM_DST_MODE SessionDstMode              = DST_AUTO; // Режим DST

input bool          CloseOnSessionExit          = SESSION_DEFAULT_CLOSE_ON_EXIT; // Закрывать позиции на выходе
input bool          UseBrokerSessionsAsFallback = false; // Брокерские сессии как fallback

// Состояние фильтров. SessionFilter использует TimeCurrent(): в live
// разница с TimeTradeServer() в пределах секунды, в тестере детерминирован.
SessionConfig          g_session_cfg;
SessionState           g_session_state;
SelectedSessionsConfig g_selected_cfg;
SelectedSessionsState  g_selected_state;

//+------------------------------------------------------------------+
//| SessionsSetup — заполнить конфигурации из входных параметров,    |
//| инициализировать оба фильтра и вывести сводку в журнал.          |
//| Возвращает false, если выбор сессий включён, но конфигурация     |
//| невалидна (фильтр в этом случае отключается модулем).            |
//+------------------------------------------------------------------+
bool SessionsSetup()
  {
   MqlDateTime srv;
   TimeToStruct(TimeTradeServer(), srv);
   PrintFormat("🕐 Серверное время: %04d.%02d.%02d %02d:%02d:%02d",
               srv.year, srv.mon, srv.day, srv.hour, srv.min, srv.sec);

   //--- legacy-окно у стыка Америка/Азия
   g_session_cfg.enabled             = UseSessionFilter;
   g_session_cfg.americanCloseHour   = AmericanCloseHour;
   g_session_cfg.americanCloseMinute = AmericanCloseMinute;
   g_session_cfg.asianOpenHour       = AsianOpenHour;
   g_session_cfg.asianOpenMinute     = AsianOpenMinute;
   g_session_cfg.windowMinutes       = SessionWindowMinutes;
   // state инициализируется всегда: при UseSessionFilter=false проверки возвращают false
   const bool autoDetected = SessionInit(g_session_cfg, g_session_state);

   if(!UseSessionFilter)
      Print("⏰ Сессионный фильтр выключен");
   else if(autoDetected)
     {
      long am = 0, as = 0;
      SessionGetEffective(g_session_cfg, g_session_state, am, as);
      PrintFormat("✅ Сессии: АВТО | Закр. Амер: %02d:%02d | Откр. Азия: %02d:%02d | Окно: ±%d мин",
                  (int)(am / 3600), (int)((am % 3600) / 60),
                  (int)(as / 3600), (int)((as % 3600) / 60), SessionWindowMinutes);
     }
   else
     {
      PrintFormat("⚠️  Сессии: РУЧНОЙ | Закр. Амер: %02d:%02d | Откр. Азия: %02d:%02d | Окно: ±%d мин",
                  AmericanCloseHour, AmericanCloseMinute,
                  AsianOpenHour, AsianOpenMinute, SessionWindowMinutes);
      Print("⚠️  Укажите часы в СЕРВЕРНОМ времени брокера.");
     }

   //--- выбор сессий (UTC): часы × 3600 + минуты × 60 = секунды суток
   g_selected_cfg.enabled                     = UseSelectedSessions;
   g_selected_cfg.useAsian                    = UseAsianSession;
   g_selected_cfg.useLondon                   = UseLondonSession;
   g_selected_cfg.useNewYork                  = UseNewYorkSession;
   g_selected_cfg.asianStartSec               = (long)AsianStartHour  * 3600 + (long)AsianStartMinute  * 60;
   g_selected_cfg.asianEndSec                 = (long)AsianEndHour    * 3600 + (long)AsianEndMinute    * 60;
   g_selected_cfg.londonStartSec              = (long)LondonStartHour * 3600 + (long)LondonStartMinute * 60;
   g_selected_cfg.londonEndSec                = (long)LondonEndHour   * 3600 + (long)LondonEndMinute   * 60;
   g_selected_cfg.nyStartSec                  = (long)NYStartHour     * 3600 + (long)NYStartMinute     * 60;
   g_selected_cfg.nyEndSec                    = (long)NYEndHour       * 3600 + (long)NYEndMinute       * 60;
   g_selected_cfg.gmtOffsetSeconds            = (long)SessionGmtOffsetHours * 3600;
   g_selected_cfg.dstMode                     = SessionDstMode;
   g_selected_cfg.closeOnSessionExit          = CloseOnSessionExit;
   g_selected_cfg.useBrokerSessionsAsFallback = UseBrokerSessionsAsFallback;
   // SelectedSessionsInit при невалидном cfg сам печатает причину и сбрасывает state
   const bool selectedOk = SelectedSessionsInit(g_selected_cfg, g_selected_state);

   if(!UseSelectedSessions)
     {
      Print("⏰ Selected sessions filter OFF");
      return true;
     }
   if(!selectedOk)
     {
      Print("❌ Selected sessions filter: невалидная конфигурация — фильтр отключён");
      return false;
     }

   string selected = "";
   if(UseAsianSession)   selected += (StringLen(selected) > 0 ? "," : "") + "Asian";
   if(UseLondonSession)  selected += (StringLen(selected) > 0 ? "," : "") + "London";
   if(UseNewYorkSession) selected += (StringLen(selected) > 0 ? "," : "") + "NewYork";
   if(StringLen(selected) == 0) selected = "none";

   long asS = 0, asE = 0, loS = 0, loE = 0, nyS = 0, nyE = 0;
   SelectedSessionsGetEffective(g_selected_cfg, g_selected_state, asS, asE, loS, loE, nyS, nyE);
   PrintFormat("⏰ Selected sessions ON | sessions=%s | gmt=%+.2fh | "
               "Asian=%02d:%02d-%02d:%02d | London=%02d:%02d-%02d:%02d | NY=%02d:%02d-%02d:%02d",
               selected, (double)g_selected_state.effectiveGmtOffsetSec / 3600.0,
               (int)(asS / 3600), (int)((asS % 3600) / 60), (int)(asE / 3600), (int)((asE % 3600) / 60),
               (int)(loS / 3600), (int)((loS % 3600) / 60), (int)(loE / 3600), (int)((loE % 3600) / 60),
               (int)(nyS / 3600), (int)((nyS % 3600) / 60), (int)(nyE / 3600), (int)((nyE % 3600) / 60));
   return true;
  }

#endif // SESSIONINPUTS_MQH
//+------------------------------------------------------------------+
