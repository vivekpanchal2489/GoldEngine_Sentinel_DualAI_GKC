//+------------------------------------------------------------------+
//| GE_AIIntegration.mqh                                             |
//| Dual-AI Consensus Engine: SuperGRU 76 + Master AI 76             |
//| Microstructure & Order Flow + Nadaraya-Watson Boundary Synergy    |
//+------------------------------------------------------------------+
#ifndef GE_AIINTEGRATION_MQH
#define GE_AIINTEGRATION_MQH

#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_EntryGates.mqh>
#include <GE_NadarayaWatson.mqh>
#include <GRUStats76.mqh>
#include <GoldAI_Features.mqh>
#include <GoldAI_ONNXEngine.mqh>

//+------------------------------------------------------------------+
//| Strategy Enable / Disable Inputs                                 |
//+------------------------------------------------------------------+
input group "=== Super-Algo Strategy Synergy (Tri-Layer Consensus) ==="
input bool   InpUseSuperTrendConsensus   = true;   // Setup A: SuperGRU + Master AI Concurrence + Order Flow
input bool   InpUseTurtleSoupSweep       = true;   // Setup B: ICT Liquidity Sweep Reversal (Feature #13 + NWE Band)
input bool   InpUseNweReversalSniper     = false;  // Setup C: NWE Boundary Sniper (Default OFF - NWE is Guard Only)
input bool   InpUseSuperGruCoreTrend     = true;   // Setup D: SuperGRU 8-Hour Temporal Trend Engine

input group "=== Model Paths (relative to MQL5/Files) ==="
input string InpGruModelPath             = "gru_model_ultimate.onnx"; // AI Brain 1: 96x76 GRU Sequence
input string InpGoldMasterModelPath      = "gold_master_ai.onnx";     // AI Brain 2: 76 Microstructure & Order Flow
input bool   InpUseSyntheticDxy          = true;                      // Synthetic DXY from ICE basket

//+------------------------------------------------------------------+
//| SuperGRU 76 Sequence Engine (AI Brain 1)                         |
//+------------------------------------------------------------------+
#define GRU_SEQ_LEN        96
#define GRU_MAX_FEATURES   76
#define GRU_M5_WARMUP      7000
#define GRU_DXY_WARMUP     3000
#define GRU_H1_WARMUP      1200
#define GRU_H4_WARMUP      600
#define GRU_D1_WARMUP      400
#define GRU_WIN_SLOPE      5
#define GRU_CORR_WINDOW    48

void GRU_RollMean(const double &x[], int n, int w, double &out[])
{
   double sum = 0.0;
   for(int i = 0; i < n; i++)
   {
      sum += x[i];
      if(i >= w) sum -= x[i - w];
      out[i] = (i >= w - 1) ? sum / w : 0.0;
   }
}

void GRU_RollStd(const double &x[], int n, int w, double &out[])
{
   double sum = 0.0, sq = 0.0;
   for(int i = 0; i < n; i++)
   {
      sum += x[i]; sq += x[i] * x[i];
      if(i >= w) { sum -= x[i - w]; sq -= x[i - w] * x[i - w]; }
      if(i >= w - 1)
      {
         double m1 = sum / w, m2 = sq / w;
         out[i] = MathSqrt(MathMax(m2 - m1 * m1, 0.0));
      }
      else out[i] = 0.0;
   }
}

void GRU_Zscore(const double &x[], int n, int w, double &out[])
{
   double mean[], sd[];
   ArrayResize(mean, n);
   ArrayResize(sd, n);
   GRU_RollMean(x, n, w, mean);
   GRU_RollStd(x, n, w, sd);
   for(int i = 0; i < n; i++)
      out[i] = (sd[i] > 0.0) ? (x[i] - mean[i]) / sd[i] : 0.0;
}

void GRU_EMA(const double &x[], int n, int span, double &out[])
{
   double alpha = 2.0 / (span + 1.0);
   out[0] = x[0];
   for(int i = 1; i < n; i++)
      out[i] = out[i - 1] + alpha * (x[i] - out[i - 1]);
}

void GRU_Slope(const double &x[], int n, double &out[])
{
   int w = GRU_WIN_SLOPE;
   double denom = w * (w * w - 1.0) / 12.0;
   double sx = 0.0, sy = 0.0, sxy = 0.0;
   for(int i = 0; i < n; i++)
   {
      sx += i; sy += x[i]; sxy += x[i] * i;
      if(i >= w)
      {
         sx -= (i - w); sy -= x[i - w]; sxy -= x[i - w] * (i - w);
      }
      if(i >= w - 1)
         out[i] = (sxy - sy * sx / w) / denom;
      else out[i] = 0.0;
   }
}

void GRU_RSI(const double &x[], int n, int period, double &out[])
{
   double alpha = 2.0 / (period + 1.0);
   double ag = 0.0, al = 0.0;
   bool started = false;
   for(int i = 0; i < n; i++)
   {
      if(i == 0) { out[i] = 0.0; continue; }
      double d = x[i] - x[i - 1];
      double g = MathMax(d, 0.0), l = MathMax(-d, 0.0);
      if(!started) { ag = g; al = l; started = true; }
      else { ag += alpha * (g - ag); al += alpha * (l - al); }
      if(al > 0.0) out[i] = 100.0 - 100.0 / (1.0 + ag / al);
      else         out[i] = (ag > 0.0) ? 100.0 : 0.0;
   }
}

void GRU_TR(const double &h[], const double &l[], const double &c[], int n, double &tr[])
{
   tr[0] = h[0] - l[0];
   for(int i = 1; i < n; i++)
   {
      double a = h[i] - l[i];
      double b = MathAbs(h[i] - c[i - 1]);
      double d = MathAbs(l[i] - c[i - 1]);
      tr[i] = MathMax(a, MathMax(b, d));
   }
}

