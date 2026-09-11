//+------------------------------------------------------------------+
//| GE_EntryGates.mqh                                                |
//| Single source of truth for whether a trade is allowed to open.   |
//|                                                                  |
//| OWNED HERE:                                                      |
//|   - ONNX permission check (directional agreement, fail-closed)   |
//|   - Nadaraya-Watson Statistical Exhaustion Veto                  |
//|   - IST Dynamic Session Conviction Scheduler                     |
//|   - Directional Lock & Opposite-Direction Cooldown               |
//|   - THE SINGLE ENTRY CHOKEPOINT: AttemptTradePlacement()         |
//+------------------------------------------------------------------+
#ifndef GE_ENTRYGATES_MQH
#define GE_ENTRYGATES_MQH

#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_DecisionLog.mqh>
#include <GE_NadarayaWatson.mqh>

//+------------------------------------------------------------------+
//| Kill Switch (EMERGENCY STOP)                                     |
//+------------------------------------------------------------------+
input group "=== Kill Switch ==="
input bool   InpKillSwitch        = false;   // EMERGENCY STOP — true = block all new trades immediately

//+------------------------------------------------------------------+
//| Structural Safety (Always Active)                                |
//+------------------------------------------------------------------+
input group "=== Structural Safety (Always Active) ==="
input bool   InpUseOnnxCorePath    = true;    // Require ONNX Core Path agreement before any entry
input bool   InpUseDirectionalLock = true;    // Block new positions opposite an existing one
input bool   InpUseOppDirCooldown  = true;    // Block re-entry in the same direction right after an opposite close
input bool   InpUsePriceZoneFilter = true;    // Only trade inside the permitted price zone
input int    InpOppDirCooldownSecs = 300;     // Seconds to block same-direction re-entry after an opposite close

//+------------------------------------------------------------------+
//| ADX / ATR / Regime Thresholds                                    |
//+------------------------------------------------------------------+
input group "=== ADX/ATR/Regime Thresholds ==="
input double InpStructuralADXHardTrendLock = 35.0;  // ADX above which reversion trading is fully disabled (strong trend)
input double InpADXTrendGuard              = 25.0;  // ADX above this reversion is on hold (trend guard)
input double InpRegimeADXThreshold         = 25.0;  // ADX that separates trending vs. ranging market behavior
input double InpVolatilitySpikeRatio       = 1.4;   // How much current volatility must exceed average to flag a spike
input double InpMinATR                     = 0.50;  // Minimum ATR; below this volatility is too low to trade
input double InpGruAtrNormMin              = 0.00092; // Min normalized ATR for GRU-model trades
input double InpBreakoutVolMult            = 1.5;   // Volume vs average multiple that confirms a real breakout
input double InpBreakoutATRMult            = 1.5;   // ATR vs average multiple that confirms a real breakout
input int    InpRegimeVolSMAPeriod         = 20;    // Volume average window used for the spike check
input int    InpRegimeATRSMAPeriod         = 20;    // ATR average window used for the spike check
input double InpRSIOverboughtLevel         = 70.0;  // RSI level considered overbought
input double InpRSIOversoldLevel           = 30.0;  // RSI level considered oversold

//+------------------------------------------------------------------+
//| ONNX Core Conviction                                             |
//+------------------------------------------------------------------+
input group "=== ONNX Core Conviction (the boss's own bar) ==="
input double InpOnnxConfidence      = 0.535;  // Min ONNX probability required for its OWN independent trades (53.5%)
input double InpOnnxMargin          = 0.050;  // Min probability gap (BULL vs BEAR) required for ONNX's own trades (5.0%)
input double InpStrategyOnnxMinProb = 0.515;  // Min ONNX probability required for AI-strategy entries (51.5%)

//+------------------------------------------------------------------+
//| Format12Hour — convert hour/minute to 12h AM/PM string           |
//+------------------------------------------------------------------+
string Format12Hour(int hour, int min)
{
   string ampm = (hour >= 12) ? "PM" : "AM";
   int displayHour = hour % 12;
   if(displayHour == 0) displayHour = 12;
   return StringFormat("%02d:%02d %s", displayHour, min, ampm);
}

