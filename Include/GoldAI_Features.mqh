//+------------------------------------------------------------------+
//|                                            GoldAI_Features.mqh   |
//|               Quantitative 76-Feature Microstructure Engine      |
//|        100% Mathematically Exact Match to Python Feature Engine  |
//+------------------------------------------------------------------+
#property copyright "Titan Gold Sentinel Institutional AI"
#property link      "https://github.com/vivekpanchal2489/Titan_Gold_AI_Quantum"
#property strict

#define FEAT_COUNT 76
#define EPS        1e-10

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

class CGoldAIFeatures
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   
   int               m_atrHandle;
   int               m_rsiHandle;
   int               m_macdHandle;
   int               m_adxHandle;
   int               m_ema20M5Handle;
   int               m_ema50M5Handle;
   
   int               m_atrH1Handle;
   int               m_ema20H1Handle;
   int               m_atrH4Handle;
   int               m_ema20H4Handle;
   int               m_atrD1Handle;
   int               m_ema20D1Handle;
   
   double            m_lastAtr;

public:
   string            m_symEUR, m_symJPY, m_symGBP, m_symCAD, m_symSEK, m_symCHF;

   string DiscoverBrokerSymbol(string standardName)
   {
      if(SymbolSelect(standardName, true)) return standardName;
      
      string lower = standardName;
      StringToLower(lower);
      if(SymbolSelect(lower, true)) return lower;
      
      int total = SymbolsTotal(false);
      for(int i = 0; i < total; i++)
      {
         string name = SymbolName(i, false);
         string nameUpper = name;
         StringToUpper(nameUpper);
         if(StringFind(nameUpper, standardName) >= 0)
         {
            SymbolSelect(name, true);
            return name;
         }
      }
      return standardName;
   }

