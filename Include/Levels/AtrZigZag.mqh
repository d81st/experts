//+------------------------------------------------------------------+
//|                                                    AtrZigZag.mqh |
//|                                                                  |
//|  ATR-зигзаг по закрытым барам: точка разворота подтверждается,   |
//|  когда цена отошла от экстремума на порог (обычно N × ATR).      |
//|  Модуль хранит только состояние волны; что делать при новой      |
//|  точке (сменить диапазон, снять ордера) — решает бот.            |
//+------------------------------------------------------------------+
#ifndef ATRZIGZAG_MQH
#define ATRZIGZAG_MQH

//+------------------------------------------------------------------+
//| AtrZigZag — состояние зигзага.                                   |
//|   dir    — 0 направление не определено; +1 после минимума ищем   |
//|            максимум; -1 после максимума ищем минимум.            |
//|   cand*  — текущий экстремум развивающейся волны.                |
//|   piv*   — последние подтверждённые максимум и минимум.          |
//+------------------------------------------------------------------+
struct AtrZigZag
  {
   int      dir;
   double   candHi, candLo;
   datetime candHiT, candLoT;
   double   pivHi, pivLo;
   datetime pivHiT, pivLoT;
  };

void AtrZigZagReset(AtrZigZag &z)
  {
   z.dir = 0;
   z.candHi = 0.0; z.candLo = 0.0; z.candHiT = 0; z.candLoT = 0;
   z.pivHi  = 0.0; z.pivLo  = 0.0; z.pivHiT  = 0; z.pivLoT  = 0;
  }

//+------------------------------------------------------------------+
//| AtrZigZagStep — один закрытый бар (h, l, t), порог th в цене.    |
//| Возвращает +1 — подтверждён максимум, -1 — минимум, 0 — нет.     |
//| На баре, обновившем экстремум, разворот не проверяется.          |
//+------------------------------------------------------------------+
int AtrZigZagStep(AtrZigZag &z, const double h, const double l, const datetime t, const double th)
  {
   if(z.dir == 0)
     {
      if(z.candHiT == 0 || h > z.candHi) { z.candHi = h; z.candHiT = t; }
      if(z.candLoT == 0 || l < z.candLo) { z.candLo = l; z.candLoT = t; }
      if(z.candHiT < t && z.candHi - l >= th)
        {
         z.pivHi = z.candHi; z.pivHiT = z.candHiT;
         z.dir = -1; z.candLo = l; z.candLoT = t;
         return 1;
        }
      if(z.candLoT < t && h - z.candLo >= th)
        {
         z.pivLo = z.candLo; z.pivLoT = z.candLoT;
         z.dir = 1; z.candHi = h; z.candHiT = t;
         return -1;
        }
      return 0;
     }
   if(z.dir == 1)
     {
      if(h > z.candHi) { z.candHi = h; z.candHiT = t; return 0; }
      if(z.candHi - l >= th)
        {
         z.pivHi = z.candHi; z.pivHiT = z.candHiT;
         z.dir = -1; z.candLo = l; z.candLoT = t;
         return 1;
        }
      return 0;
     }
   if(l < z.candLo) { z.candLo = l; z.candLoT = t; return 0; }
   if(h - z.candLo >= th)
     {
      z.pivLo = z.candLo; z.pivLoT = z.candLoT;
      z.dir = 1; z.candHi = h; z.candHiT = t;
      return -1;
     }
   return 0;
  }

// Есть подтверждённые максимум и минимум (диапазон последней волны).
bool AtrZigZagHasRange(const AtrZigZag &z) { return z.pivHiT != 0 && z.pivLoT != 0; }

// Направление последней подтверждённой волны: +1 вверх (минимум раньше максимума), -1 вниз.
int AtrZigZagWaveDir(const AtrZigZag &z) { return (z.pivLoT < z.pivHiT) ? 1 : -1; }

#endif // ATRZIGZAG_MQH
//+------------------------------------------------------------------+