//+------------------------------------------------------------------+
//| GetActiveConvictionSettings — dynamic session conviction finder  |
//+------------------------------------------------------------------+
void GetActiveConvictionSettings(double &activeConf, double &activeMargin, string &activeZoneName, string &activeZoneSched)
{
   if(!InpUseDynamicScheduler)
   {
      activeConf = InpOnnxConfidence;
      activeMargin = InpOnnxMargin;
      activeZoneName = "STATIC DEFAULT";
      activeZoneSched = StringFormat("Default: %.2f / %.2f", InpOnnxConfidence, InpOnnxMargin);
      return;
   }

   MqlDateTime dt;
   TimeLocal(dt); // Computer system clock (IST)
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin;
   int z2Minutes = InpZone2StartHour * 60 + InpZone2StartMin;
   int z3Minutes = InpZone3StartHour * 60 + InpZone3StartMin;
   int curfewStart = InpCurfewStartHour * 60 + InpCurfewStartMin;

   // Night Curfew Window: 1:30 AM to 3:30 AM IST (Bank Rollover & Illiquidity Protection)
   if(InpUseNightCurfew && currentMinutes >= curfewStart && currentMinutes < z1Minutes)
   {
      activeConf = 0.999;
      activeMargin = 0.999;
      activeZoneName = "NIGHT CURFEW";
      activeZoneSched = StringFormat("%s - %s (Curfew: No New Trades)", 
                                     Format12Hour(InpCurfewStartHour, InpCurfewStartMin), 
                                     Format12Hour(InpCurfewEndHour, InpCurfewEndMin));
   }
   // Zone 1: Sydney/Tokyo Open & Morning Chop (3:30 AM to 1:30 PM IST)
   else if(currentMinutes >= z1Minutes && currentMinutes < z2Minutes)
   {
      activeConf = InpZone1Confidence;
      activeMargin = InpZone1Margin;
      activeZoneName = "SYDNEY/TOKYO";
      activeZoneSched = StringFormat("%s - %s (Strict: %.2f/%.2f)", 
                                     Format12Hour(InpZone1StartHour, InpZone1StartMin), 
                                     Format12Hour(InpZone2StartHour, InpZone2StartMin), 
                                     activeConf, activeMargin);
   }
   // Zone 2: London & NY Peak (1:30 PM to 9:30 PM IST)
   else if(currentMinutes >= z2Minutes && currentMinutes < z3Minutes)
   {
      activeConf = InpZone2Confidence;
      activeMargin = InpZone2Margin;
      activeZoneName = "LONDON/NY PEAK";
      activeZoneSched = StringFormat("%s - %s (Normal: %.2f/%.2f)", 
                                     Format12Hour(InpZone2StartHour, InpZone2StartMin), 
                                     Format12Hour(InpZone3StartHour, InpZone3StartMin), 
                                     activeConf, activeMargin);
   }
   // Zone 3: Late NY Close & Night Drift (9:30 PM to 1:30 AM IST)
   else
   {
      activeConf = InpZone3Confidence;
      activeMargin = InpZone3Margin;
      activeZoneName = "LATE NY DRIFT";
      activeZoneSched = StringFormat("%s - %s (U-Strict: %.2f/%.2f)", 
                                     Format12Hour(InpZone3StartHour, InpZone3StartMin), 
                                     Format12Hour(InpCurfewStartHour, InpCurfewStartMin), 
                                     activeConf, activeMargin);
   }
}

//+------------------------------------------------------------------+
//| Step 4 audit additions — entry-side filters (default FALSE)      |
//+------------------------------------------------------------------+
input group "=== Step 4 Audit Additions (default OFF) ==="
input bool   InpUseGruAtrGate          = false;  // GRU ATR-norm volatility gate
input bool   InpUseSessionHours        = false;  // Session momentum-hours gate
input bool   InpUseADXGate             = false;  // ADX trend gate in ONNX engine
input bool   InpUseVolumeFilter        = false;  // Volume filter (breakout confirm)
input bool   InpUseEMAFilter           = false;  // EMA trend filter
input int    InpEMAPeriod              = 50;     // Period of the EMA trend filter
input bool   InpUseRSIFilter           = false;  // RSI exhaustion filter
input bool   InpUseCandleConfirm       = false;  // Candle color momentum confirmation
input bool   InpUseMTFTrendFilter      = false;  // Multi-timeframe trend filter

