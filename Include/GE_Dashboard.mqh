//+------------------------------------------------------------------+
//| GE_Dashboard.mqh                                                  |
//| Big, spacious, ultra-clean Charcoal Shield Dashboard              |
//| Displays SuperGRU 76, Master AI 76, Liquidity Sweep, NWE, PnL    |
//| Zero text cutoff, perfectly aligned typography                    |
//+------------------------------------------------------------------+
#ifndef GE_DASHBOARD_MQH
#define GE_DASHBOARD_MQH

#include <GE_NadarayaWatson.mqh>

//--- Inputs ---
enum ENUM_DB_POSITION
{
   DB_POS_TOP_LEFT,      // Top Left
   DB_POS_TOP_RIGHT,     // Top Right
   DB_POS_BOTTOM_LEFT,   // Bottom Left
   DB_POS_BOTTOM_RIGHT,  // Bottom Right
   DB_POS_CENTER,        // Center
   DB_POS_FREE_MOVE      // Free Move
};

input group "=== Dashboard UI Settings ==="
input bool             InpShowDashboard      = true;               // Show Dashboard Panel
input ENUM_DB_POSITION InpDashboardPosition  = DB_POS_TOP_LEFT;     // Dashboard Position Mode
input int              InpDashboardX         = 20;                 // Custom X Offset
input int              InpDashboardY         = 60;                 // Custom Y Offset

//--- Object naming ---
#define DB_PREFIX     "GE_SuperAlgo_DB_"
#define DB_BG         (DB_PREFIX + "DbPanelBg")
#define DB_TITLE      (DB_PREFIX + "DbTitle")
#define DB_ROW(i)     (DB_PREFIX + "R" + IntegerToString(i))
#define DB_MAXROWS    11
#define DB_BTN        (DB_PREFIX + "KillBtn")

//--- Global variables read by dashboard ---
bool   g_dashKillSwitchActive   = false;
string g_dashRegimeMode         = "SIDEWAYS";
double g_dashADX                = 0.0;
double g_dashATR                = 0.0;
string g_dashOnnxClass          = "N/A";
double g_dashOnnxProb           = 0.0;
double g_dashOnnxMargin         = 0.0;

// History + Next action variables
double g_dashOnnxBull1  = 0.0;
double g_dashOnnxBear1  = 0.0;
bool   g_dashOnnxValid1 = false;
double g_dashOnnxBull2  = 0.0;
double g_dashOnnxBear2  = 0.0;
bool   g_dashOnnxValid2 = false;
string g_dashNextAction = "";
int    g_dashTradesToday        = 0;
int    g_dashWinsToday          = 0;
int    g_dashLossesToday        = 0;
double g_dashNetPLToday         = 0.0;
string g_dashLastBlockSource    = "";
string g_dashLastBlockReason    = "";

// Drag memory
int g_dbX = -1;
int g_dbY = -1;

// Forward declarations
void GetActiveConvictionSettings(double &activeConf, double &activeMargin, string &activeZoneName, string &activeZoneSched);
double CalculateDynamicBalanceLot();

