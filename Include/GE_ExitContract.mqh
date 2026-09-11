//+------------------------------------------------------------------+
//| GE_ExitContract.mqh                                              |
//| Single source of truth for what happens AFTER a trade opens.     |
//|                                                                  |
//| INTEGRATED HERE (Original Sentinel Exit Engine):                 |
//|   - CTradeSafe: SL/TP enforcing trade wrapper                    |
//|   - CheckExitContract():                                         |
//|       (a) 4h time-decay close (InpMaxHoldMinutes)                |
//|       (b) ONNX reversal-exit (opposite prob >= InpExitReversalP) |
//|   - CheckExitContractTick():                                     |
//|       (a) Method A: USD Step Ladder Trail ($15->$10, $30->$15...) |
//|       (b) Method B: Dynamic ATR Volatility Trailing (2.5x ATR)    |
//|           (1.5x wider in trend, 0.7x tighter in chop)            |
//+------------------------------------------------------------------+
#ifndef GE_EXITCONTRACT_MQH
#define GE_EXITCONTRACT_MQH

#include <GE_RiskManagement.mqh>
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Exit Contract Inputs                                             |
//+------------------------------------------------------------------+
input group "=== Original Sentinel SL Trailing & Profit Lock Engine ==="
input bool   InpUseLadderTrail        = true;   // Enable Sentinel Trailing Stop-Loss Engine
input bool   InpUseStepLadder         = true;   // Method A: USD Step Ladder Trail ($15 -> $10, $30 -> $15...)
input double InpStepSizeUSD           = 15.0;   // Step Size and Trailing Buffer in USD ($15.00)
input bool   InpUseATRTrailing        = true;   // Method B: Dynamic ATR Volatility Trailing (if StepLadder disabled)
input double InpTrailLockUSD          = 15.0;   // Unrealized Profit in USD to start ATR trailing ($15.00)
input double InpTrailDistUSD          = 15.0;   // Fallback Trailing Distance in USD ($15.00)
input double InpTrailATRMultiplier    = 2.5;    // Trailing Stop Distance in ATRs (2.5x ATR)

input group "=== Initial Risk Contract (SL / TP / Reversal) ==="
input bool   InpUseATRStopLoss        = true;   // Use ATR-based SL/TP instead of fixed-USD distances
input double InpATRMultiplier         = 4.0;    // Initial SL = InpATRMultiplier x ATR(14) (4.0x ATR)
input double InpFomoRRRatio           = 2.0;    // Initial TP = SL x InpFomoRRRatio (8.0x ATR => 1:2 RR)
input double InpFixedRiskUSD          = 25.0;   // FIXED loss per trade in account USD (structural fallback)
input double InpExitSLDistUSD         = 20.0;   // Reference SL distance used for lot-sizing math
input double InpExitTPDistUSD         = 50.0;   // Take-profit distance in USD
input int    InpMaxHoldMinutes        = 0;      // Max time in position before forced close (0 = DISABLED)
input double InpExitReversalP         = 0.60;   // ONNX probability that flips a position to opposite side
input bool   InpExitReversalAllowLoss = true;   // Close LOSING trades on ONNX reversal

input group "=== Delta-Flip Fast Loss Cutter Engine ==="
input bool   InpUseDeltaFlipExit       = true;   // Enable Order Flow Delta-Flip Early Exit
input int    InpDeltaFlipBarsRequired  = 2;      // Consecutive M5 Bars with opposing Delta (default: 2 bars)
input double InpDeltaFlipThreshold     = 4.0;    // Delta magnitude to trigger exit (e.g. >= +4.0 for SELL, <= -4.0 for BUY)
input bool   InpDeltaFlipOnlyLosing    = true;   // Only apply Delta-Flip exit to losing positions (let winning positions trail)

// Structure to track opposing delta bars per ticket
struct SDeltaFlipTracker
{
   ulong ticket;
   int   opposingBars;
};

SDeltaFlipTracker g_deltaFlipTrackers[32];
int               g_deltaFlipTrackerCount = 0;

