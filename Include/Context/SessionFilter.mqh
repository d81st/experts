//+------------------------------------------------------------------+
//|                                                SessionFilter.mqh |
//|                                                                  |
//|  Сессионный фильтр: одна конфигурация, одно состояние, одни      |
//|  часы (время сервера TimeCurrent; UTC = сервер − смещение).      |
//|  Два правила:                                                    |
//|   1. Выбранные сессии (Азия / Лондон / Нью-Йорк, границы в UTC): |
//|      торговать только внутри; первый тик после выхода —          |
//|      событие «вышли из сессии» (бот закрывает позиции).          |
//|   2. Окно у дневного перерыва (закрытие Америки / открытие Азии, |
//|      время сервера, от брокера или вручную): ±N минут — не       |
//|      входить; N минут перед закрытием — закрыть позиции.         |
//|  Каждое правило включается отдельно. Модуль не объявляет input   |
//|  и не держит глобалов: конфигурация и состояние — параметрами.   |
//|  До 2026-10 правила жили в двух независимых механизмах           |
//|  (SessionConfig / SelectedSessionsConfig) с разными часами.      |
//+------------------------------------------------------------------+
#ifndef SESSIONFILTER_MQH
#define SESSIONFILTER_MQH

#define SESSIONS_SEC_PER_DAY   86400L
#define SESSIONS_DST_ROUND_SEC 900L      // смещение UTC округляется до 15 минут
#define SESSIONS_DST_LOG_DELTA 1800L     // смена смещения ≥ 30 мин — запись в журнал
#define SESSIONS_GMT_MIN_SEC   (-43200L)
#define SESSIONS_GMT_MAX_SEC   (50400L)

//--- Режим смещения сервер → UTC.
//    DST_AUTO   — по TimeTradeServer() − TimeGMT() (в тестере TimeGMT — время сервера,
//                 поэтому там всегда берётся ручное смещение);
//    DST_MANUAL — ручное смещение gmtOffsetSec.
enum ENUM_DST_MODE
  {
   DST_AUTO   = 0,
   DST_MANUAL = 1
  };

//--- Результат SessionsUpdate для текущего тика.
enum ENUM_SESSION_STATE
  {
   SESSION_TRADING     = 0,   // внутри выбранных сессий (или правило выключено)
   SESSION_JUST_EXITED = 1,   // первый тик после выхода из сессий
   SESSION_OUTSIDE     = 2    // вне сессий
  };

//+------------------------------------------------------------------+
//| SessionsConfig — заполняется ботом в OnInit.                     |
//|   useSelected        — правило 1; asian/london/ny — какие сессии; |
//|   *StartSec/*EndSec  — границы, секунды суток UTC [0, 86399];    |
//|                        start > end — через полночь, start == end  |
//|                        — пустая сессия;                           |
//|   gmtOffsetSec, dstMode — смещение сервера относительно UTC;     |
//|   brokerFallback     — границы Лондона/НЙ из расписания брокера, |
//|                        если все шесть границ нулевые;             |
//|   useBreakWindow     — правило 2; breakCloseSec / breakOpenSec — |
//|                        ручные границы перерыва (сервер), если     |
//|                        брокер не отдал расписание; windowMinutes  |
//|                        — полуширина окна [1, 120].                |
//+------------------------------------------------------------------+
struct SessionsConfig
  {
   bool          useSelected;
   bool          asian, london, ny;
   long          asianStartSec, asianEndSec;
   long          londonStartSec, londonEndSec;
   long          nyStartSec, nyEndSec;
   long          gmtOffsetSec;
   ENUM_DST_MODE dstMode;
   bool          brokerFallback;
   bool          useBreakWindow;
   long          breakCloseSec;
   long          breakOpenSec;
   int           windowMinutes;
  };

//+------------------------------------------------------------------+
//| SessionsState — заполняет SessionsInit, обновляет SessionsUpdate. |
//+------------------------------------------------------------------+
struct SessionsState
  {
   long offsetSec;        // текущее смещение сервер → UTC
   long loggedOffsetSec;  // последнее записанное в журнал (смена DST)
   bool testerNoted;      // предупреждение «в тестере смещение ручное» уже выведено
   bool wasInside;        // внутри сессий на прошлом тике (событие выхода)
   long utcSec;           // UTC, секунда суток, на последнем пересчёте
   bool breakFromBroker;  // границы перерыва взяты из расписания брокера
   long closeSec;         // закрытие Америки, секунда суток сервера
   long openSec;          // открытие Азии, секунда суток сервера
  };