//+------------------------------------------------------------------+
//| Helper to create label text elements                             |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, int fontSize, color clr, string font="Segoe UI")
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Helper to create background panel rectangle                      |
//+------------------------------------------------------------------+
void CreatePanelBg(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Helper to create a button object                                 |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, int fontSize, color clr, color bgColor, string font="Segoe UI")
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| DashboardDeinit                                                  |
//+------------------------------------------------------------------+
void DashboardDeinit()
{
   ObjectDelete(0, DB_BG);
   ObjectDelete(0, DB_TITLE);
   for(int i = 0; i < DB_MAXROWS; i++)
      ObjectDelete(0, DB_ROW(i));
   ObjectDelete(0, DB_BTN);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create or reposition the panel (Spacious 960x425 Charcoal Shield) |
//+------------------------------------------------------------------+
void CreateInterface()
{
   if(!InpShowDashboard)
   {
      DashboardDeinit();
      return;
   }

   int panelWidth  = 960;
   int panelHeight = 460;
   int margin      = 25;

   int chartWidth  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartHeight = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

   int baseX = InpDashboardX;
   int baseY = InpDashboardY;

   if(g_dbX >= 0 || g_dbY >= 0)
   {
      baseX = g_dbX;
      baseY = g_dbY;
   }
   else
   {
      switch(InpDashboardPosition)
      {
         case DB_POS_TOP_LEFT:
            baseX = InpDashboardX;
            baseY = InpDashboardY;
            break;
         case DB_POS_TOP_RIGHT:
            baseX = chartWidth - panelWidth - InpDashboardX;
            baseY = InpDashboardY;
            break;
         case DB_POS_BOTTOM_LEFT:
            baseX = InpDashboardX;
            baseY = chartHeight - panelHeight - InpDashboardY - 40;
            break;
         case DB_POS_BOTTOM_RIGHT:
            baseX = chartWidth - panelWidth - InpDashboardX;
            baseY = chartHeight - panelHeight - InpDashboardY - 40;
            break;
         case DB_POS_CENTER:
            baseX = (chartWidth - panelWidth) / 2;
            baseY = (chartHeight - panelHeight) / 2;
            break;
         case DB_POS_FREE_MOVE:
            baseX = InpDashboardX;
            baseY = InpDashboardY;
            break;
      }
      g_dbX = baseX;
      g_dbY = baseY;
   }

   int textX = baseX + margin;
   int fontSize = 10;

   // 1. Create Background Shield (Classic Dark Charcoal C'20,20,20')
   CreatePanelBg(DB_BG, baseX, baseY, panelWidth, panelHeight, C'20,20,20', C'70,70,70');
   ObjectSetInteger(0, DB_BG, OBJPROP_SELECTABLE, true);

   // 2. Create Header (Amber Gold C'255,179,0')
   CreateLabel(DB_TITLE, textX, baseY + 18, "GOLDENGINE SENTINEL SUPER-ALGO (DUAL-AI + NWE)", 12, C'255,179,0', "Segoe UI Semibold");

   // 3. Create Clickable Kill Switch Button
   string btnText = g_killSwitchBtnActive ? "HALTED" : "RUNNING";
   color btnBg    = g_killSwitchBtnActive ? C'239,83,80' : C'76,175,80';
   CreateButton(DB_BTN, baseX + panelWidth - 175, baseY + 13, 150, 28, btnText, 10, clrWhite, btnBg);

   // 4. Create 10 Rows with spacious 34px vertical gaps
   for(int i = 0; i < DB_MAXROWS; i++)
   {
      int rowY = baseY + 54 + (i * 34);
      CreateLabel(DB_ROW(i), textX, rowY, "", fontSize, clrWhite, "Segoe UI");
   }

   ChartRedraw(0);
}

void DashboardInit()
{
   CreateInterface();
}

//--- Helper ---
void ArrayAdd(string &arr[], string value)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = value;
}

