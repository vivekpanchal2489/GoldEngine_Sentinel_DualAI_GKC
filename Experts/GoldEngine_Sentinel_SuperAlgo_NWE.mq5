//+------------------------------------------------------------------+
//| GoldEngine_Sentinel_SuperAlgo_NWE.mq5                            |
//| Dual-AI Brain (SuperGRU 76 + Master AI 76)                       |
//| Microstructure & Order Flow + ICT Liquidity Sweep                |
//| Nadaraya-Watson Envelope (10 3 open) Geometric Boundary Guard    |
//| Two-Stage Step-Lock (+80->+30, +150->+100) & Dynamic Lot Floor   |
//+------------------------------------------------------------------+
#property copyright "GoldEngine Sentinel Super-Algo Release"
#property version   "10.00"
#property strict

#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_EntryGates.mqh>
#include <GE_NewsShield.mqh>
#include <GE_NadarayaWatson.mqh>
#include <GoldAI_Features.mqh>
#include <GoldAI_ONNXEngine.mqh>
#include <GE_AIIntegration.mqh>
#include <GE_DecisionLog.mqh>
#include <GE_OutcomeTracker.mqh>
#include <GE_Dashboard.mqh>

//+------------------------------------------------------------------+
//| SyncDashboardState                                               |
//+------------------------------------------------------------------+
void SyncDashboardState()
{
   g_dashKillSwitchActive = (InpKillSwitch || g_killSwitchBtnActive);
   g_dashRegimeMode       = g_cachedRegime;
   g_dashADX              = g_cachedAdx;
   g_dashATR              = g_cachedAtr;
   g_cachedRsi            = DashRSI(0);

   if(g_cachedOnnxValid)
   {
      g_dashOnnxClass   = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      g_dashOnnxProb    = MathMax(g_cachedOnnxBull, g_cachedOnnxBear);
      g_dashOnnxMargin  = g_cachedOnnxMargin;
   }
   else
   {
      g_dashOnnxClass   = "N/A";
      g_dashOnnxProb    = 0.0;
      g_dashOnnxMargin  = 0.0;
   }

   g_dashOnnxBull1  = g_histOnnxBull1;
   g_dashOnnxBear1  = g_histOnnxBear1;
   g_dashOnnxValid1 = g_histOnnxValid1;
   g_dashOnnxBull2  = g_histOnnxBull2;
   g_dashOnnxBear2  = g_histOnnxBear2;
   g_dashOnnxValid2 = g_histOnnxValid2;

   GetNextTradeAction(g_dashNextAction);

   g_dashTradesToday     = g_todayTrades;
   g_dashWinsToday       = g_todayWins;
   g_dashLossesToday     = g_todayLosses;
   g_dashNetPLToday      = g_todayNet;
   g_dashLastBlockSource = g_lastBlockSource;
   g_dashLastBlockReason = g_lastBlockReason;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   DecisionLogInit();
   OutcomeTrackerInit();

   InitAIModels();
   UpdateOnnxCache();
   UpdateNweEngine();
   SyncDashboardState();
   DashboardInit();

   EventSetTimer(1); // 1-second timer for live GUI telemetry

   Print("===================================================================");
   Print("=== GOLDENGINE SENTINEL SUPER-ALGO (DUAL-AI + NWE 10 3 OPEN) ===");
   PrintFormat("SuperGRU: %s | MasterAI: %s | Dynamic Base Lot: %.2f",
               InpGruModelPath, InpGoldMasterModelPath, InpBaseMinLot);
   Print("===================================================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DecisionLogDeinit();
   OutcomeTrackerDeinit();
   ReleaseAIModels();
   DashboardDeinit();
}

//+------------------------------------------------------------------+
//| Trade Transaction                                                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      OutcomeTrackerOnDeal(trans.deal);
   }
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   DashboardOnChartEvent(id, lparam, dparam, sparam);
}

//+------------------------------------------------------------------+
//| Expert Timer function (1s live telemetry)                        |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateNweEngine();
   UpdateNewsCalendarState();
   ExecuteHybridSmartShieldOnPositions();
   RefreshTodayStats();
   SyncDashboardState();
   DashboardRefresh();
}

//+------------------------------------------------------------------+
//| Expert Tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, _Period, 0);

   if(lastBarTime == 0)
   {
      lastBarTime = barTime;
      UpdateOnnxCache();
      UpdateNweEngine();
      UpdateNewsCalendarState();
      SyncDashboardState();
      return;
   }

   // 1. New M5 Bar Execution
   if(barTime != lastBarTime)
   {
      lastBarTime = barTime;
      UpdateOnnxCache();
      UpdateNweEngine();
      UpdateNewsCalendarState();
      ExecuteHybridSmartShieldOnPositions();
      DispatchEnabledStrategies();
      CheckExitContract(g_cachedOnnxBull, g_cachedOnnxBear, g_cachedOnnxValid);
   }
   else if(PositionsTotal() == 0)
   {
      // 1.5 Intra-Bar High-Conviction Reversal Evaluation (Lever 4)
      static datetime lastIntraCheck = 0;
      datetime nowT = TimeCurrent();
      if(nowT - lastIntraCheck >= 30) // check every 30 seconds
      {
         double o0 = iOpen(_Symbol, _Period, 0);
         double c0 = iClose(_Symbol, _Period, 0);
         double h0 = iHigh(_Symbol, _Period, 0);
         double l0 = iLow(_Symbol, _Period, 0);
         double rng = MathMax(h0 - l0, 1e-8);
         double upWick = (h0 - MathMax(o0, c0)) / rng;
         double loWick = (MathMin(o0, c0) - l0) / rng;

         // Intra-bar trigger on sharp rejection wick at envelope extremes
         if((upWick >= 0.35 && c0 >= (g_nweUpperBand - g_nweMAE * 0.25)) ||
            (loWick >= 0.35 && c0 <= (g_nweLowerBand + g_nweMAE * 0.25)))
         {
            lastIntraCheck = nowT;
            DispatchEnabledStrategies();
         }
      }
   }

   // 2. Real-Time Tick Protection & Telemetry
   UpdateNweEngine();
   UpdateNewsCalendarState();
   ExecuteHybridSmartShieldOnPositions();
   CheckExitContractTick();
   RefreshTodayStats();
   SyncDashboardState();
   DashboardRefresh();
}
