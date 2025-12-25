//+------------------------------------------------------------------+
//| Pending Order Grid - Buy Limit                                  |
//| Compatible MT5                                                  |
//+------------------------------------------------------------------+
#property strict

input double StartPrice   = 1.2835;
input double StopPrice    = 1.2695;
input int    PriceLevel   = 11;

input ulong  MagicNumber  = 12345;
input double Volume       = 0.01;
input double FreeMarginPercent = 0.0;

input double StopLoss     = 0;
input double TakeProfit   = 0;

input string CommentEA    = "12345: Pending Order Grid";

void OnInit()
{
   PlaceGrid();
}

//+------------------------------------------------------------------+
void PlaceGrid()
{
   double step = (StartPrice - StopPrice) / (PriceLevel - 1);
   double price;

   for(int i = 0; i < PriceLevel; i++)
   {
      price = NormalizeDouble(StartPrice - step * i, _Digits);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action   = TRADE_ACTION_PENDING;
      req.symbol   = _Symbol;
      req.magic    = MagicNumber;
      req.volume   = Volume;
      req.price    = price;
      req.type     = ORDER_TYPE_BUY_LIMIT;
      req.deviation= 0;
      req.type_filling = ORDER_FILLING_FOK;
      req.type_time    = ORDER_TIME_GTC;
      req.comment  = CommentEA;

      if(StopLoss > 0)
         req.sl = NormalizeDouble(price - StopLoss * _Point, _Digits);

      if(TakeProfit > 0)
         req.tp = NormalizeDouble(price + TakeProfit * _Point, _Digits);

      if(!OrderSend(req, res))
      {
         Print("Order failed at price ", price, " Error: ", GetLastError());
      }
   }
}
//+------------------------------------------------------------------+
