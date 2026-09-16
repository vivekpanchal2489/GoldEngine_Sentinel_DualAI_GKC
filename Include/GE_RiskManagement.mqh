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
//+------------------------------------------------------------------+
//| Dynamic Balance Sizing Settings                                  |
//+------------------------------------------------------------------+
input group "=== Dynamic Account Balance Sizing ($100 -> 0.02) ==="
input bool   InpUseDynamicBalanceSizing = true;    // Dynamic Lot Sizing based on Volatility & Balance
input double InpBaseMinLot              = 0.02;    // Minimum Base Lot
input double InpBalanceStepUSD          = 100.0;   // Balance Increment Step ($100)
input double InpLotStepIncrement        = 0.01;    // Lot Increment per Step (+0.01)

input group "=== Dynamic Session Conviction & Lot Scheduler (IST) ==="
input bool   InpUseDynamicScheduler = true;   // Enable dynamic conviction & lot thresholds by time zone
input int    InpZone1StartHour      = 3;      // Zone 1 Start Hour (IST, default 3:30 AM)
input int    InpZone1StartMin       = 30;     // Zone 1 Start Minute (IST)
input double InpZone1Confidence     = 0.550;  // Zone 1 Confidence Threshold (Sydney/Tokyo - 55.0%)
input double InpZone1Margin         = 0.070;  // Zone 1 Margin Gap (7.0%)
input double InpZone1MaxLot         = 0.15;   // Zone 1 Max Lot (Max 0.15 lots)
input double InpZone1StepSizeUSD     = 25.0;   // Zone 1 Step Ladder Trailing Step ($25 USD)

input int    InpZone2StartHour      = 13;     // Zone 2 Start Hour (IST, default 1:30 PM)
input int    InpZone2StartMin       = 30;     // Zone 2 Start Minute (IST)
input double InpZone2Confidence     = 0.535;  // Zone 2 Confidence Threshold (London/NY Peak - 53.5%)
input double InpZone2Margin         = 0.050;  // Zone 2 Margin Gap (5.0%)
input double InpZone2MaxLot         = 0.15;   // Zone 2 Max Lot (Max 0.15 lots)
input double InpZone2StepSizeUSD     = 25.0;   // Zone 2 Step Ladder Trailing Step ($25 USD)

input int    InpZone3StartHour      = 21;     // Zone 3 Start Hour (IST, default 9:30 PM)
input int    InpZone3StartMin       = 30;     // Zone 3 Start Minute (IST)
input double InpZone3Confidence     = 0.550;  // Zone 3 Confidence Threshold (Late NY Close - 55.0%)
input double InpZone3Margin         = 0.070;  // Zone 3 Margin Gap (7.0%)
input double InpZone3MaxLot         = 0.15;   // Zone 3 Max Lot (Max 0.15 lots)
input double InpZone3StepSizeUSD     = 25.0;   // Zone 3 Step Ladder Trailing Step ($25 USD)

input group "=== Session Execution Controls (IST) ==="
input bool   InpEnableZone1Trading  = true;   // Enable Trading in Zone 1 (Asian Session: 03:30 AM - 01:30 PM IST) [TRUE = Free Trading]
input bool   InpEnableZone2Trading  = true;   // Enable Trading in Zone 2 (London/NY Peak: 01:30 PM - 09:30 PM IST) [TRUE = Free Trading]
input bool   InpEnableZone3Trading  = true;   // Enable Trading in Zone 3 (Late NY Session: 09:30 PM - 01:30 AM IST) [TRUE = Free Trading]

input group "=== Night Curfew & Bank Rollover Protection (IST) ==="
input bool   InpUseNightCurfew      = true;   // Enable Night Curfew (No new trades between 01:30 AM and 03:30 AM IST)
input int    InpCurfewStartHour     = 1;      // Curfew Start Hour (IST, 1:30 AM)
input int    InpCurfewStartMin      = 30;     // Curfew Start Min (IST)
input int    InpCurfewEndHour       = 3;      // Curfew End Hour (IST, 3:30 AM - Zone 1 open)
input int    InpCurfewEndMin        = 30;     // Curfew End Min (IST)

