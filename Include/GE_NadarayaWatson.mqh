//+------------------------------------------------------------------+
//| GE_NadarayaWatson.mqh                                            |
//| Dedicated 1:1 LuxAlgo Nadaraya-Watson Envelope Mathematical Engine |
//| Gaussian Kernel Smoothing (10 3 open) + Statistical Veto Gating  |
//+------------------------------------------------------------------+
#ifndef GE_NADARAYAWATSON_MQH
#define GE_NADARAYAWATSON_MQH

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Nadaraya-Watson Statistical Engine (1:1 TradingView) ==="
input bool               InpUseNweEngine        = true;        // Enable Nadaraya-Watson Statistical Engine
input double             InpNweBandwidth        = 10.0;        // Bandwidth (h) — Gaussian smoothing width (TV: 10)
input double             InpNweMultiplier       = 3.0;         // Multiplier (mult) — MAE envelope width (TV: 3)
input ENUM_APPLIED_PRICE InpNweSource           = PRICE_OPEN;  // Price Source (TV: open)
input int                InpNweLookback         = 250;         // Historical Lookback Window
input bool               InpUseNweExhaustionVeto= true;        // Enable Anti-Top-Buy & Anti-Bottom-Sell Veto
input double             InpNweVetoThresholdPct = 0.90;        // Veto Zone: % of envelope width (0.90 = Top/Bottom 10%)
input bool               InpUseNWEReversal      = true;        // Enable NWE Outer-Band Mean-Reversal Strategy

//+------------------------------------------------------------------+
//| Global State Variables                                           |
//+------------------------------------------------------------------+
double g_nweMidline     = 0.0;
double g_nweMidlinePrev = 0.0;
double g_nweUpperBand   = 0.0;
double g_nweLowerBand   = 0.0;
double g_nweMAE         = 0.0;
int    g_nweActiveRegime= 0;   // -1 = Bearish Regime, 1 = Bullish Regime
double g_nweAnchorPrice = 0.0;

//+------------------------------------------------------------------+
//| UpdateNweEngine — Full Two-Sided Gaussian Kernel Regression      |
//+------------------------------------------------------------------+
void UpdateNweEngine()
{
   if(!InpUseNweEngine) return;

   double srcPrices[], highPrices[], lowPrices[];
   ArraySetAsSeries(srcPrices, true);
   ArraySetAsSeries(highPrices, true);
   ArraySetAsSeries(lowPrices, true);

   int copied = 0;
   if(InpNweSource == PRICE_OPEN)
      copied = CopyOpen(_Symbol, _Period, 0, InpNweLookback + 50, srcPrices);
   else if(InpNweSource == PRICE_CLOSE)
      copied = CopyClose(_Symbol, _Period, 0, InpNweLookback + 50, srcPrices);
   else if(InpNweSource == PRICE_HIGH)
      copied = CopyHigh(_Symbol, _Period, 0, InpNweLookback + 50, srcPrices);
   else if(InpNweSource == PRICE_LOW)
      copied = CopyLow(_Symbol, _Period, 0, InpNweLookback + 50, srcPrices);
   else
      copied = CopyOpen(_Symbol, _Period, 0, InpNweLookback + 50, srcPrices);

   CopyHigh(_Symbol, _Period, 0, InpNweLookback + 50, highPrices);
   CopyLow(_Symbol, _Period, 0, InpNweLookback + 50, lowPrices);

   if(copied < 30) return;

   int N = MathMin(copied, InpNweLookback);
   double y2[];
   ArrayResize(y2, N);

   double h2 = 2.0 * InpNweBandwidth * InpNweBandwidth;

   // 1. Two-Sided Symmetric Gaussian Kernel (Exact LuxAlgo Pine Script formula)
   double sumMAE = 0.0;
   for(int i = 0; i < N; i++)
   {
      double sumVal = 0.0;
      double sumW   = 0.0;
      for(int j = 0; j < N; j++)
      {
         double diff = (double)(i - j);
         double w = MathExp(-(diff * diff) / h2);
         sumVal += srcPrices[j] * w;
         sumW   += w;
      }
      y2[i] = (sumW > 0.0) ? (sumVal / sumW) : srcPrices[i];
      sumMAE += MathAbs(srcPrices[i] - y2[i]);
   }

   double mae = (N > 0) ? ((sumMAE / (double)N) * InpNweMultiplier) : 10.0;
   g_nweMAE         = mae;
   g_nweMidline     = y2[0];
   g_nweMidlinePrev = (N > 3) ? y2[3] : y2[0];
   g_nweUpperBand   = y2[0] + mae;
   g_nweLowerBand   = y2[0] - mae;

   // 2. Scan for last closed regime breach backwards from bar 1
   int foundSignal = 0;
   double foundPrice = 0.0;

   for(int k = 1; k < N; k++)
   {
      double upper = y2[k] + mae;
      double lower = y2[k] - mae;

      bool isSell = (highPrices[k] >= upper);
      bool isBuy  = (lowPrices[k] <= lower);

      if(isSell && !isBuy)
      {
         foundSignal = -1;
         foundPrice = highPrices[k];
         break;
      }
      else if(isBuy && !isSell)
      {
         foundSignal = 1;
         foundPrice = lowPrices[k];
         break;
      }
   }

   if(foundSignal == 0)
   {
      foundSignal = (y2[1] < y2[2]) ? -1 : 1;
      foundPrice = (foundSignal == -1) ? (y2[1] + mae) : (y2[1] - mae);
   }

   g_nweActiveRegime = foundSignal;
   g_nweAnchorPrice  = foundPrice;
}

//+------------------------------------------------------------------+
//| Getters                                                          |
//+------------------------------------------------------------------+
double GetNweUpperBand()    { return g_nweUpperBand; }
double GetNweLowerBand()    { return g_nweLowerBand; }
double GetNweMidline()      { return g_nweMidline; }
double GetNweMidlinePrev()  { return g_nweMidlinePrev; }
double GetNweMAE()          { return g_nweMAE; }
double GetNweSlope()        { return g_nweMidline - g_nweMidlinePrev; }
int    GetNweActiveRegime() { return g_nweActiveRegime; }
double GetNweAnchorPrice()  { return g_nweAnchorPrice; }

//+------------------------------------------------------------------+
//| Exhaustion Veto Detectors                                        |
//+------------------------------------------------------------------+
bool IsPriceAtTopExhaustion()
{
   if(!InpUseNweEngine || !InpUseNweExhaustionVeto || g_nweMAE <= 0.0) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double topVetoLevel = g_nweMidline + (g_nweMAE * InpNweVetoThresholdPct);
   return (ask >= topVetoLevel);
}

bool IsPriceAtBottomExhaustion()
{
   if(!InpUseNweEngine || !InpUseNweExhaustionVeto || g_nweMAE <= 0.0) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bottomVetoLevel = g_nweMidline - (g_nweMAE * InpNweVetoThresholdPct);
   return (bid <= bottomVetoLevel);
}

#endif // GE_NADARAYAWATSON_MQH
