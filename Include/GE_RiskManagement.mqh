//+------------------------------------------------------------------+
//| GE_RiskManagement.mqh                                            |
//| Single source of truth: "how much, and how many at once."        |
//|                                                                  |
//| OWNED HERE:                                                      |
//|   - Dynamic Account Balance Lot Sizing ($100 -> 0.02, +0.01)    |
//|   - Universal lot sizing formula                                 |
//|   - Per-trade USD risk cap enforcement                           |
//|   - Streak multipliers                                           |
//|   - Concurrency cap enforcement (InpUseConcurrencyCap)           |
//+------------------------------------------------------------------+
#ifndef GE_RISKMANAGEMENT_MQH
#define GE_RISKMANAGEMENT_MQH

// Global AI Cache variables (shared across ExitContract, EntryGates, AIIntegration)
double g_cachedRegimeTrendProb = 0.5;
double g_cachedRegimeChopProb  = 0.5;

//+------------------------------------------------------------------+
//| Dynamic Balance Sizing Settings                                  |
//+------------------------------------------------------------------+
input group "=== Dynamic Account Balance Sizing ($100 -> 0.02) ==="
input bool   InpUseDynamicBalanceSizing = true;    // Dynamic Lot Sizing based on Account Balance
input double InpBaseMinLot              = 0.02;    // Minimum Base Lot (at <= $100 balance)
input double InpBalanceStepUSD          = 100.0;   // Balance Increment Step ($100)
input double InpLotStepIncrement        = 0.01;    // Lot Increment per Step (+0.01)

//+------------------------------------------------------------------+
//| Risk & Position Sizing                                           |
//+------------------------------------------------------------------+
input group "=== Risk & Position Sizing ==="
input bool   InpUseConcurrencyCap   = true;    // Enforce the max-position cap and per-trade risk limit
input int    InpMaxConcurrentTrades = 3;       // Max simultaneous positions the EA may hold (Max 3 Concurrent Trades)
input int    InpMaxPositionsPerDir  = 3;       // Max simultaneous positions in the same direction
input double InpRiskPerTradeUSD     = 25.0;    // Risk per trade in USD — baseline for flat sizing
input double InpMinRiskUSD          = 100.0;   // Floor USD risk per trade (minimum allowed risk)
input double InpMaxRiskUSD          = 500.0;   // Ceiling USD risk per trade (maximum allowed risk)
input double InpMinLotSize          = 0.02;    // Minimum lot size allowed (broker floor safety clamp)
input double InpMaxLotSize          = 10.00;   // Maximum lot size allowed (hard ceiling, prevents oversized orders)
input double InpMaxRiskOverageUSD   = 300.00;  // Max extra USD risk accepted when rounding up to the lot floor
input double InpHighConfidenceThreshold = 0.62; // Confidence threshold to trigger a lot size boost
input double InpConfidenceBoostMult     = 1.5;  // Multiplier to scale trade risk when threshold is met

input group "=== Streak Risk Scaling (multipliers) ==="
input double InpStreakReduceThreeLoss = 0.25;  // Risk multiplier after 3 consecutive losses (shrink size)
input double InpStreakReduceTwoLoss   = 0.50;  // Risk multiplier after 2 consecutive losses (shrink size)
input double InpStreakBoostTwoWin     = 1.25;  // Risk multiplier after 2 consecutive wins (grow size)

//+------------------------------------------------------------------+
//| StreakState — consecutive closed wins/losses for this symbol      |
//+------------------------------------------------------------------+
struct SStreakState
{
   int    consecutiveLosses;   // 0..N
   int    consecutiveWins;     // 0..N
   bool   hasHistory;          // false = no closed deals found yet
};

//+------------------------------------------------------------------+
//| GetStreakState                                                   |
//+------------------------------------------------------------------+
SStreakState GetStreakState()
{
   SStreakState s;
   s.consecutiveLosses = 0;
   s.consecutiveWins   = 0;
   s.hasHistory        = false;

   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(profit > 0.0)
      {
         s.hasHistory = true;
         s.consecutiveWins++;
      }
      else if(profit < 0.0)
      {
         s.hasHistory = true;
         s.consecutiveLosses++;
      }
      else
         continue;
      break;
   }
   return s;
}

//+------------------------------------------------------------------+
//| StreakMultiplier                                                 |
//+------------------------------------------------------------------+
double StreakMultiplier(const SStreakState &s)
{
   if(s.hasHistory)
   {
      if(s.consecutiveLosses >= 3)  return InpStreakReduceThreeLoss;
      if(s.consecutiveLosses >= 2)  return InpStreakReduceTwoLoss;
      if(s.consecutiveWins   >= 2)  return InpStreakBoostTwoWin;
   }
   return 1.0;
}

//+------------------------------------------------------------------+
//| CalculateDynamicBalanceLot — User-specified balance formula      |
//| $100 -> 0.02, $200 -> 0.03, $300 -> 0.04, +0.01 per $100        |
//+------------------------------------------------------------------+
double CalculateDynamicBalanceLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(stepLot <= 0.0) stepLot = 0.01;

   int hundreds = (int)MathFloor(balance / InpBalanceStepUSD);
   if(hundreds < 1) hundreds = 1;

   double calculatedLot = InpBaseMinLot + (hundreds - 1) * InpLotStepIncrement;

   if(calculatedLot < InpBaseMinLot) calculatedLot = InpBaseMinLot;
   if(calculatedLot < minLot) calculatedLot = minLot;
   if(maxLot > 0.0 && calculatedLot > maxLot) calculatedLot = maxLot;

   if(stepLot > 0.0)
      calculatedLot = MathFloor(calculatedLot / stepLot) * stepLot;

   return NormalizeDouble(calculatedLot, 2);
}

//+------------------------------------------------------------------+
//| CalculateLotSizeWithConfidence                                   |
//+------------------------------------------------------------------+
double CalculateLotSizeWithConfidence(const double slDistUSD, const string source, const string dir, const double confidence, const double minConfidence)
{
   if(InpUseDynamicBalanceSizing)
      return CalculateDynamicBalanceLot();

   if(slDistUSD <= 0.0)
      return InpMinLotSize;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return InpMinLotSize;

   double lossPerLot = (slDistUSD / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return InpMinLotSize;

   double targetRisk = InpRiskPerTradeUSD;

   if(confidence >= InpHighConfidenceThreshold && InpHighConfidenceThreshold > 0.0)
      targetRisk *= InpConfidenceBoostMult;

   SStreakState streak = GetStreakState();
   targetRisk *= StreakMultiplier(streak);

   if(targetRisk < InpMinRiskUSD) targetRisk = InpMinRiskUSD;
   if(targetRisk > InpMaxRiskUSD) targetRisk = InpMaxRiskUSD;

   double calculatedLot = targetRisk / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(stepLot <= 0.0) stepLot = 0.01;

   if(calculatedLot < InpBaseMinLot) calculatedLot = InpBaseMinLot;
   if(calculatedLot < minLot) calculatedLot = minLot;
   if(calculatedLot > InpMaxLotSize) calculatedLot = InpMaxLotSize;
   if(maxLot > 0.0 && calculatedLot > maxLot) calculatedLot = maxLot;

   if(stepLot > 0.0)
      calculatedLot = MathFloor(calculatedLot / stepLot) * stepLot;

   return NormalizeDouble(calculatedLot, 2);
}

#endif // GE_RISKMANAGEMENT_MQH