class CGRUFilter76
{
private:
   long     m_onnxHandle;
   bool     m_initialized;
   float    m_inputData[GRU_SEQ_LEN * GRU_MAX_FEATURES];
   float    m_outputData[3];
   string   m_dxyPairs[6];
   double   m_lastAtrNorm;

   void ResolveBasketPairs()
   {
      string base[6] = {"EURUSD", "USDJPY", "GBPUSD", "USDCAD", "USDSEK", "USDCHF"};
      for(int i = 0; i < 6; i++)
      {
         m_dxyPairs[i] = base[i];
         if(SymbolSelect(base[i], true)) continue;
         string lower = base[i]; StringToLower(lower);
         if(SymbolSelect(lower, true)) { m_dxyPairs[i] = lower; continue; }
         int total = SymbolsTotal(false);
         for(int s = 0; s < total; s++)
         {
            string name = SymbolName(s, false);
            string upper = name; StringToUpper(upper);
            if(StringFind(upper, base[i]) >= 0)
            {
               SymbolSelect(name, true);
               m_dxyPairs[i] = name;
               break;
            }
         }
      }
   }

   void Std(float &f[])
   {
      for(int k = 0; k < GRU_MAX_FEATURES; k++)
      {
         double s = GRU76_XSD[k];
         f[k] = (float)((f[k] - GRU76_XM[k]) / (s > 1e-12 ? s : 1.0));
         f[k] = (float)MathMin(MathMax(f[k], -5.0f), 5.0f);
      }
   }

   bool BuildSyntheticDxy(MqlRates &dx[])
   {
      MqlRates b0[], b1[], b2[], b3[], b4[], b5[];
      int nArr[6];
      int minN = INT_MAX;
      nArr[0] = CopyRates(m_dxyPairs[0], PERIOD_M5, 0, GRU_DXY_WARMUP, b0);
      nArr[1] = CopyRates(m_dxyPairs[1], PERIOD_M5, 0, GRU_DXY_WARMUP, b1);
      nArr[2] = CopyRates(m_dxyPairs[2], PERIOD_M5, 0, GRU_DXY_WARMUP, b2);
      nArr[3] = CopyRates(m_dxyPairs[3], PERIOD_M5, 0, GRU_DXY_WARMUP, b3);
      nArr[4] = CopyRates(m_dxyPairs[4], PERIOD_M5, 0, GRU_DXY_WARMUP, b4);
      nArr[5] = CopyRates(m_dxyPairs[5], PERIOD_M5, 0, GRU_DXY_WARMUP, b5);
      for(int p = 0; p < 6; p++)
      {
         if(nArr[p] < GRU_SEQ_LEN + GRU_CORR_WINDOW + 100) return false;
         if(nArr[p] < minN) minN = nArr[p];
      }
      ArraySetAsSeries(b0, false); ArraySetAsSeries(b1, false); ArraySetAsSeries(b2, false);
      ArraySetAsSeries(b3, false); ArraySetAsSeries(b4, false); ArraySetAsSeries(b5, false);

      int mD = minN;
      ArrayResize(dx, mD);
      int j0 = 0, j1 = 0, j2 = 0, j3 = 0, j4 = 0, j5 = 0;
      for(int i = 0; i < mD; i++)
      {
         datetime T = b0[i].time;
         while(j0 + 1 < nArr[0] && b0[j0 + 1].time <= T) j0++;
         while(j1 + 1 < nArr[1] && b1[j1 + 1].time <= T) j1++;
         while(j2 + 1 < nArr[2] && b2[j2 + 1].time <= T) j2++;
         while(j3 + 1 < nArr[3] && b3[j3 + 1].time <= T) j3++;
         while(j4 + 1 < nArr[4] && b4[j4 + 1].time <= T) j4++;
         while(j5 + 1 < nArr[5] && b5[j5 + 1].time <= T) j5++;

         double o[6], h[6], l[6], c[6];
         o[0]=b0[j0].open;  h[0]=b0[j0].high;  l[0]=b0[j0].low;  c[0]=b0[j0].close;
         o[1]=b1[j1].open;  h[1]=b1[j1].high;  l[1]=b1[j1].low;  c[1]=b1[j1].close;
         o[2]=b2[j2].open;  h[2]=b2[j2].high;  l[2]=b2[j2].low;  c[2]=b2[j2].close;
         o[3]=b3[j3].open;  h[3]=b3[j3].high;  l[3]=b3[j3].low;  c[3]=b3[j3].close;
         o[4]=b4[j4].open;  h[4]=b4[j4].high;  l[4]=b4[j4].low;  c[4]=b4[j4].close;
         o[5]=b5[j5].open;  h[5]=b5[j5].high;  l[5]=b5[j5].low;  c[5]=b5[j5].close;

         dx[i].time   = T;
         dx[i].open   = 50.14348112 * MathPow(o[0], -0.576) * MathPow(o[1], 0.136) * MathPow(o[2], -0.119) * MathPow(o[3], 0.091) * MathPow(o[4], 0.042) * MathPow(o[5], 0.036);
         dx[i].high   = 50.14348112 * MathPow(h[0], -0.576) * MathPow(h[1], 0.136) * MathPow(h[2], -0.119) * MathPow(h[3], 0.091) * MathPow(h[4], 0.042) * MathPow(h[5], 0.036);
         dx[i].low    = 50.14348112 * MathPow(l[0], -0.576) * MathPow(l[1], 0.136) * MathPow(l[2], -0.119) * MathPow(l[3], 0.091) * MathPow(l[4], 0.042) * MathPow(l[5], 0.036);
         dx[i].close  = 50.14348112 * MathPow(c[0], -0.576) * MathPow(c[1], 0.136) * MathPow(c[2], -0.119) * MathPow(c[3], 0.091) * MathPow(c[4], 0.042) * MathPow(c[5], 0.036);
      }
      return true;
   }