public:
   CGoldAIFeatures() : m_symbol(""), m_tf(PERIOD_M5),
      m_atrHandle(INVALID_HANDLE), m_rsiHandle(INVALID_HANDLE),
      m_macdHandle(INVALID_HANDLE), m_adxHandle(INVALID_HANDLE),
      m_ema20M5Handle(INVALID_HANDLE), m_ema50M5Handle(INVALID_HANDLE),
      m_atrH1Handle(INVALID_HANDLE), m_ema20H1Handle(INVALID_HANDLE),
      m_atrH4Handle(INVALID_HANDLE), m_ema20H4Handle(INVALID_HANDLE),
      m_atrD1Handle(INVALID_HANDLE), m_ema20D1Handle(INVALID_HANDLE),
      m_lastAtr(2.0),
      m_symEUR("EURUSD"), m_symJPY("USDJPY"), m_symGBP("GBPUSD"),
      m_symCAD("USDCAD"), m_symSEK("USDSEK"), m_symCHF("USDCHF") {}
      
   ~CGoldAIFeatures() { Release(); }
   
   double GetSafeClose(string sym, int shift)
   {
      double c = iClose(sym, m_tf, shift);
      if(c > 0.0) return c;
      c = iClose(sym, m_tf, 0);
      if(c > 0.0) return c;
      return SymbolInfoDouble(sym, SYMBOL_BID);
   }

   double CalculateDXYAtBar(int shift)
   {
      double eur = GetSafeClose(m_symEUR, shift);
      double jpy = GetSafeClose(m_symJPY, shift);
      double gbp = GetSafeClose(m_symGBP, shift);
      double cad = GetSafeClose(m_symCAD, shift);
      double sek = GetSafeClose(m_symSEK, shift);
      double chf = GetSafeClose(m_symCHF, shift);
      
      if(eur > 0 && jpy > 0 && gbp > 0 && cad > 0 && sek > 0 && chf > 0)
      {
         return 50.14348112 * 
                MathPow(eur, -0.576) * 
                MathPow(jpy, 0.136) * 
                MathPow(gbp, -0.119) * 
                MathPow(cad, 0.091) * 
                MathPow(sek, 0.042) * 
                MathPow(chf, 0.036);
      }
      if(eur > 0 && jpy > 0 && gbp > 0)
      {
         return 50.14348112 * MathPow(eur, -0.69) * MathPow(jpy, 0.16) * MathPow(gbp, -0.15);
      }
      if(eur > 0)
      {
         return 100.0 / MathPow(eur, 0.576);
      }
      return 100.0;
   }

   double CalculateRealTimeDXY()
   {
      return CalculateDXYAtBar(0);
   }

   bool Initialize(string symbol = NULL, ENUM_TIMEFRAMES tf = PERIOD_M5)
   {
      m_symbol = (symbol == NULL || symbol == "" ? _Symbol : symbol);
      m_tf = tf;
      
      m_symEUR = DiscoverBrokerSymbol("EURUSD");
      m_symJPY = DiscoverBrokerSymbol("USDJPY");
      m_symGBP = DiscoverBrokerSymbol("GBPUSD");
      m_symCAD = DiscoverBrokerSymbol("USDCAD");
      m_symSEK = DiscoverBrokerSymbol("USDSEK");
      m_symCHF = DiscoverBrokerSymbol("USDCHF");
      
      m_atrHandle      = iATR(m_symbol, m_tf, 14);
      m_rsiHandle      = iRSI(m_symbol, m_tf, 14, PRICE_CLOSE);
      m_macdHandle     = iMACD(m_symbol, m_tf, 12, 26, 9, PRICE_CLOSE);
      m_adxHandle      = iADX(m_symbol, m_tf, 14);
      m_ema20M5Handle  = iMA(m_symbol, m_tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      m_ema50M5Handle  = iMA(m_symbol, m_tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      
      m_atrH1Handle    = iATR(m_symbol, PERIOD_H1, 14);
      m_ema20H1Handle  = iMA(m_symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
      m_atrH4Handle    = iATR(m_symbol, PERIOD_H4, 14);
      m_ema20H4Handle  = iMA(m_symbol, PERIOD_H4, 20, 0, MODE_EMA, PRICE_CLOSE);
      m_atrD1Handle    = iATR(m_symbol, PERIOD_D1, 14);
      m_ema20D1Handle  = iMA(m_symbol, PERIOD_D1, 20, 0, MODE_EMA, PRICE_CLOSE);
      
      return (m_atrHandle != INVALID_HANDLE && m_rsiHandle != INVALID_HANDLE);
   }

   bool Init(string symbol = NULL, ENUM_TIMEFRAMES tf = PERIOD_M5, bool enableDxy = true)
   {
      return Initialize(symbol, tf);
   }
   
   void Release()
   {
      if(m_atrHandle != INVALID_HANDLE)      IndicatorRelease(m_atrHandle);
      if(m_rsiHandle != INVALID_HANDLE)      IndicatorRelease(m_rsiHandle);
      if(m_macdHandle != INVALID_HANDLE)     IndicatorRelease(m_macdHandle);
      if(m_adxHandle != INVALID_HANDLE)      IndicatorRelease(m_adxHandle);
      if(m_ema20M5Handle != INVALID_HANDLE)  IndicatorRelease(m_ema20M5Handle);
      if(m_ema50M5Handle != INVALID_HANDLE)  IndicatorRelease(m_ema50M5Handle);
      if(m_atrH1Handle != INVALID_HANDLE)    IndicatorRelease(m_atrH1Handle);
      if(m_ema20H1Handle != INVALID_HANDLE)  IndicatorRelease(m_ema20H1Handle);
      if(m_atrH4Handle != INVALID_HANDLE)    IndicatorRelease(m_atrH4Handle);
      if(m_ema20H4Handle != INVALID_HANDLE)  IndicatorRelease(m_ema20H4Handle);
      if(m_atrD1Handle != INVALID_HANDLE)    IndicatorRelease(m_atrD1Handle);
      if(m_ema20D1Handle != INVALID_HANDLE)  IndicatorRelease(m_ema20D1Handle);
   }

   void Shutdown() { Release(); }
   
   double GetLatestATR() { return m_lastAtr; }
   double GetLatestDXY() { return CalculateRealTimeDXY(); }

   double GetATRAtBar(int shift)
   {
      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(m_atrHandle, 0, shift, 1, atrBuf) >= 1 && atrBuf[0] > 0.0)
         return atrBuf[0];
      return 2.0;
   }

   //+------------------------------------------------------------------+
   //| Extract Exactly 76 Features Matching Python Training Order       |
   //+------------------------------------------------------------------+
   bool ExtractFeaturesAtBar(int shift, float &features[])
   {
      if(ArraySize(features) < FEAT_COUNT)
         ArrayResize(features, FEAT_COUNT);

      // Need 100 M5 bars for lookbacks
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      if(CopyRates(m_symbol, m_tf, shift, 100, rates) < 100)
         return false;

      double atrBuf[];
      double rsiBuf[];
      ArraySetAsSeries(atrBuf, true);
      ArraySetAsSeries(rsiBuf, true);
      if(CopyBuffer(m_atrHandle, 0, shift, 1, atrBuf) < 1 ||
         CopyBuffer(m_rsiHandle, 0, shift, 5, rsiBuf) < 5)
         return false;

      double atr = atrBuf[0];
      if(atr <= 0) atr = 2.0;
      m_lastAtr = atr;
      
      double c0 = rates[0].close;
      double o0 = rates[0].open;
      double h0 = rates[0].high;
      double l0 = rates[0].low;
      double v0 = (double)rates[0].tick_volume;
      double hl_range0 = MathMax(h0 - l0, EPS);

      // ---------------------------------------------------------------
      // Group A: Real Order Flow & Microstructure (14 Features: 0 to 13)
      // ---------------------------------------------------------------
      // Estimate tick order flow from live tick cache / volume action
      double buy_v = 0.0, sell_v = 0.0, imbal = 0.0;
      double cum_delta_12 = 0.0, cum_delta_12_s3 = 0.0;
      double trade_cnt = MathMax((double)rates[0].tick_volume, 1.0);
      
      // Calculate delta across 15 bars
      double deltas[15];
      for(int k = 0; k < 15; k++)
      {
         double bar_range = MathMax(rates[k].high - rates[k].low, EPS);
         double bar_body = rates[k].close - rates[k].open;
         double bv = (double)rates[k].tick_volume * MathMax(0.0, MathMin(1.0, 0.5 + 0.5 * (bar_body / bar_range)));
         double sv = (double)rates[k].tick_volume - bv;
         deltas[k] = bv - sv;
         if(k == 0) { buy_v = bv; sell_v = sv; imbal = (bv + sv > 0.0) ? (bv - sv)/(bv + sv) : 0.0; }
      }
      for(int k = 0; k < 12; k++) cum_delta_12 += deltas[k];
      for(int k = 3; k < 15; k++) cum_delta_12_s3 += deltas[k];

      double tot_v = MathMax(buy_v + sell_v, EPS);
      features[0] = (float)(buy_v / tot_v);                            // 0: of_buy_vol_ratio
      features[1] = (float)(sell_v / tot_v);                           // 1: of_sell_vol_ratio
      features[2] = (float)imbal;                                      // 2: of_imbalance_ratio
      features[3] = (float)(cum_delta_12 / (atr + EPS));               // 3: of_cumulative_delta_12
      features[4] = (float)((cum_delta_12 - cum_delta_12_s3) / (atr + EPS)); // 4: of_delta_momentum
      
      double avg_trade_0 = tot_v / trade_cnt;
      double sum_avg_t = 0.0;
      for(int k = 0; k < 50; k++) sum_avg_t += (double)rates[k].tick_volume / MathMax((double)rates[k].tick_volume, 1.0);
      double mean_avg_t = sum_avg_t / 50.0;
      features[5] = (float)(avg_trade_0 / (mean_avg_t + EPS));         // 5: of_large_trade_ratio
      
      features[6] = (float)(MathAbs(c0 - o0) / hl_range0);             // 6: body_to_range
      features[7] = (float)((h0 - MathMax(o0, c0)) / hl_range0);       // 7: upper_wick_ratio
      features[8] = (float)((MathMin(o0, c0) - l0) / hl_range0);       // 8: lower_wick_ratio

      // Causal Confirmed 20-bar extremes (rates[1] to rates[20])
      double roll_low_20 = rates[1].low;
      double roll_high_20 = rates[1].high;
      for(int k = 1; k <= 20; k++)
      {
         roll_low_20 = MathMin(roll_low_20, rates[k].low);
         roll_high_20 = MathMax(roll_high_20, rates[k].high);
      }
      features[9]  = (float)((c0 - roll_low_20) / (atr + EPS));        // 9: pivot_support_dist
      features[10] = (float)((roll_high_20 - c0) / (atr + EPS));       // 10: pivot_resistance_dist

      // Causal Unfilled FVG
      double fvg_bull = MathMax(rates[0].low - rates[2].high, 0.0);
      double fvg_bear = MathMax(rates[2].low - rates[0].high, 0.0);
      features[11] = (float)(fvg_bull / (atr + EPS));                  // 11: fvg_causal_bull
      features[12] = (float)(fvg_bear / (atr + EPS));                  // 12: fvg_causal_bear

      // Liquidity sweep
      bool sw_high = (h0 > roll_high_20) && (c0 < roll_high_20);
      bool sw_low  = (l0 < roll_low_20)  && (c0 > roll_low_20);
      features[13] = sw_high ? 1.0f : (sw_low ? -1.0f : 0.0f);        // 13: liquidity_sweep

      // ---------------------------------------------------------------
      // Group B: Multi-Horizon Velocity & Momentum (10 Features: 14 to 23)
      // ---------------------------------------------------------------
      features[14] = (float)MathLog(c0 / MathMax(rates[1].close, EPS));  // 14: log_ret_1
      features[15] = (float)MathLog(c0 / MathMax(rates[5].close, EPS));  // 15: log_ret_5
      features[16] = (float)MathLog(c0 / MathMax(rates[12].close, EPS)); // 16: log_ret_12
      features[17] = (float)MathLog(c0 / MathMax(rates[24].close, EPS)); // 17: log_ret_24
      features[18] = (float)MathLog(c0 / MathMax(rates[48].close, EPS)); // 18: log_ret_48
      
      double ret5_s5 = MathLog(rates[5].close / MathMax(rates[10].close, EPS));
      features[19] = (float)(features[15] - ret5_s5);                   // 19: mom_acceleration

      features[20] = (float)((rsiBuf[0] - 50.0) / 50.0);               // 20: rsi_14_normalized
      features[21] = (float)(((rsiBuf[0] - 50.0) / 50.0) - ((rsiBuf[3] - 50.0) / 50.0)); // 21: rsi_14_slope

      double macdMain[], macdSig[];
      ArraySetAsSeries(macdMain, true); ArraySetAsSeries(macdSig, true);
      CopyBuffer(m_macdHandle, 0, shift, 4, macdMain);
      CopyBuffer(m_macdHandle, 1, shift, 4, macdSig);
      double macd_hist0 = (ArraySize(macdMain) >= 4 && ArraySize(macdSig) >= 4) ? (macdMain[0] - macdSig[0]) : 0.0;
      double macd_hist3 = (ArraySize(macdMain) >= 4 && ArraySize(macdSig) >= 4) ? (macdMain[3] - macdSig[3]) : 0.0;
      features[22] = (float)(macd_hist0 / (atr + EPS));                // 22: macd_hist_norm
      features[23] = (float)((macd_hist0 - macd_hist3) / (atr + EPS)); // 23: macd_slope

      // ---------------------------------------------------------------
      // Group C: Mean Overextension & Rubber-Band Stretch (6 Features: 24 to 29)
      // ---------------------------------------------------------------
      double ema20Buf[], ema50Buf[];
      ArraySetAsSeries(ema20Buf, true); ArraySetAsSeries(ema50Buf, true);
      CopyBuffer(m_ema20M5Handle, 0, shift, 1, ema20Buf);
      CopyBuffer(m_ema50M5Handle, 0, shift, 1, ema50Buf);
      double ema20 = ArraySize(ema20Buf) > 0 ? ema20Buf[0] : c0;
      double ema50 = ArraySize(ema50Buf) > 0 ? ema50Buf[0] : c0;

      features[24] = (float)((c0 - ema20) / (atr + EPS));              // 24: dist_ema20_m5
      features[25] = (float)((c0 - ema50) / (atr + EPS));              // 25: dist_ema50_m5

      double sum20 = 0.0, sum50 = 0.0;
      for(int k = 0; k < 20; k++) sum20 += rates[k].close;
      for(int k = 0; k < 50; k++) sum50 += rates[k].close;
      double sma20 = sum20 / 20.0, sma50 = sum50 / 50.0;
      double var20 = 0.0, var50 = 0.0;
      for(int k = 0; k < 20; k++) var20 += MathPow(rates[k].close - sma20, 2);
      for(int k = 0; k < 50; k++) var50 += MathPow(rates[k].close - sma50, 2);
      double std20 = MathSqrt(var20 / 20.0) + EPS;
      double std50 = MathSqrt(var50 / 50.0) + EPS;

      features[26] = (float)((c0 - sma20) / std20);                    // 26: zclose_20
      features[27] = (float)((c0 - sma50) / std50);                    // 27: zclose_50

      // Session VWAP (resets daily)
      MqlDateTime dt0;
      TimeToStruct(rates[0].time, dt0);
      double cum_pv = 0.0, cum_v = 0.0;
      for(int k = 0; k < 100; k++)
      {
         MqlDateTime dtk;
         TimeToStruct(rates[k].time, dtk);
         if(dtk.day != dt0.day) break;
         double vk = (double)rates[k].tick_volume;
         cum_pv += rates[k].close * vk;
         cum_v  += vk;
      }
      double vwap = cum_v > 0.0 ? (cum_pv / cum_v) : c0;
      features[28] = (float)((c0 - vwap) / (atr + EPS));               // 28: vwap_deviation
      features[29] = (float)(c0 >= roll_low_20 ? (c0 - roll_low_20) / (roll_high_20 - roll_low_20 + EPS) : 0.0); // 29: pullback_depth_from_swing

      // ---------------------------------------------------------------
      // Group D: Psychological Magnets & Structural S/R (4 Features: 30 to 33)
      // ---------------------------------------------------------------
      features[30] = (float)((MathMod(c0, 10.0) - 5.0) / (atr + EPS));  // 30: dist_round_10
      features[31] = (float)((MathMod(c0, 50.0) - 25.0) / (atr + EPS)); // 31: dist_round_50

      double pdh = iHigh(m_symbol, PERIOD_D1, 1);
      double pdl = iLow(m_symbol, PERIOD_D1, 1);
      if(pdh <= 0) pdh = c0 + atr * 2;
      if(pdl <= 0) pdl = c0 - atr * 2;
      features[32] = (float)(c0 > pdh ? (c0 - pdh)/(atr + EPS) : (c0 < pdl ? (pdl - c0)/(atr + EPS) : 0.0)); // 32: dist_prior_day_high_low

      double pwh = iHigh(m_symbol, PERIOD_W1, 1);
      double pwl = iLow(m_symbol, PERIOD_W1, 1);
      if(pwh <= 0) pwh = c0 + atr * 5;
      if(pwl <= 0) pwl = c0 - atr * 5;
      features[33] = (float)(c0 > pwh ? (c0 - pwh)/(atr + EPS) : (c0 < pwl ? (pwl - c0)/(atr + EPS) : 0.0)); // 33: dist_prior_week_high_low

      // ---------------------------------------------------------------
      // Group E: Volatility, Tail-Risk & Energy Regimes (8 Features: 34 to 41)
      // ---------------------------------------------------------------
      double atr_norm = atr / MathMax(c0, EPS);
      features[34] = (float)atr_norm;                                  // 34: atr_norm
      
      double sum_atr12 = 0.0;
      for(int k = 0; k < 12; k++) sum_atr12 += (k < ArraySize(atrBuf) ? atrBuf[k] : atr);
      double h1_atr_mean = sum_atr12 / 12.0;
      features[35] = (float)(atr / (h1_atr_mean + EPS));               // 35: atr_ratio_m5_h1

      // Garman-Klass & Parkinson Volatility (14 bars)
      double sum_gk = 0.0, sum_park = 0.0;
      for(int k = 0; k < 14; k++)
      {
         double hk = rates[k].high, lk = rates[k].low, ck = rates[k].close, ok = rates[k].open;
         double t1 = 0.5 * MathPow(MathLog(hk / MathMax(lk, EPS)), 2);
         double t2 = (2.0 * MathLog(2.0) - 1.0) * MathPow(MathLog(ck / MathMax(ok, EPS)), 2);
         sum_gk += MathSqrt(MathMax(t1 - t2, 0.0));
         sum_park += MathSqrt(MathPow(MathLog(hk / MathMax(lk, EPS)), 2) / (4.0 * MathLog(2.0)));
      }
      double gk_mean14 = sum_gk / 14.0;
      double park_mean14 = sum_park / 14.0;
      features[36] = (float)(gk_mean14 / (atr_norm + EPS));            // 36: garman_klass_vol
      features[37] = (float)(park_mean14 / (atr_norm + EPS));          // 37: parkinson_vol
      features[38] = (float)(4.0 * std20 / (sma20 + EPS));             // 38: bb_bandwidth_ratio
      features[39] = (float)(MathAbs(gk_mean14 - park_mean14));        // 39: vol_of_vol

      // Realized Skew & Kurtosis (20 bars of log_ret_1)
      double rets[20], mean_ret = 0.0;
      for(int k = 0; k < 20; k++)
      {
         rets[k] = MathLog(rates[k].close / MathMax(rates[k+1].close, EPS));
         mean_ret += rets[k];
      }
      mean_ret /= 20.0;
      double m2 = 0.0, m3 = 0.0, m4 = 0.0;
      for(int k = 0; k < 20; k++)
      {
         double diff = rets[k] - mean_ret;
         m2 += MathPow(diff, 2);
         m3 += MathPow(diff, 3);
         m4 += MathPow(diff, 4);
      }
      m2 /= 20.0; m3 /= 20.0; m4 /= 20.0;
      double s_std = MathSqrt(m2) + EPS;
      features[40] = (float)(m3 / MathPow(s_std, 3));                  // 40: realized_skew_20
      features[41] = (float)(m4 / MathPow(s_std, 4) - 3.0);            // 41: realized_kurtosis_20

      // ---------------------------------------------------------------
      // Group F: Cross-Asset Macro Dollar Matrix (8 Features: 42 to 49)
      // ---------------------------------------------------------------
      double dxy0 = CalculateDXYAtBar(shift);
      double dxy1 = CalculateDXYAtBar(shift + 1);
      double dxy5 = CalculateDXYAtBar(shift + 5);
      double dxy24 = CalculateDXYAtBar(shift + 24);
      double dxy48 = CalculateDXYAtBar(shift + 48);

      features[42] = (float)MathLog(dxy0 / MathMax(dxy1, EPS));        // 42: dxy_ret_1
      features[43] = (float)MathLog(dxy0 / MathMax(dxy5, EPS));        // 43: dxy_ret_5
      features[44] = (float)MathLog(dxy0 / MathMax(dxy24, EPS));       // 44: dxy_ret_24
      features[45] = (float)MathLog(dxy0 / MathMax(dxy48, EPS));       // 45: dxy_ret_48

      double dxy_sum20 = 0.0, dxy_sum50 = 0.0;
      for(int k = 0; k < 20; k++) dxy_sum20 += CalculateDXYAtBar(shift + k);
      for(int k = 0; k < 50; k++) dxy_sum50 += CalculateDXYAtBar(shift + k);
      double dxy_sma20 = dxy_sum20 / 20.0, dxy_sma50 = dxy_sum50 / 50.0;
      double dxy_var20 = 0.0, dxy_var50 = 0.0;
      for(int k = 0; k < 20; k++) dxy_var20 += MathPow(CalculateDXYAtBar(shift + k) - dxy_sma20, 2);
      for(int k = 0; k < 50; k++) dxy_var50 += MathPow(CalculateDXYAtBar(shift + k) - dxy_sma50, 2);
      double dxy_std20 = MathSqrt(dxy_var20 / 20.0) + EPS;
      double dxy_std50 = MathSqrt(dxy_var50 / 50.0) + EPS;

      features[46] = (float)((dxy0 - dxy_sma20) / dxy_std20);          // 46: dxy_zclose_20
      features[47] = (float)((dxy0 - dxy_sma50) / dxy_std50);          // 47: dxy_zclose_50
      
      // Correlation 48
      double gold_dxy_sum = 0.0;
      for(int k = 0; k < 48; k++)
      {
         double g_r = MathLog(rates[k].close / MathMax(rates[k+1].close, EPS));
         double d_r = MathLog(CalculateDXYAtBar(shift + k) / MathMax(CalculateDXYAtBar(shift + k + 1), EPS));
         gold_dxy_sum += g_r * d_r;
      }
      features[48] = (float)(gold_dxy_sum / 48.0 / (s_std * dxy_std20 + EPS)); // 48: gold_dxy_corr_48
      features[49] = (float)(features[17] + features[44]);             // 49: gold_dxy_divergence

      // ---------------------------------------------------------------
      // Group G: Higher-Timeframe Structural Trend (12 Features: 50 to 61)
      // ---------------------------------------------------------------
      int h1Shift = shift / 12 + 1; // Completed H1 bar
      double h1_c1 = iClose(m_symbol, PERIOD_H1, h1Shift);
      double h1_o1 = iOpen(m_symbol, PERIOD_H1, h1Shift);
      features[50] = (float)MathLog(h1_c1 / MathMax(h1_o1, EPS));       // 50: h1_ret_1

      double h1AtrBuf[], h1Ema20Buf[];
      ArraySetAsSeries(h1AtrBuf, true); ArraySetAsSeries(h1Ema20Buf, true);
      CopyBuffer(m_atrH1Handle, 0, h1Shift, 1, h1AtrBuf);
      CopyBuffer(m_ema20H1Handle, 0, h1Shift, 5, h1Ema20Buf);
      double h1_atr = (ArraySize(h1AtrBuf) > 0 && h1AtrBuf[0] > 0) ? h1AtrBuf[0] : (atr * 3.0);
      double h1_ema20_1 = (ArraySize(h1Ema20Buf) > 0) ? h1Ema20Buf[0] : h1_c1;
      double h1_ema20_4 = (ArraySize(h1Ema20Buf) > 3) ? h1Ema20Buf[3] : h1_ema20_1;

      features[51] = (float)((h1_c1 - h1_ema20_1) / (h1_atr + EPS));   // 51: h1_zclose_20
      features[52] = (float)((h1_ema20_1 - h1_ema20_4) / (h1_atr + EPS)); // 52: h1_ema20_slope
      features[53] = (float)((c0 - h1_ema20_1) / (h1_atr + EPS));      // 53: h1_dist_ema20

      int h4Shift = shift / 48 + 1; // Completed H4 bar
      double h4_c1 = iClose(m_symbol, PERIOD_H4, h4Shift);
      double h4_c2 = iClose(m_symbol, PERIOD_H4, h4Shift + 1);
      features[54] = (float)((h4_c1 - h4_c2) / (h1_atr * 3.0 + EPS));  // 54: h4_ret_1

      double h4AtrBuf[], h4Ema20Buf[];
      ArraySetAsSeries(h4AtrBuf, true); ArraySetAsSeries(h4Ema20Buf, true);
      CopyBuffer(m_atrH4Handle, 0, h4Shift, 1, h4AtrBuf);
      CopyBuffer(m_ema20H4Handle, 0, h4Shift, 5, h4Ema20Buf);
      double h4_ema20_1 = (ArraySize(h4Ema20Buf) > 0) ? h4Ema20Buf[0] : h4_c1;
      double h4_ema20_4 = (ArraySize(h4Ema20Buf) > 3) ? h4Ema20Buf[3] : h4_ema20_1;

      features[55] = (float)((h4_c1 - h4_ema20_1) / (h1_atr * 3.0 + EPS)); // 55: h4_zclose_20
      features[56] = (float)((h4_ema20_1 - h4_ema20_4) / (h1_atr * 3.0 + EPS)); // 56: h4_ema20_slope
      features[57] = (float)((c0 - h4_ema20_1) / (h1_atr * 3.0 + EPS));    // 57: h4_dist_ema20

      int d1Shift = shift / 288 + 1; // Completed D1 bar
      double d1_c1 = iClose(m_symbol, PERIOD_D1, d1Shift);
      double d1_c2 = iClose(m_symbol, PERIOD_D1, d1Shift + 1);
      features[58] = (float)((d1_c1 - d1_c2) / (h1_atr * 6.0 + EPS));  // 58: d1_ret_1

      double d1Ema20Buf[];
      ArraySetAsSeries(d1Ema20Buf, true);
      CopyBuffer(m_ema20D1Handle, 0, d1Shift, 5, d1Ema20Buf);
      double d1_ema20_1 = (ArraySize(d1Ema20Buf) > 0) ? d1Ema20Buf[0] : d1_c1;
      double d1_ema20_4 = (ArraySize(d1Ema20Buf) > 3) ? d1Ema20Buf[3] : d1_ema20_1;

      features[59] = (float)((d1_c1 - d1_ema20_1) / (h1_atr * 6.0 + EPS)); // 59: d1_zclose_20
      features[60] = (float)((d1_ema20_1 - d1_ema20_4) / (h1_atr * 6.0 + EPS)); // 60: d1_ema20_slope
      
      double d1AtrBuf[];
      ArraySetAsSeries(d1AtrBuf, true);
      CopyBuffer(m_atrD1Handle, 0, d1Shift, 1, d1AtrBuf);
      double d1_atr = (ArraySize(d1AtrBuf) > 0 && d1AtrBuf[0] > 0) ? d1AtrBuf[0] : (atr * 12.0);
      features[61] = (float)(atr / (d1_atr + EPS));                     // 61: d1_atr_relative

      // ---------------------------------------------------------------
      // Group H: Session Dynamics, Climax Streaks & Regimes (14 Features: 62 to 75)
      // ---------------------------------------------------------------
      double hour_val = dt0.hour + dt0.min / 60.0;
      features[62] = (float)MathSin(2.0 * M_PI * hour_val / 24.0);     // 62: hour_sin
      features[63] = (float)MathCos(2.0 * M_PI * hour_val / 24.0);     // 63: hour_cos
      features[64] = (float)((dt0.hour >= 13 && dt0.hour < 17) ? 1.0f : 0.0f); // 64: session_london_ny_overlap
      features[65] = (float)(((dt0.hour == 21 && dt0.min >= 45) || (dt0.hour == 22 && dt0.min <= 30)) ? 1.0f : 0.0f); // 65: session_rollover_window

      // Volume surge
      double sum_tod_v = 0.0; int cnt_tod = 0;
      for(int d = 1; d <= 20; d++)
      {
         int off = d * 288;
         if(shift + off < iBars(m_symbol, m_tf))
         {
            sum_tod_v += (double)iVolume(m_symbol, m_tf, shift + off);
            cnt_tod++;
         }
      }
      double mean_tod_v = cnt_tod > 0 ? (sum_tod_v / cnt_tod) : v0;
      features[66] = (float)(v0 / (mean_tod_v + EPS));                 // 66: rel_volume_surge

      // Consecutive streak
      int streak_cnt = 0;
      bool is_red = (rates[0].close < rates[0].open);
      bool is_grn = (rates[0].close > rates[0].open);
      for(int k = 0; k < 15; k++)
      {
         if(is_red && (rates[k].close < rates[k].open)) streak_cnt--;
         else if(is_grn && (rates[k].close > rates[k].open)) streak_cnt++;
         else break;
      }
      features[67] = (float)(streak_cnt / 5.0);                        // 67: consecutive_streak_intensity
      features[68] = (float)(MathMax(0.0, rates[3].close - c0) / (atr + EPS)); // 68: dump_velocity_3
      features[69] = (float)(MathMax(0.0, c0 - rates[3].close) / (atr + EPS)); // 69: pump_velocity_3
      features[70] = (float)(features[66] * features[8]);              // 70: stopping_vol_bull
      features[71] = (float)(features[66] * features[7]);              // 71: stopping_vol_bear

      // Hurst exponent proxy (50 bars)
      double rets50[50], m50 = 0.0;
      for(int k = 0; k < 50; k++) { rets50[k] = MathLog(rates[k].close / MathMax(rates[k+1].close, EPS)); m50 += rets50[k]; }
      m50 /= 50.0;
      double cum_dev = 0.0, min_cum = 0.0, max_cum = 0.0, varHurst50 = 0.0;
      for(int k = 0; k < 50; k++)
      {
         double dev = rets50[k] - m50;
         cum_dev += dev;
         min_cum = MathMin(min_cum, cum_dev);
         max_cum = MathMax(max_cum, cum_dev);
         varHurst50 += dev * dev;
      }
      double R = max_cum - min_cum;
      double S = MathSqrt(varHurst50 / 50.0) + EPS;
      double hurst = (R > 0 && S > 0) ? (MathLog(R / S) / MathLog(50.0)) : 0.5;
      features[72] = (float)hurst;                                     // 72: rolling_hurst_exponent

      // ADX 14
      double adxBuf[];
      ArraySetAsSeries(adxBuf, true);
      CopyBuffer(m_adxHandle, 0, shift, 1, adxBuf);
      double adx_val = (ArraySize(adxBuf) > 0) ? adxBuf[0] : 25.0;
      features[73] = (float)(adx_val / 50.0);                          // 73: adx_14_regime

      // Choppiness index 14
      double sum_tr14 = 0.0, hh14 = rates[0].high, ll14 = rates[0].low;
      for(int k = 0; k < 14; k++)
      {
         sum_tr14 += MathMax(rates[k].high - rates[k].low, MathMax(MathAbs(rates[k].high - rates[k+1].close), MathAbs(rates[k].low - rates[k+1].close)));
         hh14 = MathMax(hh14, rates[k].high);
         ll14 = MathMin(ll14, rates[k].low);
      }
      double chop = 100.0 * MathLog10(sum_tr14 / (hh14 - ll14 + EPS) + EPS) / MathLog10(14.0);
      features[74] = (float)((MathMin(MathMax(chop, 0.0), 100.0) - 50.0) / 50.0); // 74: choppiness_index

      features[75] = (float)(hl_range0 / (atr + EPS));                 // 75: range_compression_ratio

      // Numerical Safety & Outlier Clamping [-5.0, +5.0]
      for(int f = 0; f < FEAT_COUNT; f++)
      {
         if(!MathIsValidNumber(features[f]))
            features[f] = 0.0f;
         else
            features[f] = (float)MathMin(MathMax(features[f], -5.0f), 5.0f);
      }

      return true;
   }

   bool ExtractLatestFeatures(float &features[])
   {
      return ExtractFeaturesAtBar(1, features);
   }
};