//+------------------------------------------------------------------+
//| Build the list of display lines from current state               |
//+------------------------------------------------------------------+
void DashboardBuildLines(string &lines[])
{
   ArrayResize(lines, 0);

   // Line 0: Status & Lot sizing
   double dynLot = CalculateDynamicBalanceLot();
   int openCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         openCount++;
   }
   if(g_dashKillSwitchActive || g_killSwitchBtnActive)
      ArrayAdd(lines, "\x26D4 Status       : TRADING HALTED (Kill Switch Active)");
   else
      ArrayAdd(lines, StringFormat("\x25CF Status       : TRADING ACTIVE (Lot: %.2f | Pos: %d/%d | Sentinel Trail: Step Ladder $15->$10)", dynLot, openCount, InpMaxConcurrentTrades));

   // Line 1: Current IST Time (with seconds) & Active Zone
   MqlDateTime dt;
   TimeLocal(dt); // IST clock with seconds
   string ampm = (dt.hour >= 12) ? "PM" : "AM";
   int displayHour = dt.hour % 12;
   if(displayHour == 0) displayHour = 12;
   string istTimeStr = StringFormat("%02d:%02d:%02d %s", displayHour, dt.min, dt.sec, ampm);
   double activeConf = 0.0;
   double activeMargin = 0.0;
   string activeZoneName = "";
   string activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);
   ArrayAdd(lines, StringFormat("Current IST    : %s (Active Zone: %s)", istTimeStr, activeZoneName));

   // Line 2: Time Left (Live Candle Countdown in its OWN dedicated row!)
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   datetime nextBarTime    = currentBarTime + PeriodSeconds(_Period);
   int secsLeft            = (int)(nextBarTime - TimeCurrent());
   if(secsLeft < 0) secsLeft = 0;
   string countdownStr     = StringFormat("%02d:%02d", secsLeft / 60, secsLeft % 60);
   ArrayAdd(lines, StringFormat("Time Left      : %s (M5 Bar Countdown)", countdownStr));

   // Line 3: IST Schedule
   ArrayAdd(lines, "IST Schedule   : " + activeZoneSched);

   // Line 4: SuperGRU 76 (AI Brain 1 - Temporal Sequence Context)
   ArrayAdd(lines, StringFormat("SuperGRU 76    : %s %.1f%% (B:%.1f%%  S:%.1f%%) | Margin: %+.3f",
            g_dashOnnxClass, g_dashOnnxProb * 100.0,
            g_cachedOnnxBull * 100.0, g_cachedOnnxBear * 100.0,
            (g_cachedOnnxBull >= g_cachedOnnxBear ? g_dashOnnxMargin : -g_dashOnnxMargin)));

   // Line 5: Master AI 76 (AI Brain 2 - Live Microstructure & Order Flow)
   string masterStr = "N/A (Initializing...)";
   if(g_masterValid)
   {
      string mClass = (g_masterProbBull >= g_masterProbBear ? "BULL" : "BEAR");
      double mProb  = MathMax(g_masterProbBull, g_masterProbBear);
      masterStr = StringFormat("%s %.1f%% (B:%.1f%%  S:%.1f%%) | Delta : %+.1f",
                               mClass, mProb * 100.0,
                               g_masterProbBull * 100.0, g_masterProbBear * 100.0,
                               g_masterDelta);
   }
   ArrayAdd(lines, StringFormat("Master AI 76   : %s", masterStr));

   // Line 6: ICT Liquidity Sweep Status (Feature #13 Trigger)
   string sweepStr = "NO SWEEP (Normal In-Trend Flow)";
   if(g_masterLiquiditySweep <= -0.99) sweepStr = "SWEEP LOW (Bullish Liquidity Reversal Armed)";
   else if(g_masterLiquiditySweep >= 0.99) sweepStr = "SWEEP HIGH (Bearish Liquidity Reversal Armed)";
   ArrayAdd(lines, StringFormat("Liquidity Sweep: %s", sweepStr));

   // Line 7: Gaussian Kernel Channel (GKC Envelope)
   bool topVeto = IsPriceAtTopExhaustion();
   bool botVeto = IsPriceAtBottomExhaustion();
   string nweVeto = "[VETO: NONE]";
   if(topVeto) nweVeto = "[VETO: TOP-BUY]";
   else if(botVeto) nweVeto = "[VETO: BOT-SELL]";
   ArrayAdd(lines, StringFormat("GKC (10 3 open): Mid: %.2f | Upper: %.2f | Lower: %.2f %s",
            GetNweMidline(), GetNweUpperBand(), GetNweLowerBand(), nweVeto));

   // Line 8: Next Planned Trade Action
   ArrayAdd(lines, StringFormat("Next Trade     : %s", g_dashNextAction));

   // Line 9: Last block reason
   if(StringLen(g_dashLastBlockReason) > 0)
   {
      if(StringLen(g_dashLastBlockSource) > 0)
         ArrayAdd(lines, StringFormat("Last block     : %s - %s", g_dashLastBlockSource, g_dashLastBlockReason));
      else
         ArrayAdd(lines, StringFormat("Last block     : %s", g_dashLastBlockReason));
   }
   else if(StringFind(g_dashNextAction, "BLOCKED") >= 0)
   {
      ArrayAdd(lines, StringFormat("Last block     : %s", g_dashNextAction));
   }
   else
   {
      ArrayAdd(lines, "Last block     : NONE (All Systems Clear)");
   }

   // Line 10: Today's stats
   ArrayAdd(lines, StringFormat("Today          : %d trades | %dW %dL | Net: %s$%.2f",
            g_dashTradesToday, g_dashWinsToday, g_dashLossesToday,
            (g_dashNetPLToday >= 0 ? "+" : "-"), MathAbs(g_dashNetPLToday)));
}

//+------------------------------------------------------------------+
//| Truncate a line if it would exceed the panel width               |
//+------------------------------------------------------------------+
string DashboardTruncateIfNeeded(string text)
{
   uint w, h;
   TextSetFont("Segoe UI", -10 * 10, 0);
   TextGetSize(text, w, h);
   if(w <= 940) return text;

   string trimmed = text;
   while(StringLen(trimmed) > 3)
   {
      trimmed = StringSubstr(trimmed, 0, StringLen(trimmed) - 1);
      TextGetSize(trimmed + "...", w, h);
      if(w <= 940) return trimmed + "...";
   }
   return trimmed;
}

