//+------------------------------------------------------------------+
//|                                                      FvgGaps.mqh |
//|                                                                  |
//|  Незакрытые разрывы (FVG) на рабочем ТФ и выбор, у каких держать |
//|  лимитки. Разрыв — по трём свечам: бычий — low[3] > high[1],     |
//|  медвежий — high[3] < low[1]. Ближний край — экстремум 3-й свечи,|
//|  дальний — 1-й. Разрыв живёт, пока цена не прошла дальний край.  |
//|  Лимитка — на ближнем крае по направлению разрыва (медвежий над  |
//|  ценой — продажа, бычий под ценой — покупка), стоп за дальним    |
//|  краем + отступ; пороги — в долях ATR на баре разрыва.           |
//|  Логика совпадает с tester/tools/fvg_sim.py (run).               |
//|  Вызывать FvgOnNewBar один раз на новом баре ТФ.                 |
//+------------------------------------------------------------------+
#ifndef FVGGAPS_MQH
#define FVGGAPS_MQH

//+------------------------------------------------------------------+
//| FvgConfig                                                        |
//|   minAge / maxAge — возраст разрыва (баров после 3-й свечи), при |
//|                     котором он может получить лимитку            |
//|   expiryBars      — срок лимитки: баров с первой постановки      |
//|   perSide         — сколько ближайших разрывов в каждую сторону  |
//|   minGapAtr       — мин. размер разрыва, доли ATR                |
//|   minSlAtr        — меньший стоп расширяется до этого, доли ATR  |
//|   maxSlAtr        — разрыв со стопом больше — пропускается       |
//|   buffer          — отступ стопа за дальним краем, цена (USD)    |
//+------------------------------------------------------------------+
struct FvgConfig
  {
   ENUM_TIMEFRAMES tf;
   int             minAge;
   int             maxAge;
   int             expiryBars;
   int             perSide;
   double          minGapAtr;
   double          minSlAtr;
   double          maxSlAtr;
   double          buffer;
  };

//+------------------------------------------------------------------+
//| FvgGap — один разрыв.                                            |
//|   t        — время 3-й свечи (бар разрыва)                       |
//|   dir      — направление сделки: +1 покупка, −1 продажа          |
//|   nearP    — ближний край (цена лимитки), farP — дальний         |
//|   sd       — расстояние до стопа (цена)                          |
//|   first    — время бара, с которого у разрыва была лимитка (0 —  |
//|              ещё не было)                                        |
//|   selected — выбран на последнем баре (держать лимитку)          |
//|   ticket   — тикет лимитки (ведёт бот)                           |
//+------------------------------------------------------------------+
struct FvgGap
  {
   datetime t;
   int      dir;
   double   nearP;
   double   farP;
   double   sd;
   datetime first;
   bool     selected;
   ulong    ticket;
  };

void FvgRemoveAt(FvgGap &g[], const int i)
  {
   const int n = ArraySize(g);
   for(int k = i; k < n - 1; k++)
      g[k] = g[k + 1];
   ArrayResize(g, n - 1);
  }

// Добавить разрыв, образованный закрытыми барами 3, 2, 1 (бар 1 — 3-я свеча).
// atr1 — ATR на баре 1. Возвращает true, если разрыв добавлен.
bool FvgDetect(const FvgConfig &c, FvgGap &g[], const double atr1)
  {
   if(atr1 <= 0.0)
      return false;
   const double h1 = iHigh(_Symbol, c.tf, 1), l1 = iLow(_Symbol, c.tf, 1);
   const double h3 = iHigh(_Symbol, c.tf, 3), l3 = iLow(_Symbol, c.tf, 3);
   int dir = 0;
   double nearP = 0.0, farP = 0.0;
   if(l1 > h3)      { dir = 1;  nearP = l1; farP = h3; }   // бычий → покупка от верхнего края
   else if(h1 < l3) { dir = -1; nearP = h1; farP = l3; }   // медвежий → продажа от нижнего края
   if(dir == 0)
      return false;
   if(MathAbs(nearP - farP) < c.minGapAtr * atr1)
      return false;
   double sd = MathAbs(nearP - farP) + c.buffer;
   if(sd > c.maxSlAtr * atr1)
      return false;
   sd = MathMax(sd, c.minSlAtr * atr1);
   const int n = ArraySize(g);
   ArrayResize(g, n + 1);
   g[n].t        = iTime(_Symbol, c.tf, 1);
   g[n].dir      = dir;
   g[n].nearP    = nearP;
   g[n].farP     = farP;
   g[n].sd       = sd;
   g[n].first    = 0;
   g[n].selected = false;
   g[n].ticket   = 0;
   return true;
  }