   bool BuildWindow()
   {
      string sym = _Symbol;
      MqlRates m5[];
      int got = CopyRates(sym, PERIOD_M5, 1, GRU_M5_WARMUP, m5);
      if(got < GRU_SEQ_LEN + 250) return false;
      ArraySetAsSeries(m5, true);

      int N = got;
      double o[], h[], l[], c[], v[];
      datetime t[];
      ArrayResize(o, N); ArrayResize(h, N); ArrayResize(l, N);
      ArrayResize(c, N); ArrayResize(v, N); ArrayResize(t, N);
      for(int i = 0; i < N; i++)
      {
         int s = N - 1 - i;
         o[i] = m5[s].open;  h[i] = m5[s].high;  l[i] = m5[s].low;
         c[i] = m5[s].close; v[i] = (double)m5[s].tick_volume;
         t[i] = m5[s].time;
      }

      MqlRates h1[];
      int n1 = CopyRates(sym, PERIOD_H1, 1, GRU_H1_WARMUP, h1);
      if(n1 < 120) return false;
      ArraySetAsSeries(h1, true);
      double hh1[], ll1[], cc1[]; datetime t1[];
      ArrayResize(hh1, n1); ArrayResize(ll1, n1); ArrayResize(cc1, n1); ArrayResize(t1, n1);
      for(int i = 0; i < n1; i++)
      {
         int s = n1 - 1 - i;
         hh1[i] = h1[s].high; ll1[i] = h1[s].low; cc1[i] = h1[s].close; t1[i] = h1[s].time;
      }

      MqlRates h4[];
      int n4 = CopyRates(sym, PERIOD_H4, 1, GRU_H4_WARMUP, h4);
      if(n4 < 80) return false;
      ArraySetAsSeries(h4, true);
      double hh4[], ll4[], cc4[]; datetime t4[];
      ArrayResize(hh4, n4); ArrayResize(ll4, n4); ArrayResize(cc4, n4); ArrayResize(t4, n4);
      for(int i = 0; i < n4; i++)
      {
         int s = n4 - 1 - i;
         hh4[i] = h4[s].high; ll4[i] = h4[s].low; cc4[i] = h4[s].close; t4[i] = h4[s].time;
      }

      MqlRates d1[];
      int n2 = CopyRates(sym, PERIOD_D1, 1, GRU_D1_WARMUP, d1);
      if(n2 < 50) return false;
      ArraySetAsSeries(d1, true);
      double hh2[], ll2[], cc2[]; datetime t2[];
      ArrayResize(hh2, n2); ArrayResize(ll2, n2); ArrayResize(cc2, n2); ArrayResize(t2, n2);
      for(int i = 0; i < n2; i++)
      {
         int s = n2 - 1 - i;
         hh2[i] = d1[s].high; ll2[i] = d1[s].low; cc2[i] = d1[s].close; t2[i] = d1[s].time;
      }

      double aRet1[], aRet5[], aRet12[], aRet24[], aRet48[], aMom6[];
      double aZc20[], aZc50[], aZc100[], aZh20[], aZh50[], aZh100[];
      double aZl20[], aZl50[], aZl100[];
      double aAtrRatio[], aAtrNorm[];
      double aRsi[], aRsiSlope[];
      double aMacdHist[], aMacdSlope[];
      double aDistVwap[], aDistEma20[], aDistEma50[], aDistEma200[];
      double aEma20Slope[], aEma50Slope[];
      double aBody[], aUp[], aLo[], aVolRatio[];
      ArrayResize(aRet1, N); ArrayResize(aRet5, N); ArrayResize(aRet12, N);
      ArrayResize(aRet24, N); ArrayResize(aRet48, N); ArrayResize(aMom6, N);
      ArrayResize(aZc20, N); ArrayResize(aZc50, N); ArrayResize(aZc100, N);
      ArrayResize(aZh20, N); ArrayResize(aZh50, N); ArrayResize(aZh100, N);
      ArrayResize(aZl20, N); ArrayResize(aZl50, N); ArrayResize(aZl100, N);
      ArrayResize(aAtrRatio, N); ArrayResize(aAtrNorm, N);
      ArrayResize(aRsi, N); ArrayResize(aRsiSlope, N);
      ArrayResize(aMacdHist, N); ArrayResize(aMacdSlope, N);
      ArrayResize(aDistVwap, N); ArrayResize(aDistEma20, N);
      ArrayResize(aDistEma50, N); ArrayResize(aDistEma200, N);
      ArrayResize(aEma20Slope, N); ArrayResize(aEma50Slope, N);
      ArrayResize(aBody, N); ArrayResize(aUp, N); ArrayResize(aLo, N); ArrayResize(aVolRatio, N);

      double ema20[], ema50[], ema200[], macd[];
      ArrayResize(ema20, N); ArrayResize(ema50, N); ArrayResize(ema200, N); ArrayResize(macd, N);

      double tr[]; ArrayResize(tr, N);
      GRU_TR(h, l, c, N, tr);
      double atr14[], atr100[]; ArrayResize(atr14, N); ArrayResize(atr100, N);
      GRU_RollMean(tr, N, 14, atr14);
      GRU_RollMean(tr, N, 100, atr100);

      GRU_EMA(c, N, 12, macd);
      double ema26[]; ArrayResize(ema26, N);
      GRU_EMA(c, N, 26, ema26);
      for(int i = 0; i < N; i++) macd[i] -= ema26[i];

      GRU_EMA(c, N, 20, ema20);
      GRU_EMA(c, N, 50, ema50);
      GRU_EMA(c, N, 200, ema200);

      double vw[]; ArrayResize(vw, N);
      {
         double sTv = 0.0, sV = 0.0;
         for(int i = 0; i < N; i++)
         {
            double tp = (h[i] + l[i] + c[i]) / 3.0;
            sTv += tp * v[i]; sV += v[i];
            if(i >= 20) { int j = i - 20; double tpj = (h[j] + l[j] + c[j]) / 3.0; sTv -= tpj * v[j]; sV -= v[j]; }
            vw[i] = (i >= 19 && sV > 0.0) ? sTv / sV : c[i];
         }
      }
      double vMean[]; ArrayResize(vMean, N);
      GRU_RollMean(v, N, 20, vMean);

      double eps = 1e-12;
      for(int i = 0; i < N; i++)
      {
         aRet1[i]   = (i >= 1)  ? MathLog(c[i] / MathMax(c[i - 1], eps))  : 0.0;
         aRet5[i]   = (i >= 5)  ? MathLog(c[i] / MathMax(c[i - 5], eps))  : 0.0;
         aRet12[i]  = (i >= 12) ? MathLog(c[i] / MathMax(c[i - 12], eps)) : 0.0;
         aRet24[i]  = (i >= 24) ? MathLog(c[i] / MathMax(c[i - 24], eps)) : 0.0;
         aRet48[i]  = (i >= 48) ? MathLog(c[i] / MathMax(c[i - 48], eps)) : 0.0;
         aMom6[i]   = (i >= 6)  ? MathLog(c[i] / MathMax(c[i - 6], eps))  : 0.0;
         aAtrRatio[i] = (atr100[i] > 0.0) ? atr14[i] / atr100[i] : 0.0;
         aAtrNorm[i]  = atr14[i] / MathMax(c[i], eps);
         aMacdHist[i] = macd[i] / MathMax(c[i], eps);
         aDistVwap[i] = MathLog(c[i] / MathMax(vw[i], eps));
         aDistEma20[i]  = MathLog(c[i] / MathMax(ema20[i], eps));
         aDistEma50[i]  = MathLog(c[i] / MathMax(ema50[i], eps));
         aDistEma200[i] = MathLog(c[i] / MathMax(ema200[i], eps));
         double rng = MathMax(h[i] - l[i], eps);
         aBody[i] = (c[i] - o[i]) / rng;
         aUp[i] = (h[i] - MathMax(o[i], c[i])) / rng;
         aLo[i] = (MathMin(o[i], c[i]) - l[i]) / rng;
         aVolRatio[i] = (vMean[i] > 0.0) ? v[i] / vMean[i] : 1.0;
      }
      GRU_Zscore(c, N, 20, aZc20);  GRU_Zscore(c, N, 50, aZc50);  GRU_Zscore(c, N, 100, aZc100);
      GRU_Zscore(h, N, 20, aZh20);  GRU_Zscore(h, N, 50, aZh50);  GRU_Zscore(h, N, 100, aZh100);
      GRU_Zscore(l, N, 20, aZl20);  GRU_Zscore(l, N, 50, aZl50);  GRU_Zscore(l, N, 100, aZl100);
      GRU_RSI(c, N, 14, aRsi);
      GRU_Slope(aRsi, N, aRsiSlope);
      GRU_Slope(macd, N, aMacdSlope);
      GRU_Slope(ema20, N, aEma20Slope);
      GRU_Slope(ema50, N, aEma50Slope);

      double h1_ret1[], h1_ret4[], h1_zc20[], h1_zc50[], h1_atrR[], h1_rsi[], h1_de20[], h1_eslope[];
      double h1_de200[], h1_e200slope[];
      ArrayResize(h1_ret1, n1); ArrayResize(h1_ret4, n1); ArrayResize(h1_zc20, n1);
      ArrayResize(h1_zc50, n1); ArrayResize(h1_atrR, n1); ArrayResize(h1_rsi, n1);
      ArrayResize(h1_de20, n1); ArrayResize(h1_eslope, n1);
      ArrayResize(h1_de200, n1); ArrayResize(h1_e200slope, n1);
      {
         double tr1[]; ArrayResize(tr1, n1);
         double a14[], a100[], e20[], e200[];
         ArrayResize(a14, n1); ArrayResize(a100, n1); ArrayResize(e20, n1); ArrayResize(e200, n1);
         GRU_TR(hh1, ll1, cc1, n1, tr1);
         GRU_RollMean(tr1, n1, 14, a14);
         GRU_RollMean(tr1, n1, 100, a100);
         GRU_EMA(cc1, n1, 20, e20);
         GRU_EMA(cc1, n1, 200, e200);
         GRU_RSI(cc1, n1, 14, h1_rsi);
         GRU_Zscore(cc1, n1, 20, h1_zc20);
         GRU_Zscore(cc1, n1, 50, h1_zc50);
         GRU_Slope(e20, n1, h1_eslope);
         GRU_Slope(e200, n1, h1_e200slope);
         for(int i = 0; i < n1; i++)
         {
            h1_ret1[i] = (i >= 1) ? MathLog(cc1[i] / MathMax(cc1[i - 1], 1e-12)) : 0.0;
            h1_ret4[i] = (i >= 4) ? MathLog(cc1[i] / MathMax(cc1[i - 4], 1e-12)) : 0.0;
            h1_atrR[i] = (a100[i] > 0.0) ? a14[i] / a100[i] : 0.0;
            h1_de20[i] = MathLog(cc1[i] / MathMax(e20[i], 1e-12));
            h1_de200[i] = MathLog(cc1[i] / MathMax(e200[i], 1e-12));
         }
      }

      double h4_ret1[], h4_ret4[], h4_zc20[], h4_de20[], h4_eslope[], h4_atrN[];
      double h4_de200[], h4_e200slope[];
      ArrayResize(h4_ret1, n4); ArrayResize(h4_ret4, n4); ArrayResize(h4_zc20, n4);
      ArrayResize(h4_de20, n4); ArrayResize(h4_eslope, n4); ArrayResize(h4_atrN, n4);
      ArrayResize(h4_de200, n4); ArrayResize(h4_e200slope, n4);
      {
         double tr4[]; ArrayResize(tr4, n4);
         double a14[], e20[], e200[];
         ArrayResize(a14, n4); ArrayResize(e20, n4); ArrayResize(e200, n4);
         GRU_TR(hh4, ll4, cc4, n4, tr4);
         GRU_RollMean(tr4, n4, 14, a14);
         GRU_EMA(cc4, n4, 20, e20);
         GRU_EMA(cc4, n4, 200, e200);
         GRU_Zscore(cc4, n4, 20, h4_zc20);
         GRU_Slope(e20, n4, h4_eslope);
         GRU_Slope(e200, n4, h4_e200slope);
         for(int i = 0; i < n4; i++)
         {
            h4_ret1[i] = (i >= 1) ? MathLog(cc4[i] / MathMax(cc4[i - 1], 1e-12)) : 0.0;
            h4_ret4[i] = (i >= 4) ? MathLog(cc4[i] / MathMax(cc4[i - 4], 1e-12)) : 0.0;
            h4_atrN[i] = a14[i] / MathMax(cc4[i], 1e-12);
            h4_de20[i] = MathLog(cc4[i] / MathMax(e20[i], 1e-12));
            h4_de200[i] = MathLog(cc4[i] / MathMax(e200[i], 1e-12));
         }
      }

      double d1_ret1[], d1_ret5[], d1_zc20[], d1_de20[], d1_atrN[];
      ArrayResize(d1_ret1, n2); ArrayResize(d1_ret5, n2); ArrayResize(d1_zc20, n2);
      ArrayResize(d1_de20, n2); ArrayResize(d1_atrN, n2);
      {
         double tr2[]; ArrayResize(tr2, n2);
         double a14[], e20[];
         ArrayResize(a14, n2); ArrayResize(e20, n2);
         GRU_TR(hh2, ll2, cc2, n2, tr2);
         GRU_RollMean(tr2, n2, 14, a14);
         GRU_EMA(cc2, n2, 20, e20);
         GRU_Zscore(cc2, n2, 20, d1_zc20);
         for(int i = 0; i < n2; i++)
         {
            d1_ret1[i] = (i >= 1) ? MathLog(cc2[i] / MathMax(cc2[i - 1], 1e-12)) : 0.0;
            d1_ret5[i] = (i >= 5) ? MathLog(cc2[i] / MathMax(cc2[i - 5], 1e-12)) : 0.0;
            d1_atrN[i] = a14[i] / MathMax(cc2[i], 1e-12);
            d1_de20[i] = MathLog(cc2[i] / MathMax(e20[i], 1e-12));
         }
      }

      double aObBull[], aObBear[], aFvgBull[], aFvgBear[], aMss[];
      ArrayResize(aObBull, N); ArrayResize(aObBear, N);
      ArrayResize(aFvgBull, N); ArrayResize(aFvgBear, N); ArrayResize(aMss, N);
      for(int i = 0; i < N; i++)
      {
         double atri = MathMax(atr14[i], eps);
         double obB = 0.0, obS = 0.0;
         if(i >= 2)
         {
            if(c[i] > h[i - 1] && c[i - 1] < o[i - 1]) obB = (h[i - 1] - l[i - 1]) / atri;
            if(c[i] < l[i - 1] && c[i - 1] > o[i - 1]) obS = (h[i - 1] - l[i - 1]) / atri;
         }
         aObBull[i] = MathMin(obB, 5.0);
         aObBear[i] = MathMin(obS, 5.0);
         double fvgB = (i >= 2 && l[i] > h[i - 2]) ? (l[i] - h[i - 2]) / atri : 0.0;
         double fvgS = (i >= 2 && h[i] < l[i - 2]) ? (l[i - 2] - h[i]) / atri : 0.0;
         aFvgBull[i] = MathMin(fvgB, 5.0);
         aFvgBear[i] = MathMin(fvgS, 5.0);
         double mss = 0.0;
         if(i >= 20)
         {
            double hh = h[i - 1], ll = l[i - 1];
            for(int k = i - 20; k < i; k++) { if(h[k] > hh) hh = h[k]; if(l[k] < ll) ll = l[k]; }
            if(c[i] > hh) mss = 1.0;
            else if(c[i] < ll) mss = -1.0;
         }
         aMss[i] = mss;
      }

      double aRelSessVol[]; ArrayResize(aRelSessVol, N);
      for(int i = 0; i < N; i++)
      {
         double sV = 0.0; int cV = 0;
         for(int d = 1; d <= 20; d++)
         {
            int idx = i - d * 288;
            if(idx >= 0) { sV += v[idx]; cV++; }
         }
         double meanV = (cV > 0) ? sV / cV : v[i];
         aRelSessVol[i] = (meanV > 0.0) ? v[i] / meanV : 1.0;
      }

      MqlRates dxy[];
      bool hasDxy = InpUseSyntheticDxy && BuildSyntheticDxy(dxy);
      int mD = hasDxy ? ArraySize(dxy) : 0;
      double dc_[], dxyRet1[], dxyRet5[], dxyRet12[], dxyRet24[], dxyZc20[], dxyZc50[], dxyAtrN[];
      datetime dt_[];
      ArrayResize(dc_, mD); ArrayResize(dxyRet1, mD); ArrayResize(dxyRet5, mD);
      ArrayResize(dxyRet12, mD); ArrayResize(dxyRet24, mD); ArrayResize(dxyZc20, mD);
      ArrayResize(dxyZc50, mD); ArrayResize(dxyAtrN, mD); ArrayResize(dt_, mD);
      if(hasDxy)
      {
         double trD[]; ArrayResize(trD, mD);
         double hD[], lD[]; ArrayResize(hD, mD); ArrayResize(lD, mD);
         for(int i = 0; i < mD; i++) { dc_[i] = dxy[i].close; hD[i] = dxy[i].high; lD[i] = dxy[i].low; dt_[i] = dxy[i].time; }
         GRU_TR(hD, lD, dc_, mD, trD);
         double aD14[]; ArrayResize(aD14, mD);
         GRU_RollMean(trD, mD, 14, aD14);
         GRU_Zscore(dc_, mD, 20, dxyZc20);
         GRU_Zscore(dc_, mD, 50, dxyZc50);
         for(int i = 0; i < mD; i++)
         {
            dxyRet1[i]  = (i >= 1)  ? MathLog(dc_[i] / MathMax(dc_[i - 1], eps))  : 0.0;
            dxyRet5[i]  = (i >= 5)  ? MathLog(dc_[i] / MathMax(dc_[i - 5], eps))  : 0.0;
            dxyRet12[i] = (i >= 12) ? MathLog(dc_[i] / MathMax(dc_[i - 12], eps)) : 0.0;
            dxyRet24[i] = (i >= 24) ? MathLog(dc_[i] / MathMax(dc_[i - 24], eps)) : 0.0;
            dxyAtrN[i]  = aD14[i] / MathMax(dc_[i], eps);
         }
      }

      double dCorr[]; ArrayResize(dCorr, N);
      if(hasDxy)
      {
         int jd = 0;
         for(int i = 0; i < N; i++)
         {
            datetime T = t[i];
            while(jd + 1 < mD && dt_[jd + 1] <= T) jd++;
            if(i >= GRU_CORR_WINDOW && jd >= GRU_CORR_WINDOW)
            {
               double sum = 0.0, sumG2 = 0.0, sumD2 = 0.0;
               for(int k = 0; k < GRU_CORR_WINDOW; k++)
               {
                  double gR = aRet1[i - k];
                  double dR = dxyRet1[jd - k];
                  sum += gR * dR; sumG2 += gR * gR; sumD2 += dR * dR;
               }
               double denom = MathSqrt(sumG2 * sumD2);
               dCorr[i] = (denom > 1e-12) ? sum / denom : 0.0;
            }
            else dCorr[i] = 0.0;
         }
      }
      else ArrayInitialize(dCorr, 0.0);

      int base = N - GRU_SEQ_LEN;
      int ih = 0, iq = 0, id = 0, jd = 0;
      for(int r = 0; r < GRU_SEQ_LEN; r++)
      {
         int i = base + r;
         datetime T = t[i];
         while(ih + 1 < n1 && t1[ih + 1] <= T) ih++;
         while(iq + 1 < n4 && t4[iq + 1] <= T) iq++;
         while(id + 1 < n2 && t2[id + 1] <= T) id++;
         while(jd + 1 < mD && dt_[jd + 1] <= T) jd++;

         MqlDateTime mdt;
         TimeToStruct(T, mdt);
         double hour = mdt.hour + mdt.min / 60.0;
         int dow = mdt.day_of_week;

         float f[GRU_MAX_FEATURES];
         f[0]  = (float)aRet1[i];    f[1]  = (float)aRet5[i];    f[2]  = (float)aRet12[i];
         f[3]  = (float)aRet24[i];   f[4]  = (float)aRet48[i];   f[5]  = (float)aMom6[i];
         f[6]  = (float)aZc20[i];    f[7]  = (float)aZh20[i];    f[8]  = (float)aZl20[i];
         f[9]  = (float)aZc50[i];    f[10] = (float)aZh50[i];    f[11] = (float)aZl50[i];
         f[12] = (float)aZc100[i];   f[13] = (float)aZh100[i];   f[14] = (float)aZl100[i];
         f[15] = (float)aAtrRatio[i];f[16] = (float)aAtrNorm[i];
         f[17] = (float)aRsi[i];     f[18] = (float)aRsiSlope[i];
         f[19] = (float)aMacdHist[i];f[20] = (float)aMacdSlope[i];
         f[21] = (float)aDistVwap[i];f[22] = (float)aDistEma20[i]; f[23] = (float)aDistEma50[i]; f[24] = (float)aDistEma200[i];
         f[25] = (float)aEma20Slope[i]; f[26] = (float)aEma50Slope[i];
         f[27] = (float)aBody[i];    f[28] = (float)aUp[i];      f[29] = (float)aLo[i];
         f[30] = (float)aVolRatio[i];

         f[31] = (float)aObBull[i];  f[32] = (float)aObBear[i];
         f[33] = (float)aFvgBull[i]; f[34] = (float)aFvgBear[i];
         f[35] = (float)aMss[i];

         f[36] = (float)h1_ret1[ih]; f[37] = (float)h1_ret4[ih];
         f[38] = (float)h1_zc20[ih]; f[39] = (float)h1_zc50[ih];
         f[40] = (float)h1_atrR[ih]; f[41] = (float)h1_rsi[ih];
         f[42] = (float)h1_de20[ih]; f[43] = (float)h1_eslope[ih];
         f[44] = (float)h1_de200[ih];f[45] = (float)h1_e200slope[ih];

         f[46] = (float)h4_ret1[iq]; f[47] = (float)h4_ret4[iq];
         f[48] = (float)h4_zc20[iq]; f[49] = (float)h4_de20[iq];
         f[50] = (float)h4_eslope[iq]; f[51] = (float)h4_de200[iq];
         f[52] = (float)h4_e200slope[iq]; f[53] = (float)h4_atrN[iq];

         f[54] = (float)d1_ret1[id]; f[55] = (float)d1_ret5[id];
         f[56] = (float)d1_zc20[id]; f[57] = (float)d1_de20[id]; f[58] = (float)d1_atrN[id];

         f[59] = (float)MathSin(2.0 * M_PI * hour / 24.0);
         f[60] = (float)MathCos(2.0 * M_PI * hour / 24.0);
         f[61] = (float)MathSin(2.0 * M_PI * dow / 7.0);
         f[62] = (float)MathCos(2.0 * M_PI * dow / 7.0);
         f[63] = (float)((hour >= 0 && hour < 8)   ? 1.0 : 0.0);
         f[64] = (float)((hour >= 8 && hour < 16)  ? 1.0 : 0.0);
         f[65] = (float)((hour >= 13 && hour < 22) ? 1.0 : 0.0);
         f[66] = (float)aRelSessVol[i];

         bool hasD = (jd < mD && dt_[jd] <= T);
         f[67] = hasD ? (float)dxyAtrN[jd]  : 0.0f;
         f[68] = hasD ? (float)dxyRet1[jd]  : 0.0f;
         f[69] = hasD ? (float)dxyRet5[jd]  : 0.0f;
         f[70] = hasD ? (float)dxyRet12[jd] : 0.0f;
         f[71] = hasD ? (float)dxyRet24[jd] : 0.0f;
         f[72] = hasD ? (float)dxyZc20[jd]  : 0.0f;
         f[73] = hasD ? (float)dxyZc50[jd]  : 0.0f;
         f[74] = (float)dCorr[i];
         f[75] = hasD ? 1.0f : 0.0f;

         Std(f);
         for(int k = 0; k < GRU_MAX_FEATURES; k++)
            m_inputData[r * GRU_MAX_FEATURES + k] = f[k];
      }

      m_lastAtrNorm = aAtrNorm[base + GRU_SEQ_LEN - 1];
      return true;
   }

public:
   CGRUFilter76() : m_onnxHandle(INVALID_HANDLE), m_initialized(false), m_lastAtrNorm(0.0)
   {
      ZeroMemory(m_inputData);
      ZeroMemory(m_outputData);
      ResolveBasketPairs();
   }