void PruneDeltaFlipTrackers()
{
   for(int k = g_deltaFlipTrackerCount - 1; k >= 0; k--)
   {
      ulong t = g_deltaFlipTrackers[k].ticket;
      bool exists = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetTicket(i) == t)
         {
            exists = true;
            break;
         }
      }
      if(!exists)
      {
         for(int j = k; j < g_deltaFlipTrackerCount - 1; j++)
            g_deltaFlipTrackers[j] = g_deltaFlipTrackers[j+1];
         g_deltaFlipTrackerCount--;
      }
   }
}

//+------------------------------------------------------------------+
//| PriceDistForLoss — convert USD amount into price distance         |
//+------------------------------------------------------------------+
double PriceDistForLoss(const double usdAmount, const double lot)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || lot <= 0.0)
      return 0.0;
   return usdAmount * tickSize / (lot * tickValue);
}

//+------------------------------------------------------------------+
//| CTradeSafe — Order Execution Wrapper                             |
//+------------------------------------------------------------------+
class CTradeSafe : public CTrade
{
public:
   bool BuySafe(const double lot, const string symbol, const double slDistUSD, const double tpDistUSD, const double price = 0.0)
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDistUSD, _Digits);
      double tp  = (tpDistUSD > 0.0) ? NormalizeDouble(ask + tpDistUSD, _Digits) : 0.0;
      SetTypeFillingBySymbol(symbol);
      return Buy(lot, symbol, price, sl, tp);
   }

   bool SellSafe(const double lot, const string symbol, const double slDistUSD, const double tpDistUSD, const double price = 0.0)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDistUSD, _Digits);
      double tp  = (tpDistUSD > 0.0) ? NormalizeDouble(bid - tpDistUSD, _Digits) : 0.0;
      SetTypeFillingBySymbol(symbol);
      return Sell(lot, symbol, price, sl, tp);
   }
};

//+------------------------------------------------------------------+
//| CheckExitContract — Time-decay, ONNX & Delta-Flip reversal-exit  |
//+------------------------------------------------------------------+
void CheckExitContract(const double onnxBull, const double onnxBear, const bool onnxValid)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long     type     = PositionGetInteger(POSITION_TYPE);
      double   profit   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      // (a) Time-decay close
      if(InpMaxHoldMinutes > 0 && openTime > 0)
      {
         int heldMinutes = (int)((TimeCurrent() - openTime) / 60);
         if(heldMinutes >= InpMaxHoldMinutes)
         {
            CTradeSafe trade;
            trade.PositionClose(ticket);
            PrintFormat("[ExitContract] #%I64u closed on time-decay (%d mins >= %d max hold, PnL=%.2f).",
                        ticket, heldMinutes, InpMaxHoldMinutes, profit);
            continue;
         }
      }

      // (b) ONNX reversal-exit
      if(onnxValid)
      {
         bool flipCondition = false;
         if(type == POSITION_TYPE_BUY  && onnxBear >= InpExitReversalP) flipCondition = true;
         if(type == POSITION_TYPE_SELL && onnxBull >= InpExitReversalP) flipCondition = true;

         if(flipCondition)
         {
            if(profit > 0.0 || InpExitReversalAllowLoss)
            {
               CTradeSafe trade;
               trade.PositionClose(ticket);
               PrintFormat("[ExitContract] #%I64u closed on ONNX reversal (type=%s, bull=%.3f, bear=%.3f, PnL=%.2f).",
                           ticket, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), onnxBull, onnxBear, profit);
               continue;
            }
         }
      }

      // (c) Delta-Flip Fast Emergency Exit (Order Flow Loss Cutter)
      if(InpUseDeltaFlipExit && g_masterValid)
      {
         bool isOpposingDelta = false;
         if(type == POSITION_TYPE_BUY  && g_masterDelta <= -InpDeltaFlipThreshold)
            isOpposingDelta = true;
         else if(type == POSITION_TYPE_SELL && g_masterDelta >= InpDeltaFlipThreshold)
            isOpposingDelta = true;

         int trackerIdx = -1;
         for(int k = 0; k < g_deltaFlipTrackerCount; k++)
         {
            if(g_deltaFlipTrackers[k].ticket == ticket)
            {
               trackerIdx = k;
               break;
            }
         }

         if(trackerIdx == -1 && g_deltaFlipTrackerCount < 32)
         {
            trackerIdx = g_deltaFlipTrackerCount++;
            g_deltaFlipTrackers[trackerIdx].ticket = ticket;
            g_deltaFlipTrackers[trackerIdx].opposingBars = 0;
         }

         if(trackerIdx >= 0)
         {
            if(isOpposingDelta)
               g_deltaFlipTrackers[trackerIdx].opposingBars++;
            else
               g_deltaFlipTrackers[trackerIdx].opposingBars = 0;

            if(g_deltaFlipTrackers[trackerIdx].opposingBars >= InpDeltaFlipBarsRequired)
            {
               if(!InpDeltaFlipOnlyLosing || profit < 0.0)
               {
                  CTradeSafe trade;
                  trade.PositionClose(ticket);
                  PrintFormat("[ExitContract] #%I64u closed on DELTA-FLIP EMERGENCY EXIT (type=%s, delta=%.2f opposing for %d bars, PnL=%.2f USD).",
                              ticket, (type == POSITION_TYPE_BUY ? "BUY" : "SELL"), g_masterDelta,
                              g_deltaFlipTrackers[trackerIdx].opposingBars, profit);
                  continue;
               }
            }
         }
      }
   }

   PruneDeltaFlipTrackers();
}

