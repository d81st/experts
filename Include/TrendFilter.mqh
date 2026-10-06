//+------------------------------------------------------------------+
//|                                                  TrendFilter.mqh |
//|                                                                  |
//|  Trend Filter — HTF EMA-cross + optional ADX/DI bias gate        |
//|                                                                  |
//|  This header declares:                                           |
//|   - TrendConfig   — настройки EMA-кросса и ADX/DI                |
//|   - TrendHandles  — индикаторные хэндлы lifecycle                |
//|   - прототипы публичных функций модуля:                          |
//|       TrendInit                                                  |
//|       TrendDeinit                                                |
//|       TrendIsAllowed                                             |
//|   - прототип приватного хелпера TrendFilter_GetBufferValue,      |
//|     инкапсулирующего CopyBuffer single-cell read.                |
//|                                                                  |
//|  Модуль соответствует требованиям модульной изоляции:            |
//|  include-guard уникален, конфигурация передаётся                 |
//|  только через struct-аргументы, `input`-переменные в этом файле  |
//|  не объявляются. Глобальное состояние на уровне модуля           |
//|  отсутствует — все хэндлы держит вызывающая сторона в            |
//|  TrendHandles.                                                   |
//|                                                                  |
//|  Тела функций реализуются в задачах 8.2 и 8.3 этой же спеки.     |
//+------------------------------------------------------------------+
#ifndef TRENDFILTER_MQH
#define TRENDFILTER_MQH

//+------------------------------------------------------------------+
//| TrendConfig — иммутабельная конфигурация тренд-фильтра.          |
//|                                                                  |
//|  useTrend   — включает EMA-кросс fast/slow;                      |
//|                при false EMA-хэндлы не создаются.                |
//|  useADX     — включает ADX/DI-фильтр;                            |
//|                при false ADX-хэндл не создаётся.                 |
//|  timeframe  — HTF, на котором читаются EMA/ADX.                  |
//|  fastEMA    — период быстрой EMA, диапазон [1, 1000].            |
//|  slowEMA    — период медленной EMA, диапазон [1, 1000],          |
//|                требуется fastEMA < slowEMA.                      |
//|  adxPeriod  — период ADX, диапазон [1, 1000].                    |
//|  adxMin     — минимальный порог ADX, диапазон [0.0, 100.0].      |
//|                                                                  |
//|  Значение передаётся в TrendInit/TrendIsAllowed через const &    |
//|  и не модифицируется модулем.                                    |
//+------------------------------------------------------------------+
struct TrendConfig
  {
   bool            useTrend;
   bool            useADX;
   ENUM_TIMEFRAMES timeframe;
   int             fastEMA;
   int             slowEMA;
   int             adxPeriod;
   double          adxMin;
  };

//+------------------------------------------------------------------+
//| TrendHandles — lifecycle-структура индикаторных хэндлов.         |
//|                                                                  |
//|  emaFast / emaSlow — хэндлы iMA для fast/slow EMA, заполняются   |
//|                       при cfg.useTrend == true;                  |
//|                       равны INVALID_HANDLE при useTrend == false |
//| или после TrendDeinit.                                           |
//|  adx               — хэндл iADX, заполняется при cfg.useADX      |
//|                       == true; равен INVALID_HANDLE              |
//|                       при useADX == false или после              |
//|                       TrendDeinit.                               |
//|                                                                  |
//|  Перед первым вызовом TrendInit вызывающая сторона должна        |
//|  установить все поля в INVALID_HANDLE; TrendInit перезапишет     |
//|  только требуемые по cfg поля и оставит остальные равными        |
//|  INVALID_HANDLE.                                                 |
//+------------------------------------------------------------------+
struct TrendHandles
  {
   int  emaFast;     // INVALID_HANDLE если useTrend=false или после Deinit
   int  emaSlow;     // INVALID_HANDLE если useTrend=false или после Deinit
   int  adx;         // INVALID_HANDLE если useADX=false  или после Deinit
  };

//+------------------------------------------------------------------+
//| Публичный интерфейс TrendFilter (Module 3).                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| TrendInit — создаёт индикаторные хэндлы согласно cfg.            |
//|                                                                  |
//|  Возвращает true, если все требуемые по cfg хэндлы успешно       |
//|  созданы и доступны для CopyBuffer.                              |
//|  Возвращает false при нарушении границ параметров                |
//|  (fastEMA/slowEMA/adxPeriod/adxMin/timeframe), при                |
//|  fastEMA >= slowEMA или при отказе iMA/iADX; в этом случае все   |
//|  частично созданные валидные хэндлы освобождаются через          |
//|  IndicatorRelease, а соответствующие поля h устанавливаются в    |
//|  INVALID_HANDLE.                                                 |
//|                                                                  |
//|  Поля h, не требуемые по cfg (useTrend=false / useADX=false),    |
//|  устанавливаются в INVALID_HANDLE.                               |
//|                                                                  |
//|  Тело реализуется в задаче 8.2.                                  |
//+------------------------------------------------------------------+
bool   TrendInit(const TrendConfig &cfg, TrendHandles &h);

