//+------------------------------------------------------------------+
//|                                                  TradeAdapter.mqh |
//|                                                                  |
//| Тонкая абстракция над CTrade для тестируемости трейлинга.        |
//|                                                                  |
//|   ITradeAdapter    — абстрактный интерфейс (только три операции, |
//|                      необходимые для логики SyncTrail/Breakeven).|
//|   RealTradeAdapter — production-реализация, проксирующая CTrade. |
//|                                                                  |
//| MQL5 не имеет ключевого слова `interface`, поэтому используется  |
//| абстрактный класс с pure-virtual методами (`= 0`).               |
//|                                                                  |
//| Foundation для задач 8.x (error handling): позволяет тестам      |
//| подменить реальный CTrade на MockTradeAdapter и наблюдать вызовы |
//| PositionModify без побочных эффектов в терминале.                |
//+------------------------------------------------------------------+
#ifndef TRADEADAPTER_MQH
#define TRADEADAPTER_MQH

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ITradeAdapter — интерфейс адаптера                                |
//+------------------------------------------------------------------+
class ITradeAdapter
{
public:
   virtual           ~ITradeAdapter(void) {}

   // Модифицирует SL/TP открытой позиции. Возвращает true при успехе.
   virtual bool       PositionModify(const ulong ticket,
                                     const double sl,
                                     const double tp) = 0;

   // Код возврата последней торговой операции.
   virtual uint       ResultRetcode(void) const = 0;

   // Текстовое описание (комментарий) последней торговой операции.
   virtual string     ResultComment(void) const = 0;
};

//+------------------------------------------------------------------+
//| RealTradeAdapter — production-реализация поверх CTrade            |
//+------------------------------------------------------------------+
class RealTradeAdapter : public ITradeAdapter
{
private:
   CTrade            *m_trade;

public:
                     RealTradeAdapter(CTrade *tradePtr) : m_trade(tradePtr) {}
   virtual           ~RealTradeAdapter(void) {}

   virtual bool       PositionModify(const ulong ticket,
                                     const double sl,
                                     const double tp) override
   {
      return m_trade.PositionModify(ticket, sl, tp);
   }

   virtual uint       ResultRetcode(void) const override
   {
      return m_trade.ResultRetcode();
   }

   virtual string     ResultComment(void) const override
   {
      return m_trade.ResultComment();
   }
};

#endif // TRADEADAPTER_MQH