//+------------------------------------------------------------------+
//| Cached ONNX Brain 1 (SuperGRU 76)                                |
//+------------------------------------------------------------------+
datetime g_cachedOnnxBarTime = 0;
double   g_cachedOnnxBull    = 0.0;
double   g_cachedOnnxBear    = 0.0;
double   g_cachedOnnxMargin  = 0.0;
bool     g_cachedOnnxValid   = false;

// History of last 2 predictions (M5[-1] and M5[-2])
double   g_histOnnxBull1     = 0.0;
double   g_histOnnxBear1     = 0.0;
bool     g_histOnnxValid1    = false;
double   g_histOnnxBull2     = 0.0;
double   g_histOnnxBear2     = 0.0;
bool     g_histOnnxValid2    = false;

// Note: Master AI & Order Flow variables (g_masterDelta, etc.) declared in GE_RiskManagement.mqh

//+------------------------------------------------------------------+
//| Live regime/ADX/RSI cache                                        |
//+------------------------------------------------------------------+
double g_cachedAdx    = 0.0;
double g_cachedAtr    = 0.0;
double g_cachedRsi    = 50.0;
string g_cachedRegime = "SIDEWAYS";

void RefreshRegimeCache()
{
   double adxBuf[], atrBuf[], rsiBuf[];
   int adxH = iADX(_Symbol, _Period, 14);
   int atrH = iATR(_Symbol, _Period, 14);
   int rsiH = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   if(adxH != INVALID_HANDLE && CopyBuffer(adxH, 0, 0, 1, adxBuf) > 0)
      g_cachedAdx = adxBuf[0];
   if(atrH != INVALID_HANDLE && CopyBuffer(atrH, 0, 0, 1, atrBuf) > 0)
      g_cachedAtr = atrBuf[0];
   if(rsiH != INVALID_HANDLE && CopyBuffer(rsiH, 0, 0, 1, rsiBuf) > 0)
      g_cachedRsi = rsiBuf[0];
   g_cachedRegime = (g_cachedAdx >= InpRegimeADXThreshold ? "TRENDING" : "SIDEWAYS");
}

// Global button state
bool g_killSwitchBtnActive = false;

// Helper indicators
double DashMA(int period, int shift)
{
   double buf[1];
   int handle = iMA(_Symbol, _Period, period, 0, MODE_EMA, PRICE_CLOSE);
   if(handle != INVALID_HANDLE && CopyBuffer(handle, 0, shift, 1, buf) > 0)
      return buf[0];
   return 0.0;
}

double DashRSI(int shift)
{
   double buf[1];
   int handle = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   if(handle != INVALID_HANDLE && CopyBuffer(handle, 0, shift, 1, buf) > 0)
      return buf[0];
   return 50.0;
}

double DashADX(int shift)
{
   double buf[1];
   int handle = iADX(_Symbol, _Period, 14);
   if(handle != INVALID_HANDLE && CopyBuffer(handle, 0, shift, 1, buf) > 0)
      return buf[0];
   return 25.0;
}

double DashATR(int shift)
{
   double buf[1];
   int handle = iATR(_Symbol, _Period, 14);
   if(handle != INVALID_HANDLE && CopyBuffer(handle, 0, shift, 1, buf) > 0)
      return buf[0];
   return 2.0;
}