   ~CGRUFilter76() { Release(); }

   bool Initialize(string modelFileName = "gru_model_ultimate.onnx")
   {
      m_onnxHandle = OnnxCreate(modelFileName, ONNX_DEFAULT);
      if(m_onnxHandle == INVALID_HANDLE)
      {
         PrintFormat("[GRU ERROR] OnnxCreate failed for '%s'. Error: %d", modelFileName, GetLastError());
         m_initialized = false;
         return false;
      }
      const long inShape[]  = {1, GRU_SEQ_LEN, GRU_MAX_FEATURES};
      const long outShape[] = {1, 3};
      if(!OnnxSetInputShape(m_onnxHandle, 0, inShape))
         PrintFormat("[GRU WARNING] SetInputShape failed: %d", GetLastError());
      if(!OnnxSetOutputShape(m_onnxHandle, 0, outShape))
         PrintFormat("[GRU WARNING] SetOutputShape failed: %d", GetLastError());

      m_initialized = true;
      PrintFormat("[SuperGRU 76] Initialized '%s' (Shape: 1x%dx%d -> 1x3).", modelFileName, GRU_SEQ_LEN, GRU_MAX_FEATURES);
      return true;
   }

   void Release()
   {
      if(m_onnxHandle != INVALID_HANDLE)
      {
         OnnxRelease(m_onnxHandle);
         m_onnxHandle = INVALID_HANDLE;
      }
      m_initialized = false;
   }

