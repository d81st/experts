//+------------------------------------------------------------------+
//|                                              AlchemistSignal.mqh |
//|                                                                  |
//|  Сигнал «Alchemist's Trend»: покупка, когда впервые сошлись      |
//|  условия — закрытие выше MA (SMA), HMA растёт, CCI выше +порога, |
//|  старший ТФ: закрытие последнего закрытого бара выше EMA. Продажа |
//|  — зеркально. Каждый фильтр, кроме MA, отключается. Всё — по     |
//|  закрытым барам: сигнал на баре 1 (условия есть на баре 1 и не   |
//|  было на баре 2), вход — на открытии бара 0.                     |
//|  Расчёт совпадает с tester/tools/screen.py (alch_signals).       |
//+------------------------------------------------------------------+
#ifndef ALCHEMISTSIGNAL_MQH
#define ALCHEMISTSIGNAL_MQH

struct AlchemistConfig
  {
   ENUM_TIMEFRAMES tf;
   int             maPeriod;      // SMA по закрытиям
   bool            useHma;
   int             hmaPeriod;
   bool            useCci;
   int             cciPeriod;     // CCI по типичной цене
   double          cciLevel;      // покупка: CCI > +уровня, продажа: CCI < −уровня
   bool            useHtf;
   ENUM_TIMEFRAMES htf;
   int             htfEmaPeriod;
  };

struct AlchemistState
  {
   int hMa, hCci, hHtfEma;
  };

bool AlchemistInit(AlchemistState &s, const AlchemistConfig &c)
  {
   s.hMa     = iMA(_Symbol, c.tf, c.maPeriod, 0, MODE_SMA, PRICE_CLOSE);
   s.hCci    = c.useCci ? iCCI(_Symbol, c.tf, c.cciPeriod, PRICE_TYPICAL) : INVALID_HANDLE;
   s.hHtfEma = c.useHtf ? iMA(_Symbol, c.htf, c.htfEmaPeriod, 0, MODE_EMA, PRICE_CLOSE) : INVALID_HANDLE;
   return s.hMa != INVALID_HANDLE && (!c.useCci || s.hCci != INVALID_HANDLE) &&
          (!c.useHtf || s.hHtfEma != INVALID_HANDLE);
  }

void AlchemistRelease(AlchemistState &s)
  {
   if(s.hMa != INVALID_HANDLE)     IndicatorRelease(s.hMa);
   if(s.hCci != INVALID_HANDLE)    IndicatorRelease(s.hCci);
   if(s.hHtfEma != INVALID_HANDLE) IndicatorRelease(s.hHtfEma);
   s.hMa = s.hCci = s.hHtfEma = INVALID_HANDLE;
  }

// Взвешенная средняя n значений x[from … from+n-1] (x — серия: 0 — новейший), веса n … 1.
double AlchemistWma(const double &x[], const int from, const int n)
  {
   double num = 0.0, den = 0.0;
   for(int k = 0; k < n; k++)
     {
      const double w = n - k;
      num += w * x[from + k];
      den += w;
     }
   return num / den;
  }

// HMA(n) на барах shift и shift+1: WMA(2·WMA(n/2) − WMA(n), √n).
bool AlchemistHma2(const ENUM_TIMEFRAMES tf, const int shift, const int n, double &h0, double &h1)
  {
   const int half = n / 2;
   const int sq   = (int)MathFloor(MathSqrt(n));
   if(half < 1 || sq < 1)
      return false;
   const int need = n + sq + 1;
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, tf, shift, need, c) < need)
      return false;
   double d[];
   ArrayResize(d, sq + 1);
   for(int k = 0; k < sq + 1; k++)
      d[k] = 2.0 * AlchemistWma(c, k, half) - AlchemistWma(c, k, n);
   h0 = AlchemistWma(d, 0, sq);
   h1 = AlchemistWma(d, 1, sq);
   return true;
  }

// Направление на закрытом баре shift: +1 — все условия покупки, −1 — продажи, 0 — нет.
// ok = false — данных не хватило.
int AlchemistState1(const AlchemistState &s, const AlchemistConfig &c, const int shift, bool &ok)
  {
   ok = false;
   double ma[1], cc[1];
   if(CopyBuffer(s.hMa, 0, shift, 1, ma) < 1)
      return 0;
   const double cl = iClose(_Symbol, c.tf, shift);
   if(cl <= 0.0)
      return 0;
   bool up = cl > ma[0], dn = cl < ma[0];

   if(c.useHma)
     {
      double h0, h1;
      if(!AlchemistHma2(c.tf, shift, c.hmaPeriod, h0, h1))
         return 0;
      up = up && h0 > h1;
      dn = dn && h0 < h1;
     }
   if(c.useCci)
     {
      if(CopyBuffer(s.hCci, 0, shift, 1, cc) < 1)
         return 0;
      up = up && cc[0] > c.cciLevel;
      dn = dn && cc[0] < -c.cciLevel;
     }
   if(c.useHtf)
     {
      // Последний бар старшего ТФ, закрытый к началу бара shift.
      const datetime t  = iTime(_Symbol, c.tf, shift);
      const int      hs = iBarShift(_Symbol, c.htf, t, false) + 1;
      double e[1];
      if(hs < 1 || CopyBuffer(s.hHtfEma, 0, hs, 1, e) < 1)
         return 0;
      const double hc = iClose(_Symbol, c.htf, hs);
      up = up && hc > e[0];
      dn = dn && hc < e[0];
     }
   ok = true;
   return up ? 1 : (dn ? -1 : 0);
  }

// Сигнал на закрытом баре 1: условия появились на баре 1 и не было их на баре 2.
int AlchemistSignal(const AlchemistState &s, const AlchemistConfig &c)
  {
   bool ok1, ok2;
   const int s1 = AlchemistState1(s, c, 1, ok1);
   const int s2 = AlchemistState1(s, c, 2, ok2);
   if(!ok1 || !ok2 || s1 == 0 || s1 == s2)
      return 0;
   return s1;
  }

#endif // ALCHEMISTSIGNAL_MQH
//+------------------------------------------------------------------+