//+------------------------------------------------------------------+
//| Вспомогательные                                                  |
//+------------------------------------------------------------------+

long Sessions_Norm(const long sec)
  {
   return (sec % SESSIONS_SEC_PER_DAY + SESSIONS_SEC_PER_DAY) % SESSIONS_SEC_PER_DAY;
  }

bool Sessions_ValidSec(const long sec)
  {
   return sec >= 0 && sec < SESSIONS_SEC_PER_DAY;
  }

// Кратчайшее расстояние между секундами суток по окружности, [0, 43200].
long Sessions_CircularDist(const long t1, const long t2)
  {
   const long d1 = Sessions_Norm(t1 - t2);
   const long d2 = Sessions_Norm(t2 - t1);
   return (d1 < d2) ? d1 : d2;
  }

// t ∈ [start, end) по окружности; start == end — пустая сессия.
bool Sessions_InRange(const long t, const long start, const long end)
  {
   if(start == end)
      return false;
   if(start < end)
      return t >= start && t < end;
   return t >= start || t < end;
  }

long Sessions_RoundOffset(const long raw)
  {
   const long half = SESSIONS_DST_ROUND_SEC / 2;
   long r = (raw >= 0) ? ((raw + half) / SESSIONS_DST_ROUND_SEC) * SESSIONS_DST_ROUND_SEC
                       : -(((-raw) + half) / SESSIONS_DST_ROUND_SEC) * SESSIONS_DST_ROUND_SEC;
   return MathMax(SESSIONS_GMT_MIN_SEC, MathMin(SESSIONS_GMT_MAX_SEC, r));
  }

// Первые две разные торговые сессии брокера (пн–пт): out[0..3] = from1, to1, from2, to2.
// Возвращает число найденных пар (0, 1 или 2).
int Sessions_BrokerPairs(long &out[])
  {
   ArrayResize(out, 4);
   int found = 0;
   for(int day = MONDAY; day <= FRIDAY && found < 2; day++)
     {
      datetime from = 0, to = 0;
      for(uint i = 0; found < 2 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)day, i, from, to); i++)
        {
         const long f = (long)from, t = (long)to;
         if(!Sessions_ValidSec(f) || !Sessions_ValidSec(t) || f == t)
            continue;
         if(found == 1 && f == out[0] && t == out[1])
            continue;
         out[2 * found] = f;
         out[2 * found + 1] = t;
         found++;
        }
     }
   return found;
  }

// Пересчёт смещения UTC (DST_AUTO) и UTC-секунды суток.
void Sessions_RefreshClock(const SessionsConfig &c, SessionsState &s)
  {
   if(c.dstMode == DST_AUTO)
     {
      const long gmt = (long)TimeGMT();
      if(gmt == 0 || MQLInfoInteger(MQL_TESTER))
        {
         s.offsetSec = c.gmtOffsetSec;
         if(!s.testerNoted && c.useSelected)
           {
            PrintFormat("⚠️ Сессии DST_AUTO: %s — смещение из SessionGmtOffsetHours = %d ч",
                        gmt == 0 ? "TimeGMT() = 0" : "в тестере TimeGMT() = время сервера",
                        (int)(c.gmtOffsetSec / 3600));
            s.testerNoted = true;
           }
        }
      else
        {
         s.offsetSec = Sessions_RoundOffset((long)TimeTradeServer() - gmt);
         if(MathAbs(s.offsetSec - s.loggedOffsetSec) >= SESSIONS_DST_LOG_DELTA)
           {
            PrintFormat("ℹ️ Сессии: смещение UTC изменилось %+.2f → %+.2f ч",
                        s.loggedOffsetSec / 3600.0, s.offsetSec / 3600.0);
            s.loggedOffsetSec = s.offsetSec;
           }
        }
     }
   else
      s.offsetSec = c.gmtOffsetSec;
   s.utcSec = Sessions_Norm((long)TimeCurrent() - s.offsetSec);
  }

bool Sessions_IsInsideNow(const SessionsConfig &c, const SessionsState &s)
  {
   return (c.asian  && Sessions_InRange(s.utcSec, c.asianStartSec,  c.asianEndSec))  ||
          (c.london && Sessions_InRange(s.utcSec, c.londonStartSec, c.londonEndSec)) ||
          (c.ny     && Sessions_InRange(s.utcSec, c.nyStartSec,     c.nyEndSec));
  }