//+------------------------------------------------------------------+
//| THE SINGLE ENTRY CHOKEPOINT: AttemptTradePlacement()             |
//+------------------------------------------------------------------+
bool AttemptTradePlacement(const string strategySource, const string direction)
{
   SDecisionRecord rec;
   ZeroMemory(rec);
   rec.timestamp       = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   rec.symbol          = _Symbol;
   rec.strategy_source = strategySource;
   rec.direction       = direction;
   rec.onnx_prob_bull  = g_cachedOnnxBull;
   rec.onnx_prob_bear  = g_cachedOnnxBear;
   rec.onnx_margin     = g_cachedOnnxMargin;
   rec.onnx_predicted_class = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
   rec.adx_value       = g_cachedAdx;
   rec.atr_value       = g_cachedAtr;
   rec.regime_mode     = g_cachedRegime;
   rec.ai_active       = g_masterValid;
   rec.ai_conviction   = (int)(MathMax(g_masterProbBull, g_masterProbBear) * 100.0);
   rec.daily_bias_state= (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");

   //=== GATE 0: Kill switch ===
   if(InpKillSwitch || g_killSwitchBtnActive)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "KILL_SWITCH";
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 0.5: Dynamic Session Standby & Curfew Gate ===
   string zoneBlockReason = "";
   if(!IsZoneTradingAllowed(zoneBlockReason))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SESSION_STANDBY";
      rec.ai_reason_text = zoneBlockReason;
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 1: ONNX directional agreement & Universal Safety Filters (Fail-Closed) ===
   bool isReversalSniper = (strategySource == "NWE_REVERSAL" || strategySource == "TURTLE_SOUP_SWEEP");

   if(!isReversalSniper)
   {
      if(!g_cachedOnnxValid)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "ONNX_INVALID";
         LogTradeAttempt(rec);
         return false;
      }

      double activeConf = InpOnnxConfidence;
      double activeMargin = InpOnnxMargin;
      string activeZoneName = "";
      string activeZoneSched = "";
      GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

      if(strategySource == "ONNX_CORE")
      {
         double dirProb = (direction == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
         double margin  = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);
         if(dirProb < activeConf || margin < activeMargin)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "ONNX_CORE_LOW_CONVICTION";
            rec.ai_reason_text = StringFormat("Prob %.3f < %.3f or Margin %.3f < %.3f (%s)", 
                                              dirProb, activeConf, margin, activeMargin, activeZoneName);
            LogTradeAttempt(rec);
            return false;
         }
      }
      else if(strategySource == "SUPER_TREND_CONSENSUS")
      {
         double dirProb = (direction == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
         if(dirProb < InpStrategyOnnxMinProb)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "STRATEGY_ONNX_MIN_PROB";
            rec.ai_reason_text = StringFormat("SuperGRU Prob %.3f < %.3f min for consensus", dirProb, InpStrategyOnnxMinProb);
            LogTradeAttempt(rec);
            return false;
         }
      }

      // Agreement check
      if(direction == "BUY" && g_cachedOnnxBull <= g_cachedOnnxBear)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "ONNX_DISAGREEMENT";
         LogTradeAttempt(rec);
         return false;
      }
      if(direction == "SELL" && g_cachedOnnxBear <= g_cachedOnnxBull)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "ONNX_DISAGREEMENT";
         LogTradeAttempt(rec);
         return false;
      }

      // ORDER FLOW DELTA SHIELD (Protects against trading into heavy opposing institutional volume)
      if(g_masterValid)
      {
         if(direction == "BUY" && g_masterDelta <= -3.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "ORDER_FLOW_CONFLICT";
            rec.ai_reason_text = StringFormat("Blocked BUY: Heavy Seller Delta (%.2f <= -3.0)", g_masterDelta);
            LogTradeAttempt(rec);
            return false;
         }
         else if(direction == "SELL" && g_masterDelta >= 3.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "ORDER_FLOW_CONFLICT";
            rec.ai_reason_text = StringFormat("Blocked SELL: Heavy Buyer Delta (%.2f >= +3.0)", g_masterDelta);
            LogTradeAttempt(rec);
            return false;
         }
      }

      // UNIVERSAL GKC TOP/BOTTOM EXHAUSTION VETO (100% Prevents Selling Floor or Buying Ceiling)
      if(InpUseNweEngine && InpUseNweExhaustionVeto && g_nweMAE > 0.0)
      {
         if(direction == "BUY" && IsPriceAtTopExhaustion())
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "NWE_TOP_EXHAUSTION";
            rec.ai_reason_text = StringFormat("Price >= NWE Upper Band (%.2f, MAE=%.2f) — Anti-Top-Buy Veto active",
                                              g_nweUpperBand, g_nweMAE);
            LogTradeAttempt(rec);
            return false;
         }
         else if(direction == "SELL" && IsPriceAtBottomExhaustion())
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "NWE_BOTTOM_EXHAUSTION";
            rec.ai_reason_text = StringFormat("Price <= NWE Lower Band (%.2f, MAE=%.2f) — Anti-Bottom-Sell Veto active",
                                              g_nweLowerBand, g_nweMAE);
            LogTradeAttempt(rec);
            return false;
         }
      }

      // CANDLE ABSORPTION WICK FILTER
      double open1  = iOpen(_Symbol, _Period, 1);
      double close1 = iClose(_Symbol, _Period, 1);
      double high1  = iHigh(_Symbol, _Period, 1);
      double low1   = iLow(_Symbol, _Period, 1);
      double range1 = MathMax(high1 - low1, 1e-8);
      double loWick1 = (MathMin(open1, close1) - low1) / range1;
      double upWick1 = (high1 - MathMax(open1, close1)) / range1;

      if(direction == "BUY" && close1 < open1 && loWick1 < 0.15)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "CANDLE_MOMENTUM_CONFLICT";
         rec.ai_reason_text = StringFormat("Red Bar (Close %.2f < Open %.2f) without lower absorption wick (%.1f%% < 15%%)",
                                           close1, open1, loWick1 * 100.0);
         LogTradeAttempt(rec);
         return false;
      }
      else if(direction == "SELL" && close1 > open1 && upWick1 < 0.15)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "CANDLE_MOMENTUM_CONFLICT";
         rec.ai_reason_text = StringFormat("Green Bar (Close %.2f > Open %.2f) without upper absorption wick (%.1f%% < 15%%)",
                                           close1, open1, upWick1 * 100.0);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 2: Max open positions (Concurrency Cap) ===
   if(InpUseConcurrencyCap)
   {
      int openCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         openCount++;
      }
      if(openCount >= InpMaxConcurrentTrades)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "MAX_POSITIONS";
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 2b: Same-direction count cap ===
   if(InpMaxPositionsPerDir > 0)
   {
      int sameDirCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         if(posDir == direction)
            sameDirCount++;
      }
      if(sameDirCount >= InpMaxPositionsPerDir)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "SAME_DIR_CAP";
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 3: Directional lock ===
   if(InpUseDirectionalLock)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         if(posDir != direction)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DIRECTIONAL_LOCK";
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

   //=== GATE 4: Opposite-direction cooldown ===
   if(InpUseOppDirCooldown)
   {
      datetime lastOppClose = 0;
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int d = total - 1; d >= 0; d--)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
         string closedDir = (dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
         if(closedDir == direction)
         {
            lastOppClose = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            break;
         }
      }
      if(lastOppClose > 0 && (TimeCurrent() - lastOppClose) < InpOppDirCooldownSecs)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "OPP_DIR_COOLDOWN";
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 5: Price zone filter ===
   if(InpUsePriceZoneFilter)
   {
      double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                         : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double lo = iLow(_Symbol, PERIOD_D1, 0);
      double hi = iHigh(_Symbol, PERIOD_D1, 0);
      if(price < lo || price > hi)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "PRICE_ZONE";
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 6: Nadaraya-Watson Statistical Exhaustion Veto (Anti-Top-Buy / Anti-Bottom-Sell) ===
   if(InpUseNweEngine && InpUseNweExhaustionVeto && !isReversalSniper)
   {
      if(direction == "BUY" && IsPriceAtTopExhaustion())
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "NWE_TOP_EXHAUSTION";
         rec.ai_reason_text  = StringFormat("Price >= NWE Upper Band (%.2f, MAE=%.2f) — Anti-Top-Buy Veto active", GetNweUpperBand(), GetNweMAE());
         LogTradeAttempt(rec);
         return false;
      }
      if(direction == "SELL" && IsPriceAtBottomExhaustion())
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "NWE_BOTTOM_EXHAUSTION";
         rec.ai_reason_text  = StringFormat("Price <= NWE Lower Band (%.2f, MAE=%.2f) — Anti-Bottom-Sell Veto active", GetNweLowerBand(), GetNweMAE());
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 7: EMA Trend Filter (Optional) ===
   if(InpUseEMAFilter)
   {
      int emaH = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaH != INVALID_HANDLE)
      {
         double emaBuf[1];
         if(CopyBuffer(emaH, 0, 0, 1, emaBuf) > 0)
         {
            double emaVal = emaBuf[0];
            double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(direction == "BUY" && price < emaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "EMA_TREND_FILTER";
               rec.ai_reason_text = StringFormat("Price %.2f below EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               LogTradeAttempt(rec);
               return false;
            }
            if(direction == "SELL" && price > emaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "EMA_TREND_FILTER";
               rec.ai_reason_text = StringFormat("Price %.2f above EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== GATE 8: RSI Exhaustion Filter (Optional) ===
   if(InpUseRSIFilter)
   {
      int rsiH = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
      if(rsiH != INVALID_HANDLE)
      {
         double rsiBuf[1];
         if(CopyBuffer(rsiH, 0, 0, 1, rsiBuf) > 0)
         {
            double rsiVal = rsiBuf[0];
            if(direction == "BUY" && rsiVal >= InpRSIOverboughtLevel)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "RSI_EXHAUSTION";
               rec.ai_reason_text = StringFormat("RSI %.2f >= Overbought level %.1f", rsiVal, InpRSIOverboughtLevel);
               LogTradeAttempt(rec);
               return false;
            }
            if(direction == "SELL" && rsiVal <= InpRSIOversoldLevel)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "RSI_EXHAUSTION";
               rec.ai_reason_text = StringFormat("RSI %.2f <= Oversold level %.1f", rsiVal, InpRSIOversoldLevel);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== Placement: Universal Dynamic Balance Lot Size ===
   double atrBufVal[];
   double atrNow = 0.0;
   int atrHNow = iATR(_Symbol, _Period, 14);
   if(atrHNow != INVALID_HANDLE && CopyBuffer(atrHNow, 0, 0, 1, atrBufVal) > 0)
      atrNow = atrBufVal[0];
   bool useATR = (InpUseATRStopLoss && atrNow > 0.0);

   double lot = CalculateDynamicBalanceLot();

   if(lot <= 0.0)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "RISK_CAP_UNHONORED";
      LogTradeAttempt(rec);
      return false;
   }

   // SL/TP distances (ATR contract: SL=4xATR, TP=8xATR)
   double slDistUSD = useATR ? (InpATRMultiplier * atrNow) : PriceDistForLoss(InpFixedRiskUSD, lot);
   double tpDistUSD = useATR ? (slDistUSD * InpFomoRRRatio) : InpExitTPDistUSD;

   if(slDistUSD <= 0.0 || tpDistUSD <= 0.0)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "RISK_CAP_UNHONORED";
      LogTradeAttempt(rec);
      return false;
   }

   double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                      : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   double sl    = (direction == "BUY" ? price - slDistUSD : price + slDistUSD);
   double tp    = (direction == "BUY" ? price + tpDistUSD : price - tpDistUSD);

   CTradeSafe trade;
   bool ok = (direction == "BUY" ? trade.BuySafe(lot, _Symbol, slDistUSD, tpDistUSD)
                                  : trade.SellSafe(lot, _Symbol, slDistUSD, tpDistUSD));

   rec.result       = (ok ? "PLACED" : "BLOCKED");
   rec.block_reason = (ok ? "NONE" : "ORDER_REJECTED");
   if(ok)
   {
      rec.entry_price = price;
      rec.sl_price    = sl;
      rec.tp_price    = tp;
      rec.lot_size    = lot;
      rec.risk_usd    = (useATR ? (slDistUSD * lot * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)) : InpFixedRiskUSD);
   }
   LogTradeAttempt(rec);
   return ok;
}

//+------------------------------------------------------------------+
//| GetNextTradeAction — compute planned next action for dashboard   |
//+------------------------------------------------------------------+
void GetNextTradeAction(string &nextAction)
{
   if(InpKillSwitch || g_killSwitchBtnActive)
   {
      nextAction = "BLOCKED (Kill Switch Active)";
      g_lastBlockSource = "SYSTEM";
      g_lastBlockReason = "KILL_SWITCH";
      return;
   }
   if(!g_cachedOnnxValid)
   {
      nextAction = "BLOCKED (ONNX Cache Invalid)";
      g_lastBlockSource = "SYSTEM";
      g_lastBlockReason = "ONNX_INVALID";
      return;
   }
   
   // Check Concurrency Cap
   int openCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         openCount++;
   }
   if(InpUseConcurrencyCap && openCount >= InpMaxConcurrentTrades)
   {
      string pType = "TRADE";
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            pType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
            break;
         }
      }
      nextAction = StringFormat("BLOCKED (Open %s - Concurrency)", pType);
      g_lastBlockSource = "RISK_CAP";
      g_lastBlockReason = "MAX_CONCURRENT_POSITIONS";
      return;
   }
   
   // Determine next direction from ONNX
   string dir = (g_cachedOnnxBull > g_cachedOnnxBear ? "BUY" : "SELL");
   double dirProb = (dir == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
   double margin = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);
   
   // Check Same-Direction Cap
   if(InpMaxPositionsPerDir > 0)
   {
      int sameDirCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         if(posDir == dir)
            sameDirCount++;
      }
      if(sameDirCount >= InpMaxPositionsPerDir)
      {
         nextAction = StringFormat("BLOCKED (Max %s Open)", dir);
         g_lastBlockSource = "RISK_CAP";
         g_lastBlockReason = StringFormat("MAX_%s_POSITIONS", dir);
         return;
      }
   }
   
   // Check Dual-AI Consensus Readiness
   bool isConsensusReady = false;
   if(dir == "BUY" && g_masterValid && g_masterProbBull >= 0.54 && g_masterDelta >= 0.0 && !IsPriceAtTopExhaustion())
      isConsensusReady = true;
   else if(dir == "SELL" && g_masterValid && g_masterProbBear >= 0.54 && g_masterDelta <= 0.0 && !IsPriceAtBottomExhaustion())
      isConsensusReady = true;

   if(isConsensusReady)
   {
      nextAction = StringFormat("%s (Dual-AI Consensus Armed)", dir);
      return;
   }

   // Check Session Standby & Curfew
   string zoneBlockReason = "";
   if(!IsZoneTradingAllowed(zoneBlockReason))
   {
      nextAction = StringFormat("BLOCKED (%s)", zoneBlockReason);
      g_lastBlockSource = "SESSION_STANDBY";
      g_lastBlockReason = zoneBlockReason;
      return;
   }

   // Order Flow Delta Shield Telemetry
   if(g_masterValid)
   {
      if(dir == "BUY" && g_masterDelta <= -3.0)
      {
         nextAction = StringFormat("BLOCKED (Heavy Seller Delta: %+.1f)", g_masterDelta);
         g_lastBlockSource = "ORDER_FLOW";
         g_lastBlockReason = StringFormat("HEAVY_SELLER_FLOW (Delta %+.1f <= -3.0)", g_masterDelta);
         return;
      }
      else if(dir == "SELL" && g_masterDelta >= 3.0)
      {
         nextAction = StringFormat("BLOCKED (Heavy Buyer Delta: %+.1f)", g_masterDelta);
         g_lastBlockSource = "ORDER_FLOW";
         g_lastBlockReason = StringFormat("HEAVY_BUYER_FLOW (Delta %+.1f >= +3.0)", g_masterDelta);
         return;
      }
   }

   // Check ONNX Core thresholds (using dynamic settings)
   double activeConf = InpOnnxConfidence;
   double activeMargin = InpOnnxMargin;
   string activeZoneName = "";
   string activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

   if(dirProb < activeConf || margin < activeMargin)
   {
      nextAction = StringFormat("%s (Waiting for Conviction)", dir);
      g_lastBlockSource = "ONNX_CORE";
      g_lastBlockReason = StringFormat("LOW_CONVICTION (Prob %.2f < %.2f / Margin %.3f < %.3f)",
                                       dirProb, activeConf, margin, activeMargin);
      return;
   }
   
   nextAction = StringFormat("%s (Core Trend Ready)", dir);
}

#endif // GE_ENTRYGATES_MQH