   bool RunInference(double &bullProb, double &bearProb)
   {
      bullProb = 0.0;
      bearProb = 0.0;
      if(!m_initialized || m_onnxHandle == INVALID_HANDLE) return false;
      if(!BuildWindow()) return false;

      ZeroMemory(m_outputData);
      if(!OnnxRun(m_onnxHandle, ONNX_DEFAULT, m_inputData, m_outputData))
      {
         Print("[GRU WARNING] OnnxRun failed: " + IntegerToString(GetLastError()));
         return false;
      }
      bullProb = m_outputData[0];
      bearProb = m_outputData[2];
      return true;
   }

   double GetLastAtrNorm() { return m_lastAtrNorm; }
};

// Global Dual-AI Model Engines
CGRUFilter76      g_gru76;
CGoldAIONNXEngine g_goldMasterOnnx;
CGoldAIFeatures   g_goldFeatures;

//+------------------------------------------------------------------+
//| InitAIModels — initialize both models simultaneously             |
//+------------------------------------------------------------------+
bool InitAIModels()
{
   bool ok1 = g_gru76.Initialize(InpGruModelPath);
   bool ok2 = g_goldMasterOnnx.Initialize(InpGoldMasterModelPath);
   bool ok3 = g_goldFeatures.Initialize(_Symbol, _Period);

   PrintFormat("[Dual-AI Engine] SuperGRU 76: %s | GoldMaster AI 76: %s | Features: %s",
               (ok1 ? "READY" : "FAILED"), (ok2 ? "READY" : "FAILED"), (ok3 ? "READY" : "FAILED"));

   return (ok1 && ok2 && ok3);
}

