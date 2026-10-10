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
//|  Объявляет глобальные g_sessions_cfg / g_sessions_state; бот     |
//|  вызывает SessionsSetup() в OnInit и SessionsOnTick() /          |
//|  SessionsIsPreClose() / SessionsIsBoundary() / SessionsUtcNow()  |
//|  в OnTick. Имена входных параметров прежние — старые настройки   |
//|  тестера работают.                                               |
//+------------------------------------------------------------------+
#ifndef SESSIONINPUTS_MQH
#define SESSIONINPUTS_MQH

#include "SessionFilter.mqh"

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
input bool UseSessionFilter     = true;  // Окно у перерыва Америка/Азия
input int  AmericanCloseHour    = 21;    // Час закрытия Американской (серв.)
input int  AmericanCloseMinute  = 0;     // Минута закрытия Американской
input int  AsianOpenHour        = 0;     // Час открытия Азиатской (серв.)
input int  AsianOpenMinute      = 0;     // Минута открытия Азиатской
input int  SessionWindowMinutes = SESSION_DEFAULT_WINDOW_MINUTES; // Окно блокировки вокруг границы, мин

input group "── Selected Sessions Filter ──"
// Выбор торговых сессий (Asian/London/NewYork) в UTC.
// При UseSelectedSessions=false работает только окно у перерыва выше.
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

input int           SessionGmtOffsetHours       = 0;        // GMT-смещение сервера, ч [-12,14] (в тестере используется всегда; Exness = 0)
input ENUM_DST_MODE SessionDstMode              = DST_AUTO; // Режим DST

input bool          CloseOnSessionExit          = SESSION_DEFAULT_CLOSE_ON_EXIT; // Закрывать позиции на выходе
input bool          UseBrokerSessionsAsFallback = false; // Брокерские сессии как fallback

// Состояние фильтра. Часы — TimeCurrent() (в тестере детерминировано).
SessionsConfig g_sessions_cfg;
SessionsState  g_sessions_state;