//+------------------------------------------------------------------+
//| Публичный интерфейс                                              |
//+------------------------------------------------------------------+

// Инициализация. Невалидные границы выбранных сессий выключают правило 1 (false в ответ).
// cfg — не const: broker fallback записывает границы Лондона/НЙ.
bool SessionsInit(SessionsConfig &c, SessionsState &s)
  {
   s.testerNoted = false;
   s.wasInside   = false;
   bool ok = true;

   //--- правило 1: проверка границ и смещения
   if(c.useSelected)
     {
      long v[6];
      v[0] = c.asianStartSec; v[1] = c.asianEndSec; v[2] = c.londonStartSec;
      v[3] = c.londonEndSec;  v[4] = c.nyStartSec;  v[5] = c.nyEndSec;
      for(int i = 0; i < 6 && ok; i++)
         ok = Sessions_ValidSec(v[i]);
      if(ok && c.dstMode == DST_MANUAL)
         ok = c.gmtOffsetSec >= SESSIONS_GMT_MIN_SEC && c.gmtOffsetSec <= SESSIONS_GMT_MAX_SEC;
      if(!ok)
        {
         Print("❌ Сессии: границы или смещение UTC вне допустимого диапазона — выбор сессий выключен");
         c.useSelected = false;
        }
      else if(c.brokerFallback && v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && v[5] == 0)
        {
         long p[];
         if(Sessions_BrokerPairs(p) == 2)
           {
            c.londonStartSec = p[0]; c.londonEndSec = p[1];
            c.nyStartSec     = p[2]; c.nyEndSec     = p[3];
           }
         else
            Print("⚠️ Сессии: брокер не отдал две торговые сессии — границы остаются нулевыми");
        }
     }

   //--- правило 2: границы перерыва — от брокера, иначе ручные
   long p[];
   s.breakFromBroker = Sessions_BrokerPairs(p) >= 1;
   if(s.breakFromBroker)
     {
      s.openSec  = p[0];
      s.closeSec = p[1];
     }
   else
     {
      s.openSec  = c.breakOpenSec;
      s.closeSec = c.breakCloseSec;
     }

   //--- часы и состояние «внутри» на старте (без события выхода)
   s.offsetSec       = c.gmtOffsetSec;
   s.loggedOffsetSec = c.gmtOffsetSec;
   Sessions_RefreshClock(c, s);
   s.loggedOffsetSec = s.offsetSec;
   s.wasInside       = c.useSelected && Sessions_IsInsideNow(c, s);
   return ok;
  }

// Вызывать один раз в начале тика: пересчитывает часы и событие выхода из сессий.
ENUM_SESSION_STATE SessionsUpdate(const SessionsConfig &c, SessionsState &s)
  {
   Sessions_RefreshClock(c, s);
   if(!c.useSelected)
      return SESSION_TRADING;
   const bool inside = Sessions_IsInsideNow(c, s);
   const bool exited = s.wasInside && !inside;
   s.wasInside = inside;
   if(exited)
      return SESSION_JUST_EXITED;
   return inside ? SESSION_TRADING : SESSION_OUTSIDE;
  }

// Правило 2: сейчас ±windowMinutes от закрытия Америки или открытия Азии (время сервера).
bool SessionsInBreakWindow(const SessionsConfig &c, const SessionsState &s)
  {
   if(!c.useBreakWindow || c.windowMinutes < 1 || c.windowMinutes > 120 ||
      !Sessions_ValidSec(s.closeSec) || !Sessions_ValidSec(s.openSec))
      return false;
   const long w   = (long)c.windowMinutes * 60L;
   const long now = Sessions_Norm((long)TimeCurrent());
   return Sessions_CircularDist(now, s.closeSec) <= w || Sessions_CircularDist(now, s.openSec) <= w;
  }

// Правило 2: последние windowMinutes перед закрытием Америки — (close − окно, close].
bool SessionsInPreClose(const SessionsConfig &c, const SessionsState &s)
  {
   if(!c.useBreakWindow || c.windowMinutes < 1 || c.windowMinutes > 120 ||
      !Sessions_ValidSec(s.closeSec) || !Sessions_ValidSec(s.openSec))
      return false;
   const long now = Sessions_Norm((long)TimeCurrent());
   return Sessions_Norm(s.closeSec - now) < (long)c.windowMinutes * 60L;
  }

#endif // SESSIONFILTER_MQH
//+------------------------------------------------------------------+
