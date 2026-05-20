//+------------------------------------------------------------------+
//|                                                   HJFX_v174.mq5 |
//|                              Recreated based on parameter inputs |
//|                         Grid + DCA Expert Advisor for XAUUSD M1  |
//+------------------------------------------------------------------+
#property copyright "HJFX"
#property version   "1.74"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade trade;
CPositionInfo posInfo;

//=== Risk Management ===
input double   StartingLot          = 0.01;
input double   LotMultiplier        = 2.0;
input int      MagicNumber          = 658717;
input bool     AutoTradingLoop      = true;

//=== Position Grid ===
input int      GridDistance         = 200;    // Grid Distance (pips)
input int      DCAModeRound1        = 3;      // DCA Mode Round 1 (2=Standard, 3=Strong)
input int      DCAModeRound2Plus    = 2;      // DCA Mode Round 2+ (2=Standard, 3=Strong)
input int      NoRepeatZone         = 100;    // No-repeat zone (pips from prev DCA price)
input int      LotCycleLength       = 7;      // Lot Cycle Length

//=== Manual First 3 Steps ===
input bool     EnableManual3Steps   = false;
input double   Step1Lot             = 0.05;   // Step 1 Lot (Entry)
input double   Step2Lot             = 0.05;   // Step 2 Lot (DCA #1)
input double   Step3Lot             = 0.05;   // Step 3 Lot (DCA #2)

//=== Profit & Protection ===
input double   MinTP                = 2.0;    // Min TP ($ per 0.01 lot)
input int      STLActivation        = 250;    // STL activation (pips profit)
input int      InitialSLLock        = 200;    // Initial SL lock (pips from B/E)
input int      TrailGap             = 100;    // Trail gap (peak - lock distance)
input int      TrailStep            = 10;     // Trail step (pips)
input bool     HiddenSL             = true;   // Hidden SL (true=EA internal)

//=== Daily Limits ===
input double   ProfitTargetDollar   = 0.0;    // Profit Target $ (0=Off)
input double   ProfitTargetPct      = 0.0;    // Profit Target % of Balance (0=Off)
input double   MaxDrawdownDollar    = 0.0;    // Max Drawdown $ (0=Off)
input double   MaxDrawdownPct       = 0.0;    // Max Drawdown % of Balance (0=Off)

//--- Internal Variables
double   pipSize;
double   peakProfit      = 0;
double   trailLockPrice  = 0;
bool     stlActivated    = false;
double   startBalance    = 0;
datetime lastBarTime     = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   pipSize = GetPipSize();
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("HJFX v1.74 initialized. PipSize=", pipSize);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("HJFX v1.74 deinitialized.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!AutoTradingLoop) return;

   // Daily limit checks
   if(CheckDailyLimits()) return;

   // Trailing stop logic
   ManageTrailingStop();

   // Grid/DCA logic — only on new bar to reduce noise
   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   int totalBuy  = CountPositions(ORDER_TYPE_BUY);
   int totalSell = CountPositions(ORDER_TYPE_SELL);

   // If no positions open, open first entry
   if(totalBuy == 0 && totalSell == 0)
   {
      OpenFirstTrade();
      return;
   }

   // DCA Logic for BUY positions
   if(totalBuy > 0)
      CheckDCA(ORDER_TYPE_BUY, totalBuy);

   // DCA Logic for SELL positions
   if(totalSell > 0)
      CheckDCA(ORDER_TYPE_SELL, totalSell);
}

//+------------------------------------------------------------------+
//| Open first trade (entry)                                         |
//+------------------------------------------------------------------+
void OpenFirstTrade()
{
   double lot   = EnableManual3Steps ? Step1Lot : StartingLot;
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread= ask - bid;

   // Simple trend: open BUY if price > recent MA, else SELL
   double ma = iMA(_Symbol, PERIOD_M1, 20, 0, MODE_EMA, PRICE_CLOSE);
   // Use current close as proxy
   double closeNow = iClose(_Symbol, PERIOD_M1, 1);

   double tp = 0; // TP managed dynamically

   if(closeNow >= ma)
   {
      double sl = HiddenSL ? 0 : ask - InitialSLLock * pipSize;
      trade.Buy(lot, _Symbol, ask, sl, tp, "HJFX_Entry_BUY");
      Print("BUY Entry opened. Lot=", lot, " Price=", ask);
   }
   else
   {
      double sl = HiddenSL ? 0 : bid + InitialSLLock * pipSize;
      trade.Sell(lot, _Symbol, bid, sl, tp, "HJFX_Entry_SELL");
      Print("SELL Entry opened. Lot=", lot, " Price=", bid);
   }

   peakProfit   = 0;
   stlActivated = false;
   trailLockPrice = 0;
}

