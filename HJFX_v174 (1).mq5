//+------------------------------------------------------------------+
//|                                                   HJFX_v174.mq5 |
//|                         Grid + DCA EA for XAUUSD                 |
//|                         Fixed Version                            |
//+------------------------------------------------------------------+
#property copyright "HJFX"
#property version   "1.74"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//=== Risk Management ===
input double StartingLot        = 0.01;
input double LotMultiplier      = 2.0;
input int    MagicNumber        = 658717;
input bool   AutoTradingLoop    = true;

//=== Position Grid ===
input int    GridDistance       = 200;   // Grid Distance (pips)
input int    DCAModeRound1      = 3;     // DCA Mode Round 1 (2=Standard,3=Strong)
input int    DCAModeRound2Plus  = 2;     // DCA Mode Round 2+ (2=Standard,3=Strong)
input int    NoRepeatZone       = 100;   // No-repeat zone (pips from prev DCA price)
input int    LotCycleLength     = 7;     // Lot Cycle Length

//=== Manual First 3 Steps ===
input bool   EnableManual3Steps = false;
input double Step1Lot           = 0.05;
input double Step2Lot           = 0.05;
input double Step3Lot           = 0.05;

//=== Profit & Protection ===
input double MinTP              = 2.0;   // Min TP ($ per 0.01 lot)
input int    STLActivation      = 250;   // STL activation (pips profit)
input int    InitialSLLock      = 200;   // Initial SL lock (pips from B/E)
input int    TrailGap           = 100;   // Trail gap (peak - lock distance)
input int    TrailStep          = 10;    // Trail step (pips)
input bool   HiddenSL           = true;  // Hidden SL (true=EA internal)

//=== Daily Limits ===
input double ProfitTargetDollar = 0.0;
input double ProfitTargetPct    = 0.0;
input double MaxDrawdownDollar  = 0.0;
input double MaxDrawdownPct     = 0.0;

//=== Entry Direction ===
// 0=Auto(EMA), 1=BUY only, 2=SELL only, 3=Hedge(both)
input int    EntryMode          = 1;     // Entry Mode (1=BUY only, 2=SELL only, 0=Auto)

//--- Internal
double   pipSize;
double   peakProfitPips = 0;
bool     stlActivated   = false;
double   startBalance   = 0;
int      maHandle       = INVALID_HANDLE;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   pipSize      = GetPipSize();
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   maHandle = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create MA handle");
      return INIT_FAILED;
   }

   Print("HJFX v1.74 initialized | PipSize=", pipSize,
         " | Symbol=", _Symbol,
         " | EntryMode=", EntryMode);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(maHandle != INVALID_HANDLE) IndicatorRelease(maHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!AutoTradingLoop) return;
   if(CheckDailyLimits()) return;

   ManageTrailingStop();

   int totalBuy  = CountPositions(POSITION_TYPE_BUY);
   int totalSell = CountPositions(POSITION_TYPE_SELL);

   //--- No positions: open first entry
   if(totalBuy == 0 && totalSell == 0)
   {
      OpenFirstTrade();
      return;
   }

   //--- DCA check on every tick (grid-based, not bar-based)
   if(totalBuy > 0)  CheckDCA(POSITION_TYPE_BUY,  totalBuy);
   if(totalSell > 0) CheckDCA(POSITION_TYPE_SELL, totalSell);
}

//+------------------------------------------------------------------+
//| Open first trade                                                  |
//+------------------------------------------------------------------+
void OpenFirstTrade()
{
   double lot = EnableManual3Steps ? NormalizeLot(Step1Lot) : NormalizeLot(StartingLot);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool doBuy  = false;
   bool doSell = false;

   if(EntryMode == 1) { doBuy  = true; }
   else if(EntryMode == 2) { doSell = true; }
   else if(EntryMode == 3) { doBuy  = true; doSell = true; }
   else // Auto: EMA direction
   {
      double maVal[1];
      if(CopyBuffer(maHandle, 0, 1, 1, maVal) > 0)
      {
         if(bid > maVal[0]) doBuy  = true;
         else               doSell = true;
      }
      else { Print("MA copy failed"); return; }
   }

   if(doBuy)
   {
      double sl = HiddenSL ? 0.0 : NormalizeDouble(ask - InitialSLLock * pipSize, _Digits);
      if(trade.Buy(lot, _Symbol, ask, sl, 0, "HJFX_Entry"))
         Print("BUY Entry | Lot=", lot, " Price=", ask);
      else
         Print("BUY Entry FAILED: ", trade.ResultRetcodeDescription());
   }

   if(doSell)
   {
      double sl = HiddenSL ? 0.0 : NormalizeDouble(bid + InitialSLLock * pipSize, _Digits);
      if(trade.Sell(lot, _Symbol, bid, sl, 0, "HJFX_Entry"))
         Print("SELL Entry | Lot=", lot, " Price=", bid);
      else
         Print("SELL Entry FAILED: ", trade.ResultRetcodeDescription());
   }

   peakProfitPips = 0;
   stlActivated   = false;
}