//+------------------------------------------------------------------+
//| DashboardRefresh                                                 |
//+------------------------------------------------------------------+
void DashboardRefresh()
{
   if(!InpShowDashboard) return;
   if(ObjectFind(0, DB_BG) < 0) CreateInterface();

   string btnText = g_killSwitchBtnActive ? "HALTED" : "RUNNING";
   color btnBg = g_killSwitchBtnActive ? C'239,83,80' : C'76,175,80';
   if(ObjectGetString(0, DB_BTN, OBJPROP_TEXT) != btnText)
      ObjectSetString(0, DB_BTN, OBJPROP_TEXT, btnText);
   if(ObjectGetInteger(0, DB_BTN, OBJPROP_BGCOLOR) != btnBg)
      ObjectSetInteger(0, DB_BTN, OBJPROP_BGCOLOR, btnBg);

   string lines[];
   DashboardBuildLines(lines);

   int n = MathMin(ArraySize(lines), DB_MAXROWS);
   for(int i = 0; i < n; i++)
   {
      string text = DashboardTruncateIfNeeded(lines[i]);
      if(ObjectGetString(0, DB_ROW(i), OBJPROP_TEXT) != text)
         ObjectSetString(0, DB_ROW(i), OBJPROP_TEXT, text);

      color rowColor = clrWhite;
      if(i == 0) // Status
         rowColor = (g_dashKillSwitchActive || g_killSwitchBtnActive) ? C'239,83,80' : C'76,175,80';
      else if(i == 1) // Current IST
         rowColor = C'255,224,130';
      else if(i == 2) // Time Left
         rowColor = C'0,255,255';
      else if(i == 3) // IST Schedule
         rowColor = C'144,202,249';
      else if(i == 4) // SuperGRU 76
      {
         if(g_dashOnnxClass == "BULL") rowColor = C'0,255,255';
         else if(g_dashOnnxClass == "BEAR") rowColor = C'255,165,0';
         else rowColor = clrGray;
      }
      else if(i == 5) // Master AI 76
         rowColor = C'200,230,201';
      else if(i == 6) // Liquidity Sweep
      {
         if(StringFind(lines[i], "SWEEP LOW") >= 0) rowColor = C'0,255,255';
         else if(StringFind(lines[i], "SWEEP HIGH") >= 0) rowColor = C'255,165,0';
         else rowColor = C'180,180,180';
      }
      else if(i == 7) // NWE (10 3 open)
      {
         if(StringFind(lines[i], "VETO") >= 0 && StringFind(lines[i], "NONE") < 0) rowColor = C'239,83,80';
         else rowColor = C'255,245,157';
      }
      else if(i == 8) // Next Trade
      {
         if(StringFind(lines[i], "Blocked") >= 0) rowColor = C'239,83,80';
         else if(StringFind(lines[i], "BUY") >= 0) rowColor = C'0,255,255';
         else if(StringFind(lines[i], "SELL") >= 0) rowColor = C'255,165,0';
         else rowColor = clrWhite;
      }
      else if(i == 9) // Last Block
         rowColor = C'150,150,150';
      else if(i == 10) // Today's Stats
      {
         if(g_dashNetPLToday > 0.0) rowColor = C'76,175,80';
         else if(g_dashNetPLToday < 0.0) rowColor = C'239,83,80';
         else rowColor = clrWhite;
      }

      if(ObjectGetInteger(0, DB_ROW(i), OBJPROP_COLOR) != rowColor)
         ObjectSetInteger(0, DB_ROW(i), OBJPROP_COLOR, rowColor);
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DashboardOnChartEvent                                            |
//+------------------------------------------------------------------+
void DashboardOnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!InpShowDashboard) return;

   if(id == CHARTEVENT_OBJECT_CLICK && sparam == DB_BTN)
   {
      g_killSwitchBtnActive = !g_killSwitchBtnActive;
      ObjectSetInteger(0, DB_BTN, OBJPROP_STATE, false);
      DashboardRefresh();
      return;
   }
}

#endif // GE_DASHBOARD_MQH
