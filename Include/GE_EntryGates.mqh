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

//+------------------------------------------------------------------+
//| Cached ONNX Brain 2 (Master AI 76 + Microstructure + Order Flow) |
//+------------------------------------------------------------------+
double   g_masterProbBull       = 0.0;
double   g_masterProbNeu        = 0.0;
double   g_masterProbBear       = 0.0;
bool     g_masterValid          = false;
double   g_masterDelta          = 0.0;
double   g_masterDeltaMom       = 0.0;
double   g_masterFastDelta3Pct  = 0.0;
double   g_masterMacroDelta12Pct= 0.0;
double   g_masterLiquiditySweep = 0.0; // +1.0 = sweep high (bearish), -1.0 = sweep low (bullish)
double   g_masterImbalance      = 0.0;
double   g_masterLargeTrade     = 0.0;
datetime g_lastSweepLowTime     = 0;
datetime g_lastSweepHighTime    = 0;

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

   //=== GATE 0.5: Dynamic Session Standby & Strict Curfew Gate ===
   string zoneBlockReason = "";
   if(!IsZoneTradingAllowed(zoneBlockReason))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SESSION_STANDBY";
      rec.ai_reason_text = zoneBlockReason;
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 1: THE UNIVERSAL TRI-CORE SUPREME COUNCIL GATE ===
   // Boss 1: SuperGRU 76 (Macro Trend & Momentum)
   // Boss 2: Master AI 76 (Microstructure Classifier)
   // Boss 3: Order Flow Delta (Institutional Aggression)
   // Guard 1: Absorption / Rejection Wick Filter
   // Guard 2: NWE Volatility Anti-Overextension Band
   if(!g_cachedOnnxValid)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "ONNX_INVALID";
      LogTradeAttempt(rec);
      return false;
   }

   // 0.8 GUARD: Liquidity Sweep Exhaustion Lockout (Sweep Memory)
   datetime bar0Time = iTime(_Symbol, _Period, 0);
   if(direction == "SELL" && g_lastSweepLowTime > 0 && (bar0Time - g_lastSweepLowTime) <= 6 * PeriodSeconds(_Period))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SWEEP_LOW_LOCKOUT";
      rec.ai_reason_text = StringFormat("SELL blocked: Liquidity Sweep Low detected within last 6 bars (%s). High risk of mean-reversion rally.",
                                        TimeToString(g_lastSweepLowTime, TIME_MINUTES));
      LogTradeAttempt(rec);
      return false;
   }
   if(direction == "BUY" && g_lastSweepHighTime > 0 && (bar0Time - g_lastSweepHighTime) <= 6 * PeriodSeconds(_Period))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SWEEP_HIGH_LOCKOUT";
      rec.ai_reason_text = StringFormat("BUY blocked: Liquidity Sweep High detected within last 6 bars (%s). High risk of mean-reversion drop.",
                                        TimeToString(g_lastSweepHighTime, TIME_MINUTES));
      LogTradeAttempt(rec);
      return false;
   }

   // 1. BOSS 1: SuperGRU Directional Conviction & Symmetrical Margin
   double dirProb = (direction == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
   double oppProb = (direction == "BUY" ? g_cachedOnnxBear : g_cachedOnnxBull);
   double margin  = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);

   double activeConf = InpOnnxConfidence;
   double activeMargin = InpOnnxMargin;
   string activeZoneName = "";
   string activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

   if(dirProb < InpStrategyOnnxMinProb || dirProb <= oppProb || margin < activeMargin)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SUPERGRU_DISAGREEMENT";
      rec.ai_reason_text = StringFormat("SuperGRU %s %.3f < %.3f min or Margin %.3f < %.3f (%s)",
                                        direction, dirProb, InpStrategyOnnxMinProb, margin, activeMargin, activeZoneName);
      LogTradeAttempt(rec);
      return false;
   }

   bool strongGruTrend = (dirProb >= 0.60 && margin >= 0.15);

   // 2. BOSS 2: Master AI Microstructure Confirmation (Hierarchical Decoupling)
   if(g_masterValid)
   {
      double masterDirProb = (direction == "BUY" ? g_masterProbBull : g_masterProbBear);
      double masterOppProb = (direction == "BUY" ? g_masterProbBear : g_masterProbBull);
      double masterMargin  = MathAbs(masterDirProb - masterOppProb);

      if(strongGruTrend)
      {
         // In a strong macro trend run, Master AI only blocks if opposing conviction is extreme (>= 65% with >= 20% margin)
         if(masterOppProb >= 0.65 && masterMargin >= 0.20)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DUAL_AI_DIVERGENCE";
            rec.ai_reason_text = StringFormat("Master AI Strong Counter-Conviction (%s %.3f vs %s %.3f)",
                                              (direction == "BUY" ? "Bear" : "Bull"), masterOppProb, (direction == "BUY" ? "Bull" : "Bear"), masterDirProb);
            LogTradeAttempt(rec);
            return false;
         }
      }
      else
      {
         // Symmetrical directional dominance requirement in normal/balanced market conditions: >= 55% with >= 10% margin lead
         if(masterDirProb < 0.55 || masterMargin < 0.10 || masterDirProb <= masterOppProb)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DUAL_AI_DIVERGENCE";
            rec.ai_reason_text = StringFormat("Dual-AI Divergence: SuperGRU %s %.3f but Master AI %s %.3f < 0.55 or Margin %.3f < 0.10",
                                              direction, dirProb, (direction == "BUY" ? "Bull" : "Bear"), masterDirProb, masterMargin);
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

   // 3. BOSS 3: Dual-Horizon Order Flow Delta Institutional Alignment (Filtered for Noise)
   if(g_masterValid)
   {
      if(direction == "BUY")
      {
         // Block BUY if macro delta is strongly negative (selling momentum < -10%)
         if(g_masterMacroDelta12Pct < -10.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("BUY blocked: 60m Macro Delta %+.1f%% < -10.0%% (Bearish Momentum)", g_masterMacroDelta12Pct);
            LogTradeAttempt(rec);
            return false;
         }
         // In standard entries (not strong GRU trend), require positive or neutral macro delta (>= 0.0)
         else if(!strongGruTrend && g_masterMacroDelta12Pct < 0.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("BUY blocked: 60m Macro Delta %+.1f%% < 0.0%% in non-trend market", g_masterMacroDelta12Pct);
            LogTradeAttempt(rec);
            return false;
         }
         // Fast delta rejection if strong short-term aggressive dumping (< -15%)
         else if(g_masterFastDelta3Pct < -15.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "FAST_DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("BUY blocked: 15m Fast Delta %+.1f%% < -15.0%% (Severe Short-term Selling Pressure)", g_masterFastDelta3Pct);
            LogTradeAttempt(rec);
            return false;
         }
      }
      else if(direction == "SELL")
      {
         // Block SELL if macro delta is strongly positive (buying momentum > +10%)
         if(g_masterMacroDelta12Pct > 10.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("SELL blocked: 60m Macro Delta %+.1f%% > +10.0%% (Bullish Momentum)", g_masterMacroDelta12Pct);
            LogTradeAttempt(rec);
            return false;
         }
         // In standard entries (not strong GRU trend), require negative or neutral macro delta (<= 0.0)
         else if(!strongGruTrend && g_masterMacroDelta12Pct > 0.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("SELL blocked: 60m Macro Delta %+.1f%% > 0.0%% in non-trend market", g_masterMacroDelta12Pct);
            LogTradeAttempt(rec);
            return false;
         }
         // Fast delta rejection if strong short-term aggressive absorption (> +15%)
         else if(g_masterFastDelta3Pct > 15.0)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "FAST_DELTA_CONFLICT";
            rec.ai_reason_text = StringFormat("SELL blocked: 15m Fast Delta %+.1f%% > +15.0%% (Severe Short-term Buyer Absorption)", g_masterFastDelta3Pct);
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

   // 4. GUARD 1: Candle Direction & Absorption Wick Filter
   double open1   = iOpen(_Symbol, _Period, 1);
   double close1  = iClose(_Symbol, _Period, 1);
   double high1   = iHigh(_Symbol, _Period, 1);
   double low1    = iLow(_Symbol, _Period, 1);
   double range1  = MathMax(high1 - low1, 1e-8);
   double loWick1 = (MathMin(open1, close1) - low1) / range1;
   double upWick1 = (high1 - MathMax(open1, close1)) / range1;

   // For BUY: Do not buy into a solid falling red bar unless it has a >= 20% lower rejection wick
   if(direction == "BUY" && close1 < open1 && loWick1 < 0.20)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "CANDLE_MOMENTUM_CONFLICT";
      rec.ai_reason_text = StringFormat("Red Bar (Close %.2f < Open %.2f) without lower absorption wick (%.1f%% < 20%%)",
                                        close1, open1, loWick1 * 100.0);
      LogTradeAttempt(rec);
      return false;
   }
   // For SELL: Do not sell into a solid rising green bar unless it has a >= 20% upper rejection wick
   else if(direction == "SELL" && close1 > open1 && upWick1 < 0.20)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "CANDLE_MOMENTUM_CONFLICT";
      rec.ai_reason_text = StringFormat("Green Bar (Close %.2f > Open %.2f) without upper absorption wick (%.1f%% < 20%%)",
                                        close1, open1, upWick1 * 100.0);
      LogTradeAttempt(rec);
      return false;
   }

   // 5. GUARD 2: NWE Dynamic Volatility Anti-Overextension Guard (Universal Boundary)
   if(InpUseNweEngine && g_nweMAE > 0.0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double c0  = iClose(_Symbol, _Period, 0);
      double nweRange = g_nweUpperBand - g_nweLowerBand;

      if(nweRange > 0.0)
      {
         double channelPos = (c0 - g_nweLowerBand) / nweRange; // 0.0 = lower band floor, 1.0 = upper band ceiling

         if(direction == "BUY" && (ask >= g_nweUpperBand || channelPos > 0.80))
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "NWE_OVEREXTENSION";
            rec.ai_reason_text = StringFormat("BUY blocked: Price %.2f at Upper NWE Band %.2f (Channel Pos %.1f%% > 80%% Ceiling)",
                                              ask, g_nweUpperBand, channelPos * 100.0);
            LogTradeAttempt(rec);
            return false;
         }
         else if(direction == "SELL" && (bid <= g_nweLowerBand || channelPos < 0.20))
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "NWE_OVEREXTENSION";
            rec.ai_reason_text = StringFormat("SELL blocked: Price %.2f at Lower NWE Band %.2f (Channel Pos %.1f%% < 20%% Floor)",
                                              bid, g_nweLowerBand, channelPos * 100.0);
            LogTradeAttempt(rec);
            return false;
         }
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

   //=== GATE 2c: Concurrent Position Spacing & Cooldown Filter ===
   if(InpMinEntrySpacingPts > 0.0 || InpMinEntryCooldownBars > 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      datetime nowTime = TimeCurrent();

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         if(posDir != direction)
            continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

         // Check time cooldown
         int elapsedSecs = (int)(nowTime - openTime);
         int requiredCooldownSecs = InpMinEntryCooldownBars * PeriodSeconds(_Period);
         if(InpMinEntryCooldownBars > 0 && elapsedSecs < requiredCooldownSecs)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "CONCURRENT_ENTRY_COOLDOWN";
            rec.ai_reason_text = StringFormat("Position #%I64u opened %d sec ago (< %d sec cooldown)",
                                              ticket, elapsedSecs, requiredCooldownSecs);
            LogTradeAttempt(rec);
            return false;
         }

         // Check price spacing
         if(InpMinEntrySpacingPts > 0.0)
         {
            if(direction == "BUY" && ask < openPrice + InpMinEntrySpacingPts * _Point)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "CONCURRENT_ENTRY_SPACING";
               rec.ai_reason_text = StringFormat("BUY spacing too close: Ask %.2f vs Open %.2f (< %.1f pts)",
                                                 ask, openPrice, InpMinEntrySpacingPts);
               LogTradeAttempt(rec);
               return false;
            }
            else if(direction == "SELL" && bid > openPrice - InpMinEntrySpacingPts * _Point)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "CONCURRENT_ENTRY_SPACING";
               rec.ai_reason_text = StringFormat("SELL spacing too close: Bid %.2f vs Open %.2f (< %.1f pts)",
                                                 bid, openPrice, InpMinEntrySpacingPts);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== GATE 2d: Consecutive Same-Level Cluster Loss Brake ===
   // Prevent spamming entries into the same level if stopped out repeatedly (e.g. 2+ losses within 8 pts in 60 mins)
   {
      double curPrice = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      datetime windowStart = TimeCurrent() - 3600; // 60 minutes rolling
      HistorySelect(windowStart, TimeCurrent());
      int histDeals = HistoryDealsTotal();
      int recentSameLevelLosses = 0;

      for(int d = histDeals - 1; d >= 0; d--)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         
         double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
         if(profit < 0.0)
         {
            long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
            string closedDir = (dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
            if(closedDir == direction)
            {
               double dealPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
               if(MathAbs(dealPrice - curPrice) <= 8.0) // within 8 USD points
               {
                  recentSameLevelLosses++;
               }
            }
         }
      }

      if(recentSameLevelLosses >= 2)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "PRICE_CLUSTER_LOSS_LIMIT";
         rec.ai_reason_text = StringFormat("%s blocked: %d stopped trades at price level %.2f within last 60 mins",
                                           direction, recentSameLevelLosses, curPrice);
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
   if(InpUseNweEngine && InpUseNweExhaustionVeto)
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

   // SL/TP distances (ATR contract: SL=4xATR, TP=8xATR)
   double slDistUSD = useATR ? (InpATRMultiplier * atrNow) : InpExitSLDistUSD;
   if(slDistUSD <= 0.0) slDistUSD = 5.0; // fallback safety
   double tpDistUSD = useATR ? (slDistUSD * InpFomoRRRatio) : InpExitTPDistUSD;

   double lot = CalculateDynamicBalanceLot(slDistUSD);

   if(lot <= 0.0)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "RISK_CAP_UNHONORED";
      LogTradeAttempt(rec);
      return false;
   }

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
      rec.risk_usd    = (slDistUSD * lot * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / MathMax(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 1e-8));
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
   
   // 3. Check Session Standby & Curfew
   string zoneBlockReason = "";
   if(!IsZoneTradingAllowed(zoneBlockReason))
   {
      nextAction = StringFormat("BLOCKED (%s)", zoneBlockReason);
      g_lastBlockSource = "SESSION_STANDBY";
      g_lastBlockReason = zoneBlockReason;
      return;
   }

   // 3.5. Check Sweep Memory Lockout
   datetime bar0T = iTime(_Symbol, _Period, 0);
   if(dir == "SELL" && g_lastSweepLowTime > 0 && (bar0T - g_lastSweepLowTime) <= 6 * PeriodSeconds(_Period))
   {
      nextAction = "BLOCKED (Sweep Low Lockout — 6 Bar Protection)";
      g_lastBlockSource = "SWEEP_LOCKOUT";
      g_lastBlockReason = "SWEEP_LOW_LOCKOUT";
      return;
   }
   if(dir == "BUY" && g_lastSweepHighTime > 0 && (bar0T - g_lastSweepHighTime) <= 6 * PeriodSeconds(_Period))
   {
      nextAction = "BLOCKED (Sweep High Lockout — 6 Bar Protection)";
      g_lastBlockSource = "SWEEP_LOCKOUT";
      g_lastBlockReason = "SWEEP_HIGH_LOCKOUT";
      return;
   }

   // 4. Check 3-Boss Alignment: Dual-AI Hierarchical Consensus & Order Flow Delta
   if(g_masterValid)
   {
      bool strongGru = (dirProb >= 0.60 && margin >= 0.15);
      if(dir == "BUY")
      {
         if(!strongGru && (g_masterProbBull < 0.55 || (g_masterProbBull - g_masterProbBear) < 0.10 || g_masterProbBull <= g_masterProbBear))
         {
            nextAction = StringFormat("BLOCKED (AI Divergence: Macro BUY vs Micro %s %.1f%%)",
                                      (g_masterProbBull >= g_masterProbBear ? "BULL" : "BEAR"), MathMax(g_masterProbBull, g_masterProbBear) * 100.0);
            g_lastBlockSource = "DUAL_AI";
            g_lastBlockReason = StringFormat("DIVERGENCE (Macro BUY vs Micro %s)", (g_masterProbBull >= g_masterProbBear ? "BULL" : "BEAR"));
            return;
         }
         else if(g_masterMacroDelta12Pct < -10.0 || (!strongGru && g_masterMacroDelta12Pct < 0.0))
         {
            nextAction = StringFormat("BLOCKED (Flow Conflict: 60m Delta %+.1f%%)", g_masterMacroDelta12Pct);
            g_lastBlockSource = "ORDER_FLOW";
            g_lastBlockReason = StringFormat("DELTA_CONFLICT (60m Delta %+.1f%%)", g_masterMacroDelta12Pct);
            return;
         }
         else if(g_masterFastDelta3Pct < -15.0)
         {
            nextAction = StringFormat("BLOCKED (Flow Divergence: 15m Fast Delta %+.1f%% < -15%%)", g_masterFastDelta3Pct);
            g_lastBlockSource = "ORDER_FLOW";
            g_lastBlockReason = StringFormat("FAST_DELTA_CONFLICT (15m Delta %+.1f%% < -15%%)", g_masterFastDelta3Pct);
            return;
         }
      }
      else if(dir == "SELL")
      {
         if(!strongGru && (g_masterProbBear < 0.55 || (g_masterProbBear - g_masterProbBull) < 0.10 || g_masterProbBear <= g_masterProbBull))
         {
            nextAction = StringFormat("BLOCKED (AI Divergence: Macro SELL vs Micro %s %.1f%%)",
                                      (g_masterProbBull >= g_masterProbBear ? "BULL" : "BEAR"), MathMax(g_masterProbBull, g_masterProbBear) * 100.0);
            g_lastBlockSource = "DUAL_AI";
            g_lastBlockReason = StringFormat("DIVERGENCE (Macro SELL vs Micro %s)", (g_masterProbBull >= g_masterProbBear ? "BULL" : "BEAR"));
            return;
         }
         else if(g_masterMacroDelta12Pct > 10.0 || (!strongGru && g_masterMacroDelta12Pct > 0.0))
         {
            nextAction = StringFormat("BLOCKED (Flow Conflict: 60m Delta %+.1f%%)", g_masterMacroDelta12Pct);
            g_lastBlockSource = "ORDER_FLOW";
            g_lastBlockReason = StringFormat("DELTA_CONFLICT (60m Delta %+.1f%%)", g_masterMacroDelta12Pct);
            return;
         }
         else if(g_masterFastDelta3Pct > 15.0)
         {
            nextAction = StringFormat("BLOCKED (Flow Divergence: 15m Fast Delta %+.1f%% > +15%%)", g_masterFastDelta3Pct);
            g_lastBlockSource = "ORDER_FLOW";
            g_lastBlockReason = StringFormat("FAST_DELTA_CONFLICT (15m Delta %+.1f%% > +15%%)", g_masterFastDelta3Pct);
            return;
         }
      }
   }

   // 5. Check NWE Volatility Exhaustion Veto
   if(InpUseNweEngine)
   {
      double c0 = iClose(_Symbol, _Period, 0);
      double nweRange = g_nweUpperBand - g_nweLowerBand;
      double channelPos = (nweRange > 0.0) ? (c0 - g_nweLowerBand) / nweRange : 0.5;

      if(dir == "BUY" && (IsPriceAtTopExhaustion() || channelPos > 0.80))
      {
         nextAction = "BLOCKED (NWE Top Ceiling Veto > 80%)";
         g_lastBlockSource = "NWE_EXHAUSTION";
         g_lastBlockReason = StringFormat("TOP_EXHAUSTION (Channel Pos %.1f%% > 80%%)", channelPos * 100.0);
         return;
      }
      else if(dir == "SELL" && (IsPriceAtBottomExhaustion() || channelPos < 0.20))
      {
         nextAction = "BLOCKED (NWE Bottom Floor Veto < 20%)";
         g_lastBlockSource = "NWE_EXHAUSTION";
         g_lastBlockReason = StringFormat("BOTTOM_EXHAUSTION (Channel Pos %.1f%% < 20%%)", channelPos * 100.0);
         return;
      }
   }

   // 6. Check ONNX Core conviction thresholds (using dynamic settings)
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
   
   nextAction = StringFormat("%s (Tri-Core Locked & Ready)", dir);
   g_lastBlockSource = "NONE";
   g_lastBlockReason = "All Systems Clear (3 Bosses Aligned)";
}

#endif // GE_ENTRYGATES_MQH
