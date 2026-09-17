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
input group "=== Two-Phase Hybrid Trailing & Profit Lock Engine ==="
input bool   InpUseLadderTrail        = true;   // Enable Sentinel Trailing Stop-Loss Engine
input bool   InpUseStepLadder         = true;   // Method A: Two-Phase Hybrid Break-Even & Big-Profit Ratchet
input double InpPhase1TriggerUSD      = 50.0;   // Phase 1: Profit in USD to trigger Break-Even ($50.00 = +3.3 pts)
input double InpPhase1LockUSD         = 5.0;    // Phase 1: Profit to lock in USD (+$5.00 = spread/commission cushion)
input double InpPhase2TriggerUSD      = 75.0;   // Phase 2: Profit in USD to start Big-Profit Ratchet ($75.00 = +5.0 pts)
input double InpPhase2FirstLockUSD    = 50.0;   // Phase 2: Guaranteed profit locked at $75 ($50.00 minimum win)
input double InpPhase2StepUSD         = 25.0;   // Phase 2: Step-ladder climbing rung size ($25.00)
input bool   InpUseATRTrailing        = true;   // Method B: Dynamic ATR Volatility Trailing (if StepLadder disabled)
input double InpTrailLockUSD          = 50.0;   // Unrealized Profit in USD to start ATR trailing ($50.00)
input double InpTrailDistUSD          = 25.0;   // Fallback Trailing Distance in USD ($25.00)
input double InpTrailATRMultiplier    = 2.5;    // Trailing Stop Distance in ATRs (2.5x ATR)

input group "=== Initial Risk Contract (SL / TP / Reversal) ==="
input bool   InpUseATRStopLoss        = true;   // Use ATR-based SL/TP instead of fixed-USD distances
input double InpATRMultiplier         = 2.5;    // Initial SL = InpATRMultiplier x ATR(14) (2.5x ATR ~3.5-5.0 pts)
input double InpFomoRRRatio           = 3.0;    // Initial TP = SL x InpFomoRRRatio (7.5x ATR => 1:3 RR)
input double InpFixedRiskUSD          = 50.0;   // FIXED loss per trade in account USD (structural fallback)
input double InpExitSLDistUSD         = 6.0;    // Reference SL distance used for lot-sizing math ($6.00)
input double InpExitTPDistUSD         = 150.0;  // Reference Take-profit distance in USD ($150.00)
input int    InpMaxHoldMinutes        = 0;      // Max time in position before forced close (0 = DISABLED)
input bool   InpExitOnReversal        = false;  // ONNX AI Reversal Exit (0 = DISABLED, rely strictly on Step-Ladder & Hard SL)
input double InpExitReversalP         = 0.60;   // ONNX probability that flips a position to opposite side
input bool   InpExitReversalAllowLoss = false;  // Close LOSING trades on ONNX reversal (FALSE = DISABLED)

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
//| CheckExitContract — Time-decay and ONNX reversal-exit             |
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
      if(InpExitOnReversal && onnxValid)
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
   }
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
      int activeZone = GetActiveZoneId();

      //=== METHOD A: USD-based Two-Phase Hybrid Break-Even & Big-Profit Ratchet ===
      if(InpUseStepLadder)
      {
         double lockedProfitUSD = 0.0;
         
         // Zone 1 (Asian) & Zone 2 (London/NY Peak): Two-Phase Hybrid Engine
         if(activeZone == 1 || activeZone == 2)
         {
            // Phase 1: Risk Elimination Buffer at +$50 Profit -> Move SL to Break-Even + $5
            // Gives a full 3.0+ points of breathing room from peak so long runners are never choked!
            if(profit >= InpPhase1TriggerUSD && profit < InpPhase2TriggerUSD)
            {
               lockedProfitUSD = InpPhase1LockUSD; // $5.00 (Break-Even + spread/commission)
            }
            // Phase 2: Big-Profit Step-Ladder Ratchet at >= $75 Profit ($50 lock climbing in $25 rungs)
            else if(profit >= InpPhase2TriggerUSD)
            {
               int rungsAbovePhase2 = (int)((profit - InpPhase2TriggerUSD) / InpPhase2StepUSD);
               lockedProfitUSD = InpPhase2FirstLockUSD + (rungsAbovePhase2 * InpPhase2StepUSD);
            }
         }
         // Zone 3 (Late NY Close): Micro-Trailing Mode (Every $10 USD ratchet)
         else
         {
            if(profit >= 15.0 && profit < 25.0)
            {
               lockedProfitUSD = 5.0;
            }
            else if(profit >= 25.0 && profit < 35.0)
            {
               lockedProfitUSD = 15.0;
            }
            else if(profit >= 35.0)
            {
               int n = (int)(profit / 10.0);
               lockedProfitUSD = (n - 1) * 10.0;
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
               if(activeZone == 1 || activeZone == 2)
               {
                  if(profit >= InpPhase1TriggerUSD && profit < InpPhase2TriggerUSD)
                     lockedProfitUSD = InpPhase1LockUSD;
                  else if(profit >= InpPhase2TriggerUSD)
                  {
                     int rungsAbovePhase2 = (int)((profit - InpPhase2TriggerUSD) / InpPhase2StepUSD);
                     lockedProfitUSD = InpPhase2FirstLockUSD + (rungsAbovePhase2 * InpPhase2StepUSD);
                  }
               }
               else
               {
                  if(profit >= 15.0 && profit < 25.0) lockedProfitUSD = 5.0;
                  else if(profit >= 25.0 && profit < 35.0) lockedProfitUSD = 15.0;
                  else if(profit >= 35.0) lockedProfitUSD = ((int)(profit / 10.0) - 1) * 10.0;
               }

               PrintFormat("[Hybrid-Ladder-Trail] Updated #%I64u SL: %.2f -> %.2f (USD Profit: %.2f, locked in +$%.2f USD).",
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