//+------------------------------------------------------------------+
//| IsNightCurfewActive — Checks if current IST time is in curfew    |
//+------------------------------------------------------------------+
bool IsNightCurfewActive()
{
   if(!InpUseDynamicScheduler || !InpUseNightCurfew)
      return false;

   MqlDateTime dt;
   TimeLocal(dt); // Computer system clock (IST)
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int curfewStart = InpCurfewStartHour * 60 + InpCurfewStartMin; // 1:30 AM (90 mins)
   int curfewEnd   = InpCurfewEndHour * 60 + InpCurfewEndMin;     // 3:30 AM (210 mins)

   if(currentMinutes >= curfewStart && currentMinutes < curfewEnd)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| IsZoneTradingAllowed — Check if trading is enabled in current zone|
//+------------------------------------------------------------------+
bool IsZoneTradingAllowed(string &zoneBlockedReason)
{
   if(!InpUseDynamicScheduler)
   {
      zoneBlockedReason = "";
      return true;
   }

   MqlDateTime dt;
   TimeLocal(dt); // System clock (IST)
   int currentMinutes = dt.hour * 60 + dt.min;

   int curfewStart = InpCurfewStartHour * 60 + InpCurfewStartMin; // 1:30 AM (90 mins)
   int curfewEnd   = InpCurfewEndHour * 60 + InpCurfewEndMin;     // 3:30 AM (210 mins)

   // 1. Night Rollover Curfew (01:30 AM - 03:30 AM IST)
   if(InpUseNightCurfew && currentMinutes >= curfewStart && currentMinutes < curfewEnd)
   {
      zoneBlockedReason = "NIGHT_CURFEW (01:30 AM - 03:30 AM Rollover Protection)";
      return false;
   }

   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin; // 03:30 AM (210 mins)
   int z2Minutes = InpZone2StartHour * 60 + InpZone2StartMin; // 01:30 PM (810 mins)
   int z3Minutes = InpZone3StartHour * 60 + InpZone3StartMin; // 09:30 PM (1290 mins)

   // 2. Zone 1: Asian Session Strict Curfew (03:30 AM - 01:30 PM IST)
   if(currentMinutes >= z1Minutes && currentMinutes < z2Minutes)
   {
      if(!InpEnableZone1Trading)
      {
         zoneBlockedReason = "ZONE1_ASIAN_CURFEW (03:30 AM - 01:30 PM Asian Standby)";
         return false;
      }
   }
   // 3. Zone 2: London & NY Peak (01:30 PM - 09:30 PM IST)
   else if(currentMinutes >= z2Minutes && currentMinutes < z3Minutes)
   {
      if(!InpEnableZone2Trading)
      {
         zoneBlockedReason = "ZONE2_DISABLED";
         return false;
      }
   }
   // 4. Zone 3: Late NY Session (09:30 PM - 01:30 AM IST)
   else
   {
      if(!InpEnableZone3Trading)
      {
         zoneBlockedReason = "ZONE3_DISABLED";
         return false;
      }
   }

   zoneBlockedReason = "";
   return true;
}

//+------------------------------------------------------------------+
//| GetActiveStepSizeUSD — Dynamic Session Step Ladder Trailing Step |
//+------------------------------------------------------------------+
double GetActiveStepSizeUSD(const double defaultStepUSD = 15.0)
{
   if(!InpUseDynamicScheduler)
      return defaultStepUSD;

   MqlDateTime dt;
   TimeLocal(dt); // Computer system clock (IST)
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin;
   int z2Minutes = InpZone2StartHour * 60 + InpZone2StartMin;
   int z3Minutes = InpZone3StartHour * 60 + InpZone3StartMin;

   // Zone 1: Sydney/Tokyo Open & Morning Chop (3:30 AM to 1:30 PM IST)
   if(currentMinutes >= z1Minutes && currentMinutes < z2Minutes)
      return InpZone1StepSizeUSD;
   // Zone 2: London & NY Peak (1:30 PM to 9:30 PM IST)
   else if(currentMinutes >= z2Minutes && currentMinutes < z3Minutes)
      return InpZone2StepSizeUSD;
   // Zone 3: Late NY Close & Night Drift (9:30 PM to 3:30 AM IST)
   else
      return InpZone3StepSizeUSD;
}

//+------------------------------------------------------------------+
//| Risk & Position Sizing                                           |
//+------------------------------------------------------------------+
input group "=== Risk & Position Sizing ==="
input bool   InpUseConcurrencyCap   = true;    // Enforce the max-position cap and per-trade risk limit
input int    InpMaxConcurrentTrades = 3;       // Max simultaneous positions the EA may hold (Max 3 Concurrent Trades)
input int    InpMaxPositionsPerDir  = 3;       // Max simultaneous positions in the same direction
input double InpMinEntrySpacingPts   = 6.0;     // Min price distance (pts) to open concurrent position in same direction
input int    InpMinEntryCooldownBars = 2;       // Min M5 bars (10 mins) between opening concurrent positions
input double InpRiskPerTradeUSD     = 50.0;    // Risk per trade in USD — baseline for flat sizing
input double InpMinRiskUSD          = 50.0;    // Floor USD risk per trade (minimum allowed risk)
input double InpMaxRiskUSD          = 200.0;   // Ceiling USD risk per trade (maximum allowed risk)
input double InpMinLotSize          = 0.02;    // Minimum lot size allowed (broker floor safety clamp)
input double InpMaxLotSize          = 0.50;    // Maximum lot size allowed (hard ceiling, prevents oversized orders)
input double InpMaxRiskOverageUSD   = 100.00;  // Max extra USD risk accepted when rounding up to the lot floor
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
//| GetActiveZoneMaxLot — dynamic session lot ceiling governor       |
//+------------------------------------------------------------------+
double GetActiveZoneMaxLot()
{
   if(!InpUseDynamicScheduler)
      return InpMaxLotSize;

   MqlDateTime dt;
   TimeLocal(dt); // Computer system clock (IST)
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin;
   int z2Minutes = InpZone2StartHour * 60 + InpZone2StartMin;
   int z3Minutes = InpZone3StartHour * 60 + InpZone3StartMin;

   if(currentMinutes >= z1Minutes && currentMinutes < z2Minutes)
      return InpZone1MaxLot;
   else if(currentMinutes >= z2Minutes && currentMinutes < z3Minutes)
      return InpZone2MaxLot;
   else
      return InpZone3MaxLot;
}

//+------------------------------------------------------------------+
//| CalculateDynamicBalanceLot — Volatility-Normalized Risk Sizing   |
//| Lots = TargetRiskUSD / (slDistUSD * tickValue / tickSize)        |
//| Strictly governed by Zone Max Lot ceiling (e.g. 0.15 max)        |
//+------------------------------------------------------------------+
double CalculateDynamicBalanceLot(const double slDistUSD = 0.0)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0) tickSize = _Point;
   if(tickValue <= 0.0) tickValue = 1.0;

   double targetRisk = InpRiskPerTradeUSD; // e.g. $50.00 USD
   if(targetRisk <= 0.0) targetRisk = 50.0;

   double calculatedLot = 0.0;
   if(slDistUSD > 0.0)
   {
      double lossPerLot = (slDistUSD / tickSize) * tickValue;
      if(lossPerLot > 0.0)
         calculatedLot = targetRisk / lossPerLot;
   }

   if(calculatedLot <= 0.0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      int hundreds = (int)MathFloor(balance / InpBalanceStepUSD);
      if(hundreds < 1) hundreds = 1;
      calculatedLot = InpBaseMinLot + (hundreds - 1) * InpLotStepIncrement;
   }

   // Apply Zone-Adaptive Lot Governor Ceiling
   double zoneCap = GetActiveZoneMaxLot();
   if(zoneCap > 0.0 && calculatedLot > zoneCap)
      calculatedLot = zoneCap;

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
