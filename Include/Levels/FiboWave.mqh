//+------------------------------------------------------------------+
//|                                                    FiboWave.mqh |
//|                                                                  |
//|  Фибо-зоны от волн ATR-зигзага (логика Fibo Zones): диапазон —   |
//|  последняя подтверждённая волна; зоны — откат 0.382–0.5 по       |
//|  направлению волны (подтверждённой и текущей), 1.212–1.272,      |
//|  1.618–1.762, 2.212–2.272 за диапазоном в обе стороны.           |
//|  Модуль строит зоны и сообщает о смене диапазона; ордерами       |
//|  занимается бот (например, через Triggers/ZoneOrders).           |
//|                                                                  |
//|  Слоты: 0 — откат подтверждённой волны; 1/2 — Ext1 сверху/снизу; |
//|  3/4 — Ext2; 5/6 — Ext3; 7 — откат текущей волны.                |
//+------------------------------------------------------------------+
#ifndef FIBOWAVE_MQH
#define FIBOWAVE_MQH

#include "AtrZigZag.mqh"
#include "FiboZones.mqh"

#define FIBO_WAVE_SLOTS         8
#define FIBO_WAVE_RANGE_CHANGED 1   // подтверждена новая волна — новый диапазон
#define FIBO_WAVE_LIVE_CHANGED  2   // сменился экстремум текущей волны (слот 7)

//+------------------------------------------------------------------+
//| FiboWaveConfig — входные параметры бота.                         |
//|   minRange — мин. размер волны в цене (0 = без ограничения)      |
//+------------------------------------------------------------------+
struct FiboWaveConfig
  {
   ENUM_TIMEFRAMES tf;
   int             atrPeriod;
   double          atrMult;
   int             warmupBars;
   double          minRange;
   bool            useRetrace, useRetraceLive, useExt1, useExt2, useExt3;
   double          retraceNear, retraceFar;
   double          ext1Near, ext1Far, ext2Near, ext2Far, ext3Near, ext3Far;
  };

//+------------------------------------------------------------------+
//| FiboWave — состояние: зигзаг, диапазон, счётчик диапазонов.      |
//+------------------------------------------------------------------+
struct FiboWave
  {
   int       atrHandle;
   bool      ready;      // волна найдена по истории
   AtrZigZag zz;
   bool      valid;      // диапазон есть и не меньше minRange
   int       id;
   double    hi;
   double    lo;
   int       waveDir;    // +1 — волна вверх (минимум раньше максимума), -1 — вниз
   datetime  liveKey;    // время текущего экстремума волны
   int       cntRanges;
  };

bool FiboWaveInit(FiboWave &w, const FiboWaveConfig &c)
  {
   AtrZigZagReset(w.zz);
   w.ready = false; w.valid = false; w.id = 0; w.hi = 0.0; w.lo = 0.0; w.waveDir = 0;
   w.liveKey = 0; w.cntRanges = 0;
   w.atrHandle = iATR(_Symbol, c.tf, c.atrPeriod);
   return w.atrHandle != INVALID_HANDLE;
  }

void FiboWaveDeinit(FiboWave &w)
  {
   if(w.atrHandle != INVALID_HANDLE)
      IndicatorRelease(w.atrHandle);
   w.atrHandle = INVALID_HANDLE;
  }

// Подтверждена новая точка разворота: диапазон — последняя подтверждённая волна.
bool FiboWave_OnPivot(FiboWave &w, const FiboWaveConfig &c, const bool log)
  {
   if(!AtrZigZagHasRange(w.zz))
      return false;
   w.id++;
   w.hi      = w.zz.pivHi;
   w.lo      = w.zz.pivLo;
   w.waveDir = AtrZigZagWaveDir(w.zz);
   w.valid   = (w.zz.pivHi - w.zz.pivLo) >= c.minRange;
   if(log)
     {
      w.cntRanges++;
      PrintFormat("📐 Диапазон #%d: H=%.3f L=%.3f R=%.2f USD | волна %s%s",
                  w.id, w.hi, w.lo, w.hi - w.lo, w.waveDir == 1 ? "вверх" : "вниз",
                  w.valid ? "" : " | меньше MinRangePoints — не торгуем");
     }
   return true;
  }

// Один закрытый бар зигзага. true — сменился диапазон.
bool FiboWave_Step(FiboWave &w, const FiboWaveConfig &c, const int shift, const bool log)
  {
   double atr[1];
   if(CopyBuffer(w.atrHandle, 0, shift, 1, atr) != 1 || atr[0] <= 0.0)
      return false;
   const double   h  = iHigh(_Symbol, c.tf, shift);
   const double   l  = iLow(_Symbol, c.tf, shift);
   const datetime t  = iTime(_Symbol, c.tf, shift);
   const double   th = c.atrMult * atr[0];
   if(AtrZigZagStep(w.zz, h, l, t, th) == 0)
      return false;
   return FiboWave_OnPivot(w, c, log);
  }