//+------------------------------------------------------------------+
//| DCA: add position when price moves GridDistance against us       |
//+------------------------------------------------------------------+
void CheckDCA(ENUM_POSITION_TYPE ptype, int count)
{
   double lastPrice = GetLastOpenPrice(ptype);
   if(lastPrice <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double distancePips = 0;
   if(ptype == POSITION_TYPE_BUY)
      distancePips = (lastPrice - bid) / pipSize;   // price fell below last buy
   else
      distancePips = (ask - lastPrice) / pipSize;   // price rose above last sell

   // Not far enough yet
   if(distancePips < GridDistance) return;

   // No-repeat zone: don't add if we already have a position within NoRepeatZone pips
   double closestDist = GetClosestPositionDistance(ptype);
   if(closestDist < NoRepeatZone) return;

   double dcaLot = CalcDCALot(count);
   double sl     = 0;

   if(ptype == POSITION_TYPE_BUY)
   {
      if(!HiddenSL)
      {
         double be = CalcBreakeven(POSITION_TYPE_BUY);
         sl = NormalizeDouble(be - InitialSLLock * pipSize, _Digits);
      }
      if(trade.Buy(dcaLot, _Symbol, ask, sl, 0, "HJFX_DCA_B" + IntegerToString(count)))
         Print("DCA BUY #", count, " | Lot=", dcaLot, " Price=", ask, " Dist=", distancePips, " pips");
      else
         Print("DCA BUY #", count, " FAILED: ", trade.ResultRetcodeDescription());
   }
   else
   {
      if(!HiddenSL)
      {
         double be = CalcBreakeven(POSITION_TYPE_SELL);
         sl = NormalizeDouble(be + InitialSLLock * pipSize, _Digits);
      }
      if(trade.Sell(dcaLot, _Symbol, bid, sl, 0, "HJFX_DCA_S" + IntegerToString(count)))
         Print("DCA SELL #", count, " | Lot=", dcaLot, " Price=", bid, " Dist=", distancePips, " pips");
      else
         Print("DCA SELL #", count, " FAILED: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Calculate DCA lot                                                 |
//+------------------------------------------------------------------+
double CalcDCALot(int count)
{
   if(EnableManual3Steps)
   {
      if(count == 1) return NormalizeLot(Step2Lot);
      if(count == 2) return NormalizeLot(Step3Lot);
   }

   int mode     = (count == 1) ? DCAModeRound1 : DCAModeRound2Plus;
   int cyclePos = (count - 1) % LotCycleLength;

   double lot = StartingLot;
   for(int i = 0; i < cyclePos; i++)
      lot *= LotMultiplier;

   if(mode == 3 && cyclePos == LotCycleLength - 1)
      lot *= LotMultiplier;

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Trailing Stop / STL                                               |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double totalLots = GetTotalLots(POSITION_TYPE_BUY) + GetTotalLots(POSITION_TYPE_SELL);
   if(totalLots <= 0) return;

   double minProfitTarget = MinTP * (totalLots / 0.01);
   double totalProfit     = GetTotalProfit();
   double profitPips      = GetProfitInPips();

   // STL activation
   if(!stlActivated && profitPips >= STLActivation)
   {
      stlActivated   = true;
      peakProfitPips = profitPips;
      Print("STL Activated at ", DoubleToString(profitPips, 1), " pips");
   }

   if(stlActivated)
   {
      if(profitPips > peakProfitPips)
         peakProfitPips = profitPips;

      double lockLevel = peakProfitPips - TrailGap;

      if(profitPips <= lockLevel && totalProfit >= minProfitTarget)
      {
         Print("STL Triggered | Profit=", DoubleToString(totalProfit, 2), " USD");
         CloseAllPositions();
         return;
      }
   }

   // Hidden SL protection
   if(HiddenSL)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(GetTotalLots(POSITION_TYPE_BUY) > 0)
      {
         double be = CalcBreakeven(POSITION_TYPE_BUY);
         if(be > 0 && bid < be - InitialSLLock * pipSize)
         {
            Print("Hidden SL BUY triggered | BE=", be, " Bid=", bid);
            ClosePositionsByType(POSITION_TYPE_BUY);
         }
      }
      if(GetTotalLots(POSITION_TYPE_SELL) > 0)
      {
         double be = CalcBreakeven(POSITION_TYPE_SELL);
         if(be > 0 && ask > be + InitialSLLock * pipSize)
         {
            Print("Hidden SL SELL triggered | BE=", be, " Ask=", ask);
            ClosePositionsByType(POSITION_TYPE_SELL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Daily Limits                                                      |
//+------------------------------------------------------------------+
bool CheckDailyLimits()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit  = equity - startBalance;

   if(ProfitTargetDollar > 0 && profit >= ProfitTargetDollar)
   { Print("Daily Profit Target $ hit"); CloseAllPositions(); return true; }

   if(ProfitTargetPct > 0 && profit >= balance * ProfitTargetPct / 100.0)
   { Print("Daily Profit Target % hit"); CloseAllPositions(); return true; }

   if(MaxDrawdownDollar > 0 && profit <= -MaxDrawdownDollar)
   { Print("Max Drawdown $ hit"); CloseAllPositions(); return true; }

   if(MaxDrawdownPct > 0 && profit <= -(balance * MaxDrawdownPct / 100.0))
   { Print("Max Drawdown % hit"); CloseAllPositions(); return true; }

   return false;
}

//+------------------------------------------------------------------+
//| Count positions by type                                           |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE ptype)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
               count++;
   return count;
}

//+------------------------------------------------------------------+
//| Get price of most recently opened position of given type         |
//+------------------------------------------------------------------+
double GetLastOpenPrice(ENUM_POSITION_TYPE ptype)
{
   double   lastPrice = 0;
   datetime lastTime  = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
               if(posInfo.Time() > lastTime)
               { lastTime = posInfo.Time(); lastPrice = posInfo.PriceOpen(); }
   return lastPrice;
}

//+------------------------------------------------------------------+
//| Get distance (pips) from current price to closest position       |
//+------------------------------------------------------------------+
double GetClosestPositionDistance(ENUM_POSITION_TYPE ptype)
{
   double minDist = 1e9;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
            {
               double dist = (ptype == POSITION_TYPE_BUY)
                  ? MathAbs(posInfo.PriceOpen() - bid) / pipSize
                  : MathAbs(posInfo.PriceOpen() - ask) / pipSize;
               if(dist < minDist) minDist = dist;
            }
   return minDist;
}

//+------------------------------------------------------------------+
//| Weighted breakeven price                                          |
//+------------------------------------------------------------------+
double CalcBreakeven(ENUM_POSITION_TYPE ptype)
{
   double vol = 0, cost = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
            { vol += posInfo.Volume(); cost += posInfo.PriceOpen() * posInfo.Volume(); }
   return (vol > 0) ? cost / vol : 0;
}

//+------------------------------------------------------------------+
double GetTotalLots(ENUM_POSITION_TYPE ptype)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
               total += posInfo.Volume();
   return total;
}

//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            total += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   return total;
}

//+------------------------------------------------------------------+
//| Profit in pips (weighted average across all positions)           |
//+------------------------------------------------------------------+
double GetProfitInPips()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pips = 0;

   double beBuy  = CalcBreakeven(POSITION_TYPE_BUY);
   double beSell = CalcBreakeven(POSITION_TYPE_SELL);
   double lotBuy  = GetTotalLots(POSITION_TYPE_BUY);
   double lotSell = GetTotalLots(POSITION_TYPE_SELL);
   double totalLot = lotBuy + lotSell;

   if(totalLot <= 0) return 0;

   if(beBuy  > 0 && lotBuy  > 0) pips += (bid - beBuy)  / pipSize * (lotBuy  / totalLot);
   if(beSell > 0 && lotSell > 0) pips += (beSell - ask)  / pipSize * (lotSell / totalLot);

   return pips;
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            trade.PositionClose(posInfo.Ticket());
   peakProfitPips = 0;
   stlActivated   = false;
}

void ClosePositionsByType(ENUM_POSITION_TYPE ptype)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == MagicNumber)
            if(posInfo.PositionType() == ptype)
               trade.PositionClose(posInfo.Ticket());
}

//+------------------------------------------------------------------+
//| Pip size for XAUUSD (2 decimal = 0.10 per pip)                  |
//+------------------------------------------------------------------+
double GetPipSize()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   // XAUUSD: digits=2, point=0.01 → 1 pip = 0.10
   // Forex 5-digit: point=0.00001 → 1 pip = 0.0001
   if(digits == 2) return point;       // XAUUSD: 1 pip = 0.01
   if(digits == 3) return point * 10;
   if(digits == 5) return point * 10;
   return point * 10;
}

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