//+------------------------------------------------------------------+
//| SessionsSetup — заполнить конфигурацию из входных параметров,    |
//| инициализировать фильтр и вывести сводку в журнал. Возвращает    |
//| false, если границы выбранных сессий невалидны (выбор сессий в   |
//| этом случае выключается).                                        |
//+------------------------------------------------------------------+
bool SessionsSetup()
  {
   MqlDateTime srv;
   TimeToStruct(TimeTradeServer(), srv);
   PrintFormat("🕐 Серверное время: %04d.%02d.%02d %02d:%02d:%02d",
               srv.year, srv.mon, srv.day, srv.hour, srv.min, srv.sec);
   g_sessions_cfg.useSelected    = UseSelectedSessions;
   g_sessions_cfg.asian          = UseAsianSession;
   g_sessions_cfg.london         = UseLondonSession;
   g_sessions_cfg.ny             = UseNewYorkSession;
   g_sessions_cfg.asianStartSec  = (long)AsianStartHour  * 3600 + (long)AsianStartMinute  * 60;
   g_sessions_cfg.asianEndSec    = (long)AsianEndHour    * 3600 + (long)AsianEndMinute    * 60;
   g_sessions_cfg.londonStartSec = (long)LondonStartHour * 3600 + (long)LondonStartMinute * 60;
   g_sessions_cfg.londonEndSec   = (long)LondonEndHour   * 3600 + (long)LondonEndMinute   * 60;
   g_sessions_cfg.nyStartSec     = (long)NYStartHour     * 3600 + (long)NYStartMinute     * 60;
   g_sessions_cfg.nyEndSec       = (long)NYEndHour       * 3600 + (long)NYEndMinute       * 60;
   g_sessions_cfg.gmtOffsetSec   = (long)SessionGmtOffsetHours * 3600;
   g_sessions_cfg.dstMode        = SessionDstMode;
   g_sessions_cfg.brokerFallback = UseBrokerSessionsAsFallback;
   g_sessions_cfg.useBreakWindow = UseSessionFilter;
   g_sessions_cfg.breakCloseSec  = (long)AmericanCloseHour * 3600 + (long)AmericanCloseMinute * 60;
   g_sessions_cfg.breakOpenSec   = (long)AsianOpenHour     * 3600 + (long)AsianOpenMinute     * 60;
   g_sessions_cfg.windowMinutes  = SessionWindowMinutes;
   const bool ok = SessionsInit(g_sessions_cfg, g_sessions_state);

   if(!UseSessionFilter)
      Print("⏰ Окно у перерыва выключено");
   else
      PrintFormat("%s Окно у перерыва: %s | закр. Америки %02d:%02d | откр. Азии %02d:%02d (сервер) | ±%d мин",
                  g_sessions_state.breakFromBroker ? "✅" : "⚠️",
                  g_sessions_state.breakFromBroker ? "по расписанию брокера" : "вручную (часы сервера)",
                  (int)(g_sessions_state.closeSec / 3600), (int)((g_sessions_state.closeSec % 3600) / 60),
                  (int)(g_sessions_state.openSec / 3600), (int)((g_sessions_state.openSec % 3600) / 60),
                  SessionWindowMinutes);
   if(!g_sessions_cfg.useSelected)
     {
      Print("⏰ Выбор сессий выключен");
      return ok;
     }
   string selected = "";
   if(UseAsianSession)   selected += (StringLen(selected) > 0 ? "," : "") + "Asian";
   if(UseLondonSession)  selected += (StringLen(selected) > 0 ? "," : "") + "London";
   if(UseNewYorkSession) selected += (StringLen(selected) > 0 ? "," : "") + "NewYork";
   if(StringLen(selected) == 0) selected = "none";
   const SessionsConfig c = g_sessions_cfg;
   PrintFormat("⏰ Выбор сессий: %s | UTC%+.2f ч | Asian=%02d:%02d-%02d:%02d | London=%02d:%02d-%02d:%02d | NY=%02d:%02d-%02d:%02d",
               selected, (double)g_sessions_state.offsetSec / 3600.0,
               (int)(c.asianStartSec / 3600), (int)((c.asianStartSec % 3600) / 60),
               (int)(c.asianEndSec / 3600), (int)((c.asianEndSec % 3600) / 60),
               (int)(c.londonStartSec / 3600), (int)((c.londonStartSec % 3600) / 60),
               (int)(c.londonEndSec / 3600), (int)((c.londonEndSec % 3600) / 60),
               (int)(c.nyStartSec / 3600), (int)((c.nyStartSec % 3600) / 60),
               (int)(c.nyEndSec / 3600), (int)((c.nyEndSec % 3600) / 60));
   return ok;
  }

//+------------------------------------------------------------------+
//| Единый API сессий для OnTick.                                    |
//|   SessionsOnTick()     — один раз в начале тика: TRADING / первый |
//|                          тик после выхода (закрыть позиции, если  |
//|                          CloseOnSessionExit) / вне сессий;        |
//|   SessionsIsPreClose() — последние минуты перед закрытием Америки:|
//|                          закрыть позиции;                         |
//|   SessionsIsBoundary() — окно у перерыва: не входить;             |
//|   SessionsUtcNow()     — UTC, секунда суток (для журнала).        |
//+------------------------------------------------------------------+
ENUM_SESSION_STATE SessionsOnTick()     { return SessionsUpdate(g_sessions_cfg, g_sessions_state); }
bool               SessionsIsPreClose() { return SessionsInPreClose(g_sessions_cfg, g_sessions_state); }
bool               SessionsIsBoundary() { return SessionsInBreakWindow(g_sessions_cfg, g_sessions_state); }
long               SessionsUtcNow()     { return g_sessions_state.utcSec; }

#endif // SESSIONINPUTS_MQH
//+------------------------------------------------------------------+