//+------------------------------------------------------------------+
//| FiboWaveOnNewBar — вызывать на каждом новом баре c.tf. Сначала   |
//| прогрев по истории (без журнала), затем по одному закрытому бару.|
//| Возвращает флаги FIBO_WAVE_RANGE_CHANGED / FIBO_WAVE_LIVE_CHANGED.|
//+------------------------------------------------------------------+
int FiboWaveOnNewBar(FiboWave &w, const FiboWaveConfig &c)
  {
   int ev = 0;
   if(!w.ready)
     {
      const int bars = MathMin(c.warmupBars, Bars(_Symbol, c.tf) - 2);
      if(bars >= c.atrPeriod + 2 && BarsCalculated(w.atrHandle) >= bars + 1)
        {
         for(int s = bars; s >= 2; s--)
            if(FiboWave_Step(w, c, s, false))
               ev |= FIBO_WAVE_RANGE_CHANGED;
         w.ready = true;
         if(w.valid)
            PrintFormat("📐 Стартовый диапазон #%d: H=%.3f L=%.3f | волна %s",
                        w.id, w.hi, w.lo, w.waveDir == 1 ? "вверх" : "вниз");
        }
     }
   if(w.ready && FiboWave_Step(w, c, 1, true))
      ev |= FIBO_WAVE_RANGE_CHANGED;

   const datetime key = (w.zz.dir == 1) ? w.zz.candHiT : (w.zz.dir == -1 ? w.zz.candLoT : 0);
   if(key != w.liveKey)
     {
      w.liveKey = key;
      ev |= FIBO_WAVE_LIVE_CHANGED;
     }
   return ev;
  }

// Доли волны и флаг включения для слота.
bool FiboWaveSlotLevels(const FiboWaveConfig &c, const int slot, double &nearR, double &farR)
  {
   switch(slot)
     {
      case 0:  nearR = c.retraceNear; farR = c.retraceFar; return c.useRetrace;
      case 7:  nearR = c.retraceNear; farR = c.retraceFar; return c.useRetraceLive;
      case 1:
      case 2:  nearR = c.ext1Near;    farR = c.ext1Far;    return c.useExt1;
      case 3:
      case 4:  nearR = c.ext2Near;    farR = c.ext2Far;    return c.useExt2;
      default: nearR = c.ext3Near;    farR = c.ext3Far;    return c.useExt3;
     }
  }

string FiboWaveSlotName(const int slot)
  {
   return (slot == 0) ? "откат подтв." : (slot == 7 ? "откат текущей" : (slot % 2 == 1 ? "сверху" : "снизу"));
  }

//+------------------------------------------------------------------+
//| FiboWaveBuildZone — зона слота. Уровни отсчитываются от границ   |
//| диапазона долями R = hi - lo: откат — от конца волны внутрь; за  |
//| диапазоном сверху — lo + r·R, снизу — hi - r·R. Слот 7 — откат   |
//| текущей волны: от последней подтверждённой точки до текущего     |
//| экстремума.                                                      |
//+------------------------------------------------------------------+
bool FiboWaveBuildZone(const FiboWave &w, const FiboWaveConfig &c, const int slot, FiboZone &z)
  {
   double nearR, farR;
   if(!FiboWaveSlotLevels(c, slot, nearR, farR))
      return false;
   z.name = StringFormat("%.3f–%.3f", nearR, farR);

   if(slot == 7)
     {
      if(!w.ready || w.zz.dir == 0 || !AtrZigZagHasRange(w.zz))
         return false;
      // После минимума волна идёт вверх (покупка на откате), после максимума — вниз.
      const double start = (w.zz.dir == 1) ? w.zz.pivLo  : w.zz.pivHi;
      const double end   = (w.zz.dir == 1) ? w.zz.candHi : w.zz.candLo;
      const double W     = (w.zz.dir == 1) ? end - start : start - end;
      if(W <= 0.0 || W < c.minRange)
         return false;
      FiboRetraceZone(start, end, nearR, farR, z);
      z.name = "откат текущей " + z.name;
      return true;
     }

   if(!w.valid)
      return false;
   if(slot == 0)
     {
      if(w.waveDir == 1)
         FiboRetraceZone(w.lo, w.hi, nearR, farR, z);
      else
         FiboRetraceZone(w.hi, w.lo, nearR, farR, z);
      z.name = "откат подтв. " + z.name;
     }
   else if(slot % 2 == 1)   // сверху: продажа на разворот, тейк — максимум диапазона
     {
      FiboExtZone(w.hi, w.lo, true, nearR, farR, z);
      z.name = "сверху " + z.name;
     }
   else                     // снизу: покупка на разворот, тейк — минимум диапазона
     {
      FiboExtZone(w.hi, w.lo, false, nearR, farR, z);
      z.name = "снизу " + z.name;
     }
   return true;
  }

void FiboWaveBuildAll(const FiboWave &w, const FiboWaveConfig &c, FiboZone &zs[], bool &ok[])
  {
   for(int i = 0; i < FIBO_WAVE_SLOTS; i++)
      ok[i] = FiboWaveBuildZone(w, c, i, zs[i]);
  }

#endif // FIBOWAVE_MQH
//+------------------------------------------------------------------+