//+------------------------------------------------------------------+
//| ReleaseAIModels                                                  |
//+------------------------------------------------------------------+
void ReleaseAIModels()
{
   g_gru76.Release();
   g_goldMasterOnnx.Release();
   g_goldFeatures.Release();
}

//+------------------------------------------------------------------+
//| UpdateOnnxCache — Synchronous dual-model inference on new bar    |
//+------------------------------------------------------------------+
void UpdateOnnxCache()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == g_cachedOnnxBarTime && g_cachedOnnxValid)
      return;

   // 1. Cycle history buffers
   if(g_cachedOnnxValid)
   {
      g_histOnnxBull2  = g_histOnnxBull1;
      g_histOnnxBear2  = g_histOnnxBear1;
      g_histOnnxValid2 = g_histOnnxValid1;

      g_histOnnxBull1  = g_cachedOnnxBull;
      g_histOnnxBear1  = g_cachedOnnxBear;
      g_histOnnxValid1 = g_cachedOnnxValid;
   }

   // 2. Run SuperGRU 76 Inference (AI Brain 1)
   double bullProb = 0.0, bearProb = 0.0;
   bool okGru = g_gru76.RunInference(bullProb, bearProb);

   g_cachedOnnxBarTime = currentBarTime;
   g_cachedOnnxBull    = bullProb;
   g_cachedOnnxBear    = bearProb;
   g_cachedOnnxMargin  = MathAbs(bullProb - bearProb);
   g_cachedOnnxValid   = okGru;

   // 3. Extract Microstructure & Order Flow + Run Master AI 76 (AI Brain 2)
   float masterFeatures[FEAT_COUNT];
   bool okFeat = g_goldFeatures.ExtractLatestFeatures(masterFeatures);
   if(okFeat)
   {
      SModelPrediction pred;
      bool okMaster = g_goldMasterOnnx.Predict(masterFeatures, pred);
      if(okMaster && pred.valid)
      {
         g_masterProbBull       = pred.probBullish;
         g_masterProbNeu        = pred.probNeutral;
         g_masterProbBear       = pred.probBearish;
         g_masterValid          = true;
         g_masterDelta          = (double)masterFeatures[3];  // 3: of_cumulative_delta_12
         g_masterDeltaMom       = (double)masterFeatures[4];  // 4: of_delta_momentum
         g_masterLiquiditySweep = (double)masterFeatures[13]; // 13: liquidity_sweep (+1.0 sweep high, -1.0 sweep low)
         g_masterImbalance      = (double)masterFeatures[2];  // 2: of_imbalance_ratio
         g_masterLargeTrade     = (double)masterFeatures[5];  // 5: of_large_trade_ratio
      }
      else
      {
         g_masterValid = false;
      }
   }
   else
   {
      g_masterValid = false;
   }

   RefreshRegimeCache();

   PrintFormat("[Dual-AI Inferred] Bar %s -> SuperGRU: BULL %.3f | BEAR %.3f | MasterAI: BULL %.3f | NEU %.3f | BEAR %.3f | Delta: %.2f | Sweep: %.1f",
               TimeToString(currentBarTime, TIME_DATE|TIME_MINUTES),
               g_cachedOnnxBull, g_cachedOnnxBear,
               g_masterProbBull, g_masterProbNeu, g_masterProbBear,
               g_masterDelta, g_masterLiquiditySweep);
}