//+------------------------------------------------------------------+
//| TrendDeinit — освобождает индикаторные хэндлы.                   |
//|                                                                  |
//|  Для каждого поля h[i] != INVALID_HANDLE вызывает                |
//|  IndicatorRelease ровно один раз и устанавливает поле в          |
//|  INVALID_HANDLE до возврата. Повторный                           |
//|  вызов с уже очищенным h безопасен: IndicatorRelease не          |
//|  вызывается, _LastError не модифицируется.                       |
//|                                                                  |
//|  Тело реализуется в задаче 8.2.                                  |
//+------------------------------------------------------------------+
void   TrendDeinit(TrendHandles &h);

//+------------------------------------------------------------------+
//| TrendIsAllowed — разрешает ли фильтр вход в направлении dir.     |
//|                                                                  |
//|  dir = +1 → BUY, dir = -1 → SELL. При dir вне множества {+1,-1}  |
//|  возвращает false без модификации cfg и h.                       |
//|                                                                  |
//|  Логика разрешения (читается на закрытом баре, shift = 1):       |
//|   - useTrend=false и useADX=false  → true.                       |
//|   - useTrend=true, dir=+1 → fastEMA[1] > slowEMA[1] и (если      |
//|     useADX=true) +DI[1] > -DI[1] и ADX[1] >= cfg.adxMin.         |
//|   - useTrend=true, dir=-1 → fastEMA[1] < slowEMA[1] и (если      |
//|     useADX=true) -DI[1] > +DI[1] и ADX[1] >= cfg.adxMin.         |
//|   - useTrend=false и useADX=true  → только ADX/DI-условие        |
//|     для соответствующего dir.                                    |
//|                                                                  |
//|  cfg и h НЕ модифицируются. При сбое                             |
//|  CopyBuffer для любого требуемого индикатора возвращает false    |
//|  без модификации cfg и h.                                        |
//|                                                                  |
//|  Тело реализуется в задаче 8.3.                                  |
//+------------------------------------------------------------------+
bool   TrendIsAllowed(const TrendConfig &cfg, const TrendHandles &h, const int dir);

//+------------------------------------------------------------------+
//| Приватный хелпер модуля.                                         |
//|                                                                  |
//|  Имя c префиксом `TrendFilter_` отражает «module-private»        |
//|  семантику и предотвращает коллизии с одноимёнными хелперами в   |
//|  EA-файлах (локальные `GetBufferValue` не допускаются).          |
//|  Функция не входит в публичный API модуля и используется только  |
//|  телами TrendInit / TrendIsAllowed.                              |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| TrendFilter_GetBufferValue — читает одну ячейку индикаторного    |
//| буфера через CopyBuffer.                                         |
//|                                                                  |
//|  handle — валидный индикаторный хэндл (h.emaFast / h.emaSlow /   |
//|            h.adx); вызывающая сторона гарантирует, что hэндл     |
//|            != INVALID_HANDLE.                                    |
//|  buffer — индекс буфера индикатора (0 для EMA, 0/1/2 для ADX).   |
//|  shift  — смещение от текущего бара; модуль читает shift = 1,    |
//|            т.е. последний закрытый бар.                          |
//|                                                                  |
//|  Возвращает прочитанное значение при CopyBuffer == 1; при отказе |
//|  CopyBuffer (< 1) возвращает 0.0 как sentinel-значение —         |
//|  TrendIsAllowed обязан отдельно проверять статус CopyBuffer и    |
//|  возвращать false при сбое.                                      |
//|                                                                  |
//|  Тело реализуется в задаче 8.2.                                  |
//+------------------------------------------------------------------+
double TrendFilter_GetBufferValue(const int handle, const int buffer, const int shift);