// Учёт на новом баре. spread — текущий спред (касание покупки — по Ask).
// Порядок как в симуляторе: (1) разрывы, выбранные на прошлом баре и задетые им, — отработаны;
// (2) новый разрыв; (3) закрытые насквозь, устаревшие и с истёкшей лимиткой — убираются;
// (4) выбор perSide ближайших в каждую сторону. Убранные разрывы с ticket != 0 возвращаются в
// dropTickets — их лимитки бот снимает. Возвращает число убранных из-за касания (отработанных).
int FvgOnNewBar(const FvgConfig &c, FvgGap &g[], const double atr1, const double spread, ulong &dropTickets[])
  {
   ArrayResize(dropTickets, 0);
   const double h1 = iHigh(_Symbol, c.tf, 1), l1 = iLow(_Symbol, c.tf, 1), c1 = iClose(_Symbol, c.tf, 1);
   const datetime t1 = iTime(_Symbol, c.tf, 1);
   int touched = 0;

   //--- (1) выбранные и задетые прошлым баром: исполнены (или пропущены при открытой позиции)
   for(int i = ArraySize(g) - 1; i >= 0; i--)
     {
      if(!g[i].selected)
         continue;
      const bool hit = (g[i].dir == 1) ? (l1 + spread <= g[i].nearP) : (h1 >= g[i].nearP);
      if(!hit)
         continue;
      if(g[i].ticket != 0)
        {
         const int k = ArraySize(dropTickets);
         ArrayResize(dropTickets, k + 1);
         dropTickets[k] = g[i].ticket;
        }
      FvgRemoveAt(g, i);
      touched++;
     }

   //--- (2) новый разрыв на барах 3, 2, 1
   FvgDetect(c, g, atr1);

   //--- (3) закрыт насквозь / устарел / срок лимитки истёк
   for(int i = ArraySize(g) - 1; i >= 0; i--)
     {
      const int  age  = iBarShift(_Symbol, c.tf, g[i].t, false) - 1;
      bool       drop = false;
      if(g[i].t < t1 && ((g[i].dir == 1 && l1 <= g[i].farP) || (g[i].dir == -1 && h1 >= g[i].farP)))
         drop = true;
      else if(g[i].first == 0 && age >= c.maxAge)
         drop = true;
      else if(g[i].first != 0 && iBarShift(_Symbol, c.tf, g[i].first, false) >= c.expiryBars)
         drop = true;
      if(!drop)
         continue;
      if(g[i].ticket != 0)
        {
         const int k = ArraySize(dropTickets);
         ArrayResize(dropTickets, k + 1);
         dropTickets[k] = g[i].ticket;
        }
      FvgRemoveAt(g, i);
     }

   //--- (4) выбор: в каждую сторону perSide ближайших к цене закрытия бара 1
   const datetime t0 = iTime(_Symbol, c.tf, 0);
   for(int i = 0; i < ArraySize(g); i++)
      g[i].selected = false;
   for(int side = -1; side <= 1; side += 2)
      for(int pick = 0; pick < c.perSide; pick++)
        {
         int best = -1;
         double bestD = DBL_MAX;
         for(int i = 0; i < ArraySize(g); i++)
           {
            if(g[i].dir != side || g[i].selected)
               continue;
            const int age = iBarShift(_Symbol, c.tf, g[i].t, false) - 1;
            if(age < c.minAge || age >= c.maxAge)
               continue;
            if(side == -1 ? (c1 >= g[i].nearP) : (c1 <= g[i].nearP))
               continue;   // цена уже на разрыве или за ним
            const double d = MathAbs(g[i].nearP - c1);
            if(d < bestD) { bestD = d; best = i; }
           }
         if(best < 0)
            break;
         g[best].selected = true;
         if(g[best].first == 0)
            g[best].first = t0;
        }
   return touched;
  }

#endif // FVGGAPS_MQH
//+------------------------------------------------------------------+