//+------------------------------------------------------------------+
//| DispatchEnabledStrategies — Tri-Layer Consensus Strategy Engine   |
//+------------------------------------------------------------------+
void DispatchEnabledStrategies()
{
   double close0 = iClose(_Symbol, _Period, 0);
   double open1  = iOpen(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double range1 = MathMax(high1 - low1, 1e-8);
   double upWick1 = (high1 - MathMax(open1, close1)) / range1;
   double loWick1 = (MathMin(open1, close1) - low1) / range1;

   //===================================================================
   // SETUP A: SUPER_TREND_CONSENSUS (SuperGRU 76 + Master AI 76 Concurrence)
   //===================================================================
   if(InpUseSuperTrendConsensus && g_cachedOnnxValid && g_masterValid)
   {
      if(g_cachedOnnxBull >= InpStrategyOnnxMinProb && g_cachedOnnxBull > g_cachedOnnxBear &&
         g_masterProbBull >= 0.475 && g_masterProbBull > g_masterProbBear && g_masterDelta >= 0.0)
      {
         if(AttemptTradePlacement("SUPER_TREND_CONSENSUS", "BUY")) return;
      }
      else if(g_cachedOnnxBear >= InpStrategyOnnxMinProb && g_cachedOnnxBear > g_cachedOnnxBull &&
              g_masterProbBear >= 0.475 && g_masterProbBear > g_masterProbBull && g_masterDelta <= 0.0)
      {
         if(AttemptTradePlacement("SUPER_TREND_CONSENSUS", "SELL")) return;
      }
   }

   //===================================================================
   // SETUP B: TURTLE_SOUP_SWEEP (ICT Liquidity Sweep - Tri-Core Verified)
   //===================================================================
   if(InpUseTurtleSoupSweep && g_masterValid && g_nweMAE > 0.0)
   {
      // Master AI detected Sweep Low (-1.0) -> Rejection lower wick >= 35% near NWE Lower Band -> BUY
      if(g_masterLiquiditySweep <= -0.99 && loWick1 >= 0.35 && (close1 <= g_nweLowerBand + g_nweMAE * 0.3))
      {
         if(AttemptTradePlacement("TURTLE_SOUP_SWEEP", "BUY")) return;
      }
      // Master AI detected Sweep High (+1.0) -> Rejection upper wick >= 35% near NWE Upper Band -> SELL
      else if(g_masterLiquiditySweep >= 0.99 && upWick1 >= 0.35 && (close1 >= g_nweUpperBand - g_nweMAE * 0.3))
      {
         if(AttemptTradePlacement("TURTLE_SOUP_SWEEP", "SELL")) return;
      }
   }

   //===================================================================
   // SETUP C: NWE_REVERSAL_SNIPER -> Converted to Universal Boundary Guard (Zero Standalone Orders)
   //===================================================================

   //===================================================================
   // SETUP D: ONNX_CORE (SuperGRU 76 Core Direction Engine - Universal Tri-Core Locked)
   //===================================================================
   if(InpUseSuperGruCoreTrend && g_cachedOnnxValid)
   {
      if(g_cachedOnnxBull > g_cachedOnnxBear)
      {
         AttemptTradePlacement("ONNX_CORE", "BUY");
      }
      else if(g_cachedOnnxBear > g_cachedOnnxBull)
      {
         AttemptTradePlacement("ONNX_CORE", "SELL");
      }
   }
}

#endif // GE_AIINTEGRATION_MQH