//+------------------------------------------------------------------+
//| Implementations                                                  |
//|                                                                  |
//|  Тела TrendInit / TrendDeinit и приватного хелпера               |
//|  TrendFilter_GetBufferValue. Реализация задачи 8.2 спеки         |
//|  ea-modular-architecture.                                        |
//|                                                                  |
//|  TrendIsAllowed реализуется отдельно в задаче 8.3.               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| TrendFilter_GetBufferValue — приватный хелпер.                   |
//|                                                                  |
//|  Читает одну ячейку индикаторного буфера. При сбое CopyBuffer    |
//|  (< 1) возвращает 0.0 как sentinel; вызывающая сторона обязана   |
//|  отдельно проверять статус CopyBuffer для корректной обработки   |
//|  отказа в TrendIsAllowed.                                        |
//+------------------------------------------------------------------+
double TrendFilter_GetBufferValue(const int handle, const int buffer, const int shift)
  {
   double tmp[1];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) < 1)
      return 0.0;
   return tmp[0];
  }

//+------------------------------------------------------------------+
//| TrendInit — создаёт индикаторные хэндлы согласно cfg.            |
//|                                                                  |
//|  Контракт (см. блочный комментарий к прототипу выше):            |
//|   - При cfg.useTrend == true и валидных fastEMA, slowEMA ∈       |
//|     [1, 1000] с fastEMA < slowEMA — создать h.emaFast/h.emaSlow  |
//|     через iMA.                                                   |
//|   - При cfg.useADX == true и валидных adxPeriod ∈ [1, 1000],     |
//|     adxMin ∈ [0, 100] — создать h.adx через iADX.                |
//|   - При useTrend == false → h.emaFast = h.emaSlow =              |
//|     INVALID_HANDLE; useADX == false → h.adx =                    |
//|     INVALID_HANDLE.                                              |
//|   - При любой ошибке (нарушение пределов, отказ iMA/iADX) —      |
//|     откатиться через TrendDeinit и вернуть false.                |
//|                                                                  |
//|  Поля h инициализируются в INVALID_HANDLE на входе, чтобы        |
//|  частичное создание корректно разворачивалось через TrendDeinit: |
//|  TrendDeinit освобождает только реально созданные                |
//|  хэндлы и игнорирует поля, оставшиеся в INVALID_HANDLE.          |
//+------------------------------------------------------------------+
bool TrendInit(const TrendConfig &cfg, TrendHandles &h)
  {
   // Инициализация в INVALID_HANDLE гарантирует чистый откат при
   // частичном сбое: TrendDeinit вызовет IndicatorRelease только
   // для уже созданных хэндлов.
   h.emaFast = INVALID_HANDLE;
   h.emaSlow = INVALID_HANDLE;
   h.adx     = INVALID_HANDLE;

   //--- EMA-блок
   if(cfg.useTrend)
     {
      if(cfg.fastEMA < 1 || cfg.fastEMA > 1000) return false;
      if(cfg.slowEMA < 1 || cfg.slowEMA > 1000) return false;
      if(cfg.fastEMA >= cfg.slowEMA)            return false;

      h.emaFast = iMA(_Symbol, cfg.timeframe, cfg.fastEMA, 0, MODE_EMA, PRICE_CLOSE);
      h.emaSlow = iMA(_Symbol, cfg.timeframe, cfg.slowEMA, 0, MODE_EMA, PRICE_CLOSE);

      if(h.emaFast == INVALID_HANDLE || h.emaSlow == INVALID_HANDLE)
        {
         // Откат: освобождаем то, что успели создать.
         TrendDeinit(h);
         return false;
        }
     }

   //--- ADX-блок
   if(cfg.useADX)
     {
      if(cfg.adxPeriod < 1 || cfg.adxPeriod > 1000)
        {
         TrendDeinit(h);
         return false;
        }
      if(cfg.adxMin < 0.0 || cfg.adxMin > 100.0)
        {
         TrendDeinit(h);
         return false;
        }

      h.adx = iADX(_Symbol, cfg.timeframe, cfg.adxPeriod);
      if(h.adx == INVALID_HANDLE)
        {
         // Откат: EMA-хэндлы (если были созданы) тоже освобождаются.
         TrendDeinit(h);
         return false;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| TrendDeinit — освобождает индикаторные хэндлы.                   |
//|                                                                  |
//|  Для каждого поля h[i] != INVALID_HANDLE вызывает                |
//|  IndicatorRelease ровно один раз и сбрасывает поле в             |
//|  INVALID_HANDLE до возврата.                                     |
//|                                                                  |
//|  Идемпотентность: повторный вызов с h, у                         |
//|  которого все поля уже равны INVALID_HANDLE, гарантированно НЕ   |
//|  вызывает IndicatorRelease и НЕ модифицирует _LastError —        |
//|  проверка `!= INVALID_HANDLE` отсеивает все обращения к API.     |
//+------------------------------------------------------------------+
void TrendDeinit(TrendHandles &h)
  {
   if(h.emaFast != INVALID_HANDLE)
     {
      IndicatorRelease(h.emaFast);
      h.emaFast = INVALID_HANDLE;
     }
   if(h.emaSlow != INVALID_HANDLE)
     {
      IndicatorRelease(h.emaSlow);
      h.emaSlow = INVALID_HANDLE;
     }
   if(h.adx != INVALID_HANDLE)
     {
      IndicatorRelease(h.adx);
      h.adx = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| TrendIsAllowed — разрешает ли фильтр вход в направлении dir.     |
//|                                                                  |
//|  Контракт (см. блочный комментарий к прототипу выше):             |
//|   - dir вне {+1,-1} → false без модификаций cfg/h.               |
//|   - useTrend=false и useADX=false → true.                        |
//|   - useTrend=true: fast/slow EMA читаются с shift=1; для BUY     |
//|     требуется fastEMA[1] > slowEMA[1], для SELL — обратно.       |
//|   - useADX=true: ADX/+DI/-DI читаются с shift=1; ADX[1] должен   |
//|     быть >= cfg.adxMin, и +DI[1] > -DI[1] (BUY) или -DI[1] >    |
//|     +DI[1] (SELL). Работает независимо от useTrend.              |
//|                                                                  |
//|  Сбой CopyBuffer (< 1) по любому требуемому индикатору сразу    |
//|  возвращает false без модификаций cfg/h. Здесь                   |
//|  используется CopyBuffer напрямую, а не                          |
//|  TrendFilter_GetBufferValue: его sentinel 0.0 неотличим от       |
//|  валидного нуля (например, +DI/-DI могут быть около 0 на         |
//|  слабом тренде), поэтому опираться на sentinel нельзя.           |
//|                                                                  |
//|  cfg и h объявлены как const & в прототипе — компилятор          |
//|  гарантирует их немодифицируемость.                              |
//+------------------------------------------------------------------+
bool TrendIsAllowed(const TrendConfig &cfg, const TrendHandles &h, const int dir)
  {
   // dir вне {+1,-1} → false без модификаций.
   if(dir != 1 && dir != -1)
      return false;

   // оба фильтра выключены → разрешено всегда.
   if(!cfg.useTrend && !cfg.useADX)
      return true;

   // Закрытый бар; единая точка чтения для EMA и ADX/DI.
   const int shift = 1;

   //--- EMA-блок
   if(cfg.useTrend)
     {
      // Хэндлы должны быть валидными: TrendInit гарантирует это при
      // useTrend=true; INVALID_HANDLE здесь = инициализация не была
      // выполнена → отказываем (защита от misuse).
      if(h.emaFast == INVALID_HANDLE || h.emaSlow == INVALID_HANDLE)
         return false;

      double fastBuf[1];
      double slowBuf[1];
      // при отказе CopyBuffer — false без модификаций.
      if(CopyBuffer(h.emaFast, 0, shift, 1, fastBuf) < 1)
         return false;
      if(CopyBuffer(h.emaSlow, 0, shift, 1, slowBuf) < 1)
         return false;

      // BUY требует fast > slow; SELL требует fast < slow.
      if(dir == 1  && !(fastBuf[0] > slowBuf[0]))
         return false;
      if(dir == -1 && !(fastBuf[0] < slowBuf[0]))
         return false;
     }

   //--- ADX/DI-блок: работает независимо от useTrend.
   if(cfg.useADX)
     {
      if(h.adx == INVALID_HANDLE)
         return false;

      // iADX buffer layout: 0 = ADX, 1 = +DI, 2 = -DI
      // (подтверждено reference-имплементацией в engulfing-bot_v2.1.mq5 /
      //  crt-bot_v4.2.mq5).
      double adxBuf    [1];
      double plusDiBuf [1];
      double minusDiBuf[1];

      // при отказе CopyBuffer по любому из буферов — false.
      if(CopyBuffer(h.adx, 0, shift, 1, adxBuf)     < 1)
         return false;
      if(CopyBuffer(h.adx, 1, shift, 1, plusDiBuf)  < 1)
         return false;
      if(CopyBuffer(h.adx, 2, shift, 1, minusDiBuf) < 1)
         return false;

      // ADX должен превышать пороговый минимум.
      if(adxBuf[0] < cfg.adxMin)
         return false;

      // BUY → +DI > -DI; SELL → -DI > +DI.
      if(dir == 1  && !(plusDiBuf[0]  > minusDiBuf[0]))
         return false;
      if(dir == -1 && !(minusDiBuf[0] > plusDiBuf[0]))
         return false;
     }

   return true;
  }

#endif // TRENDFILTER_MQH
//+------------------------------------------------------------------+