//+------------------------------------------------------------------+
//| DCA: Add position if price moves against us by GridDistance      |
//+------------------------------------------------------------------+
void CheckDCA(ENUM_ORDER_TYPE direction, int count)
{
   double lastPrice = GetLastOpenPrice(direction);
   if(lastPrice <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double distancePips = 0;
   if(direction == ORDER_TYPE_BUY)
      distancePips = (lastPrice - bid) / pipSize;
   else
      distancePips = (ask - lastPrice) / pipSize;

   if(distancePips < GridDistance) return;

   // No-repeat zone check
   if(distancePips < NoRepeatZone) return;

   // Determine DCA lot
   double dcaLot = CalcDCALot(count);

   double sl = 0, tp = 0;

   if(direction == ORDER_TYPE_BUY)
   {
      if(!HiddenSL)
      {
         double be = CalcBreakeven(ORDER_TYPE_BUY);
         sl = be - InitialSLLock * pipSize;
      }
      trade.Buy(dcaLot, _Symbol, ask, sl, tp, "HJFX_DCA_BUY_" + IntegerToString(count));
      Print("DCA BUY #", count, " opened. Lot=", dcaLot, " Price=", ask);
   }
   else
   {
      if(!HiddenSL)
      {
         double be = CalcBreakeven(ORDER_TYPE_SELL);
         sl = be + InitialSLLock * pipSize;
      }
      trade.Sell(dcaLot, _Symbol, bid, sl, tp, "HJFX_DCA_SELL_" + IntegerToString(count));
      Print("DCA SELL #", count, " opened. Lot=", dcaLot, " Price=", bid);
   }
}

//+------------------------------------------------------------------+
//| Calculate DCA lot based on count and mode                        |
//+------------------------------------------------------------------+
double CalcDCALot(int count)
{
   // Manual first 3 steps override
   if(EnableManual3Steps)
   {
      if(count == 1) return NormalizeLot(Step2Lot);
      if(count == 2) return NormalizeLot(Step3Lot);
   }

   // Determine multiplier mode
   int mode = (count == 1) ? DCAModeRound1 : DCAModeRound2Plus;

   // Cycle index within LotCycleLength
   int cyclePos = (count - 1) % LotCycleLength;

   double lot = StartingLot;
   for(int i = 0; i < cyclePos; i++)
      lot *= LotMultiplier;

   // Mode 3 = stronger (extra multiplier on last step of cycle)
   if(mode == 3 && cyclePos == LotCycleLength - 1)
      lot *= LotMultiplier;

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Trailing Stop Logic (STL)                                        |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double totalProfit = GetTotalProfit();
   double totalLots   = GetTotalLots(ORDER_TYPE_BUY) + GetTotalLots(ORDER_TYPE_SELL);
   if(totalLots <= 0) return;

   // Dynamic TP: MinTP per 0.01 lot
   double minProfitTarget = MinTP * (totalLots / 0.01);

   // STL activation check
   double profitPips = GetProfitInPips();

   if(!stlActivated && profitPips >= STLActivation)
   {
      stlActivated = true;
      peakProfit = profitPips;
      Print("STL Activated at ", profitPips, " pips profit.");
   }

   if(stlActivated)
   {
      if(profitPips > peakProfit)
         peakProfit = profitPips;

      double lockLevel = peakProfit - TrailGap;

      // Close all if profit dropped below lock level
      if(profitPips <= lockLevel && totalProfit >= minProfitTarget)
      {
         Print("STL triggered. Closing all. Profit=", totalProfit);
         CloseAllPositions();
         return;
      }
   }

   // Hidden SL: internal break-even protection
   if(HiddenSL)
   {
      double be = CalcBreakeven(ORDER_TYPE_BUY);
      double beSell = CalcBreakeven(ORDER_TYPE_SELL);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(GetTotalLots(ORDER_TYPE_BUY) > 0 && bid < be - InitialSLLock * pipSize)
      {
         Print("Hidden SL triggered for BUY.");
         ClosePositionsByType(ORDER_TYPE_BUY);
      }
      if(GetTotalLots(ORDER_TYPE_SELL) > 0 && ask > beSell + InitialSLLock * pipSize)
      {
         Print("Hidden SL triggered for SELL.");
         ClosePositionsByType(ORDER_TYPE_SELL);
      }
   }
}

//+------------------------------------------------------------------+
//| Daily Limits Check                                               |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit  = equity - startBalance;

   // Profit Target $
   if(ProfitTargetDollar > 0 && profit >= ProfitTargetDollar)
   {
      Print("Daily Profit Target $ reached: ", profit);
      CloseAllPositions();
      return true;
   }
   // Profit Target %
   if(ProfitTargetPct > 0 && profit >= balance * ProfitTargetPct / 100.0)
   {
      Print("Daily Profit Target % reached.");
      CloseAllPositions();
      return true;
   }
   // Max Drawdown $
   if(MaxDrawdownDollar > 0 && profit <= -MaxDrawdownDollar)
   {
      Print("Max Drawdown $ hit.");
      CloseAllPositions();
      return true;
   }
   // Max Drawdown %
   if(MaxDrawdownPct > 0 && profit <= -(balance * MaxDrawdownPct / 100.0))
   {
      Print("Max Drawdown % hit.");
      CloseAllPositions();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Count positions by type                                  |
//+------------------------------------------------------------------+
int CountPositions(ENUM_ORDER_TYPE type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if((type == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (type == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL))
               count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Helper: Get last open price for direction                        |
//+------------------------------------------------------------------+
double GetLastOpenPrice(ENUM_ORDER_TYPE type)
{
   double lastPrice = 0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if((type == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (type == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL))
               if(posInfo.Time() > lastTime)
               {
                  lastTime  = posInfo.Time();
                  lastPrice = posInfo.PriceOpen();
               }
   }
   return lastPrice;
}

//+------------------------------------------------------------------+
//| Helper: Calculate weighted breakeven price                       |
//+------------------------------------------------------------------+
double CalcBreakeven(ENUM_ORDER_TYPE type)
{
   double totalVolume = 0, totalCost = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if((type == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (type == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL))
            {
               totalVolume += posInfo.Volume();
               totalCost   += posInfo.PriceOpen() * posInfo.Volume();
            }
   }
   return (totalVolume > 0) ? totalCost / totalVolume : 0;
}

//+------------------------------------------------------------------+
//| Helper: Get total lots by type                                   |
//+------------------------------------------------------------------+
double GetTotalLots(ENUM_ORDER_TYPE type)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if((type == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (type == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL))
               total += posInfo.Volume();
   }
   return total;
}

//+------------------------------------------------------------------+
//| Helper: Get total floating profit                                |
//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            total += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   }
   return total;
}

//+------------------------------------------------------------------+
//| Helper: Get approximate profit in pips                           |
//+------------------------------------------------------------------+
double GetProfitInPips()
{
   double buyBE  = CalcBreakeven(ORDER_TYPE_BUY);
   double sellBE = CalcBreakeven(ORDER_TYPE_SELL);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pips   = 0;

   if(buyBE  > 0) pips += (bid - buyBE)  / pipSize * GetTotalLots(ORDER_TYPE_BUY);
   if(sellBE > 0) pips += (sellBE - ask) / pipSize * GetTotalLots(ORDER_TYPE_SELL);
   return pips;
}

//+------------------------------------------------------------------+
//| Helper: Close all positions                                      |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            trade.PositionClose(posInfo.Ticket());
   }
   peakProfit   = 0;
   stlActivated = false;
}

//+------------------------------------------------------------------+
//| Helper: Close positions by type                                  |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_ORDER_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if((type == ORDER_TYPE_BUY  && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (type == ORDER_TYPE_SELL && posInfo.PositionType() == POSITION_TYPE_SELL))
               trade.PositionClose(posInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| Helper: Get pip size (accounts for 5-digit brokers)             |
//+------------------------------------------------------------------+
double GetPipSize()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // XAUUSD typically 2 digits: 1 pip = 0.01
   if(digits == 2) return point * 10;
   if(digits == 3) return point * 10;
   if(digits == 5) return point * 10;
   return point * 10;
}

//+------------------------------------------------------------------+
//| Helper: Normalize lot to broker requirements                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   lot = MathRound(lot / lotStep) * lotStep;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
