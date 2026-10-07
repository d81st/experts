//+------------------------------------------------------------------+
//|                                                 MarketRegime.mqh |
//|                                                                  |
//|  Режим рынка: тренд или флэт. Мера — коэффициент эффективности   |
//|  (Kaufman ER) по закрытым барам: путь цены «по прямой» за N баров|
//|  делённый на сумму всех шагов. 1 — цена шла в одну сторону,      |
//|  около 0 — топталась на месте.                                   |
//|  Режим подключается к любому боту: выключен / торговать только в |
//|  тренде / в тренде — по сигналу, во флэте — против сигнала.      |
//+------------------------------------------------------------------+
#ifndef MARKETREGIME_MQH
#define MARKETREGIME_MQH

enum ENUM_REGIME_MODE
  {
   REGIME_OFF    = 0,  // Выключен
   REGIME_FILTER = 1,  // Входить только в тренде
   REGIME_SWITCH = 2   // Тренд — по сигналу, флэт — против сигнала
  };

//+------------------------------------------------------------------+
//| MarketRegimeConfig                                               |
//|   tf, period — бары, по которым считается ER                     |
//|   threshold  — ER ≥ порога — тренд, ниже — флэт                  |
//+------------------------------------------------------------------+
struct MarketRegimeConfig
  {
   ENUM_REGIME_MODE mode;
   ENUM_TIMEFRAMES  tf;
   int              period;
   double           threshold;
  };

// ER по закрытым барам tf (бары 1 … period+1); -1 — не хватает истории.
double MarketRegimeER(const MarketRegimeConfig &c)
  {
   double cl[];
   ArraySetAsSeries(cl, true);
   if(c.period < 1 || CopyClose(_Symbol, c.tf, 1, c.period + 1, cl) < c.period + 1)
      return -1.0;
   double path = 0.0;
   for(int i = 0; i < c.period; i++)
      path += MathAbs(cl[i] - cl[i + 1]);
   return (path > 0.0) ? MathAbs(cl[0] - cl[c.period]) / path : 0.0;
  }

// +1 тренд, -1 флэт, 0 — неизвестно (мало истории).
int MarketRegimeGet(const MarketRegimeConfig &c)
  {
   const double er = MarketRegimeER(c);
   if(er < 0.0)
      return 0;
   return (er >= c.threshold) ? 1 : -1;
  }

//+------------------------------------------------------------------+
//| MarketRegimeApply — направление сделки с учётом режима.          |
//| dir — сигнал бота (+1/-1). Возвращает +1/-1 или 0 (не входить).  |
//| Выключен — dir; фильтр — dir в тренде, 0 во флэте; переключатель |
//| — dir в тренде, -dir во флэте. Режим неизвестен — 0 (кроме OFF). |
//+------------------------------------------------------------------+
int MarketRegimeApply(const MarketRegimeConfig &c, const int dir)
  {
   if(c.mode == REGIME_OFF)
      return dir;
   const int r = MarketRegimeGet(c);
   if(r == 0)
      return 0;
   if(r == 1)
      return dir;
   return (c.mode == REGIME_SWITCH) ? -dir : 0;
  }

#endif // MARKETREGIME_MQH
//+------------------------------------------------------------------+
