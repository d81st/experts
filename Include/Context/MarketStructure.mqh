//+------------------------------------------------------------------+
//|                                              MarketStructure.mqh |
//|                                                                  |
//|  Тренд структуры рынка (как LimonFx, tester/tools/structure.py): |
//|  точки разворота pivothigh/pivotlow(len, len); закрытие          |
//|  пересекло последний максимум — тренд вверх (BOS или CHoCH),     |
//|  минимум — вниз. Пробитый уровень убирается, следующий пробой —  |
//|  только новой точки. Плюс простой тренд: закрытие выше/ниже EMA. |
//|  Всё — по барам, закрытым к моменту asOf. Для D1 воскресный бар  |
//|  (сессия ~22:00–24:00) сливается с понедельником, как в screen.py|
//|  Состояние не хранится: тренд считается заново по последним      |
//|  MS_BARS барам (пара миллисекунд, вызывать раз на сигнал).       |
//+------------------------------------------------------------------+
#ifndef MARKETSTRUCTURE_MQH
#define MARKETSTRUCTURE_MQH

#define MS_BARS 400

// Закрытые к asOf бары tf (старые → новые). Возвращает число баров.
int MsClosedBars(const ENUM_TIMEFRAMES tf, const datetime asOf, double &h[], double &l[], double &c[])
  {
   const int per = PeriodSeconds(tf);
   MqlRates r[];
   ArraySetAsSeries(r, false);
   const int got = CopyRates(_Symbol, tf, asOf - (datetime)((MS_BARS + 5) * (long)per * (tf == PERIOD_D1 ? 2 : 1)),
                             asOf - 1, r);
   ArrayResize(h, 0); ArrayResize(l, 0); ArrayResize(c, 0);
   if(got <= 0)
      return 0;
   int n = 0;
   const bool merge = (tf == PERIOD_D1);
   for(int i = 0; i < got; i++)
     {
      MqlDateTime d;
      TimeToStruct(r[i].time, d);
      datetime closeT = r[i].time + per;
      if(merge && d.day_of_week == 0)
         closeT += per;                 // воскресенье — часть понедельника
      bool join = false;
      if(merge && n > 0 && i > 0)
        {
         MqlDateTime p;
         TimeToStruct(r[i - 1].time, p);
         join = (p.day_of_week == 0 && r[i].time - r[i - 1].time <= per);
        }
      if(join)
        {
         h[n - 1] = MathMax(h[n - 1], r[i].high);
         l[n - 1] = MathMin(l[n - 1], r[i].low);
         c[n - 1] = r[i].close;
        }
      else
        {
         ArrayResize(h, n + 1); ArrayResize(l, n + 1); ArrayResize(c, n + 1);
         h[n] = r[i].high; l[n] = r[i].low; c[n] = r[i].close;
         n++;
        }
      if(closeT > asOf)                 // бар (или понедельник с воскресеньем) ещё не закрыт
        {
         n--;
         ArrayResize(h, n); ArrayResize(l, n); ArrayResize(c, n);
         break;
        }
     }
   return n;
  }

// Тренд структуры на последнем закрытом баре: +1 / −1 / 0 (не определён).
int MsStructureTrend(const ENUM_TIMEFRAMES tf, const int len, const datetime asOf)
  {
   double h[], l[], c[];
   const int n = MsClosedBars(tf, asOf, h, l, c);
   if(n < 2 * len + 3)
      return 0;
   double up = 0.0, dn = 0.0;
   bool hasUp = false, hasDn = false;
   int nhigh = 0, nlow = 0, tr = 0;
   for(int i = 0; i < n; i++)
     {
      // точка разворота с центром i − len подтверждается на баре i
      const int cc = i - len;
      if(cc >= len)
        {
         bool ph = true, pl = true;
         for(int k = cc - len; k <= cc + len && (ph || pl); k++)
           {
            if(k == cc)
               continue;
            if(k < cc)
              {
               if(h[k] >= h[cc]) ph = false;
               if(l[k] <= l[cc]) pl = false;
              }
            else
              {
               if(h[k] > h[cc]) ph = false;
               if(l[k] < l[cc]) pl = false;
              }
           }
         if(ph)      { up = h[cc]; hasUp = true; nhigh++; }
         else if(pl) { dn = l[cc]; hasDn = true; nlow++; }
        }
      if(i > 0)
        {
         if(hasUp && nlow > 1 && c[i] > up && c[i - 1] <= up)
           { tr = 1; hasUp = false; }
         if(hasDn && nhigh > 1 && c[i] < dn && c[i - 1] >= dn)
           { tr = -1; hasDn = false; }
        }
     }
   return tr;
  }

// Простой тренд: закрытие последнего закрытого бара выше (+1) / ниже (−1) EMA(period).
int MsEmaTrend(const ENUM_TIMEFRAMES tf, const int period, const datetime asOf)
  {
   double h[], l[], c[];
   const int n = MsClosedBars(tf, asOf, h, l, c);
   if(n < period)
      return 0;
   const double a = 2.0 / (period + 1.0);
   double e = c[0];
   for(int i = 1; i < n; i++)
      e = a * c[i] + (1.0 - a) * e;
   return c[n - 1] > e ? 1 : (c[n - 1] < e ? -1 : 0);
  }

#endif // MARKETSTRUCTURE_MQH
//+------------------------------------------------------------------+