//+------------------------------------------------------------------+
//| CheckExitContractTick — Evaluated on every tick to trail stops   |
//| (Method A: USD Step Ladder Trail | Method B: Dynamic ATR Trail)  |
//+------------------------------------------------------------------+
void CheckExitContractTick()
{
   if(!InpUseLadderTrail)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      ENUM_POSITION_TYPE type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double             lot    = PositionGetDouble(POSITION_VOLUME);

      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double entryPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL    = PositionGetDouble(POSITION_SL);
      double currentTP    = PositionGetDouble(POSITION_TP);

      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0 || lot <= 0.0)
         continue;

      double targetSL = 0.0;
      bool modifyNeeded = false;

      //=== METHOD A: USD-based Step Ladder Trail (locks in $5 at $10 for $10 step, $10 at $15 for $15 step, scaling infinitely) ===
      if(InpUseStepLadder)
      {
         double activeStep = GetActiveStepSizeUSD(InpStepSizeUSD);
         double lockedProfitUSD = 0.0;
         
         if(activeStep <= 10.0)
         {
            if(profit >= activeStep && profit < 2.0 * activeStep)
            {
               // First step (e.g. $10.00 to $19.99): lock $5.00 (+USD buffer)
               lockedProfitUSD = activeStep * 0.5;
            }
            else if(profit >= 2.0 * activeStep)
            {
               // Subsequent steps ($20 -> $10, $30 -> $20, $40 -> $30, $50 -> $40... infinitely until closed)
               int n = (int)(profit / activeStep);
               lockedProfitUSD = (n - 1) * activeStep;
            }
         }
         else if(lot <= 0.09)
         {
            if(profit >= 15.0 && profit < 30.0)
            {
               lockedProfitUSD = 10.0;
            }
            else if(profit >= 30.0)
            {
               int n = (int)(profit / activeStep);
               lockedProfitUSD = (n - 1) * activeStep;
            }
         }
         else // standard step size with normal lot
         {
            if(profit >= 2.0 * activeStep)
            {
               int n = (int)(profit / activeStep);
               lockedProfitUSD = (n - 1) * activeStep;
            }
         }
         
         if(lockedProfitUSD > 0.0)
         {
            // Convert locked profit USD to price distance from entry
            double profitPriceDist = (lockedProfitUSD * tickSize) / (lot * tickValue);
            
            targetSL = (type == POSITION_TYPE_BUY) ? (entryPrice + profitPriceDist)
                                                   : (entryPrice - profitPriceDist);
            targetSL = NormalizeDouble(targetSL, _Digits);

            if(type == POSITION_TYPE_BUY)
            {
               if(targetSL > currentSL && (currentTP <= 0.0 || targetSL < currentTP))
                  modifyNeeded = true;
            }
            else // POSITION_TYPE_SELL
            {
               if((currentSL == 0.0 || targetSL < currentSL) && (currentTP <= 0.0 || targetSL > currentTP))
                  modifyNeeded = true;
            }
         }
      }
      //=== METHOD B: Volatility/USD Dynamic ATR Trail ===
      else if(profit >= InpTrailLockUSD)
      {
         // Dynamic trailing room buffer based on live regime conviction
         double multiplier = 1.0;
         if(g_cachedRegimeTrendProb >= 0.60)
            multiplier = 1.5; // Trending -> widen trailing distance (breathing room: 3.75x ATR)
         else if(g_cachedRegimeTrendProb <= 0.40)
            multiplier = 0.7; // Chop/Sideways -> tighten trailing distance (lock-in: 1.75x ATR)

         double trailDistPrice = 0.0;
         if(InpUseATRTrailing)
         {
            double atrBufVal[];
            double atrNow = 0.0;
            int atrHNow = iATR(_Symbol, _Period, 14);
            if(atrHNow != INVALID_HANDLE && CopyBuffer(atrHNow, 0, 0, 1, atrBufVal) > 0)
               atrNow = atrBufVal[0];
            
            if(atrNow > 0.0)
               trailDistPrice = InpTrailATRMultiplier * multiplier * atrNow;
            else
               trailDistPrice = (InpTrailDistUSD * multiplier * tickSize) / (lot * tickValue);
         }
         else
         {
            trailDistPrice = (InpTrailDistUSD * multiplier * tickSize) / (lot * tickValue);
         }

         targetSL = (type == POSITION_TYPE_BUY) ? (currentPrice - trailDistPrice)
                                                : (currentPrice + trailDistPrice);
         targetSL = NormalizeDouble(targetSL, _Digits);

         if(type == POSITION_TYPE_BUY)
         {
            if(targetSL > currentSL && (currentTP <= 0.0 || targetSL < currentTP))
               modifyNeeded = true;
         }
         else // POSITION_TYPE_SELL
         {
            if((currentSL == 0.0 || targetSL < currentSL) && (currentTP <= 0.0 || targetSL > currentTP))
               modifyNeeded = true;
         }
      }

      // Enforce modification
      if(modifyNeeded && targetSL > 0.0)
      {
         CTradeSafe trade;
         if(trade.PositionModify(ticket, targetSL, currentTP))
         {
            if(InpUseStepLadder)
            {
               double lockedProfitUSD = 0.0;
               if(lot <= 0.09)
               {
                  if(profit >= 15.0 && profit < 30.0)
                     lockedProfitUSD = 10.0;
                  else if(profit >= 30.0)
                  {
                     int n = (int)(profit / InpStepSizeUSD);
                     lockedProfitUSD = (n - 1) * InpStepSizeUSD;
                  }
               }
               else
               {
                  if(profit >= 2.0 * InpStepSizeUSD)
                  {
                     int n = (int)(profit / InpStepSizeUSD);
                     lockedProfitUSD = (n - 1) * InpStepSizeUSD;
                  }
               }
               PrintFormat("[Ladder-Trail-Step] Updated #%I64u SL: %.2f -> %.2f (USD Profit: %.2f, locked in +$%.2f USD).",
                           ticket, currentSL, targetSL, profit, lockedProfitUSD);
            }
            else
            {
               PrintFormat("[Ladder-Trail-Tick] Updated #%I64u SL: %.2f -> %.2f (USD Profit: %.2f, trailing active).",
                           ticket, currentSL, targetSL, profit);
            }
         }
      }
   }
}

#endif // GE_EXITCONTRACT_MQH
