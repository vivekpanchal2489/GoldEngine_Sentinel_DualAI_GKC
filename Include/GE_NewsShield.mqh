//+------------------------------------------------------------------+
//| GE_NewsShield.mqh                                                |
//| Sentinel Automated 3-Tier Economic News & Volatility Shock Guard |
//| Native MT5 High-Impact USD Calendar + Hybrid Smart Shield        |
//+------------------------------------------------------------------+
#ifndef GE_NEWSSHIELD_MQH
#define GE_NEWSSHIELD_MQH

#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>

//+------------------------------------------------------------------+
//| News Shield Inputs                                               |
//+------------------------------------------------------------------+
input group "=== Sentinel Automated News Defense Matrix ==="
input bool   InpUseNewsShield           = true;   // Enable Autonomous Economic News Defense Shield
input int    InpNewsPreBlockMinutes     = 15;     // Minutes before High-Impact News to freeze new entries (15m)
input int    InpNewsPostBlockMinutes    = 15;     // Minutes after High-Impact News to freeze new entries (15m)
input int    InpNewsPositionManageMin   = 5;      // Minutes before High-Impact News to execute Hybrid Smart Shield (5m)
input double InpNewsProfitFreeRollUSD   = 30.0;   // Minimum unrealized profit ($30.00) to keep position as Free-Roll
input double InpNewsFreeRollLockUSD     = 10.0;   // Guaranteed profit locked on Free-Roll positions ($10.00)
input double InpMaxAllowedSpreadPts     = 3.5;    // Maximum allowed broker spread in points (Normal 1.5-2.0, >3.5 blocks)
input double InpVolSpikeAtrMult         = 2.5;    // Volatility spike multiplier vs ATR(14)

// Global state variables
bool     g_newsShieldActive             = false;
string   g_newsStatusText               = "ALL CLEAR";
string   g_nextEventName                = "";
datetime g_nextEventTime                = 0;
int      g_minsToNextEvent              = 999;
int      g_minsSinceLastEvent           = 999;
datetime g_lastVolSpikeTime             = 0;
datetime g_lastNewsPositionManagedTime  = 0;

//+------------------------------------------------------------------+
//| UpdateNewsCalendarState — Scan for High-Impact USD Events        |
//+------------------------------------------------------------------+
void UpdateNewsCalendarState()
{
   if(!InpUseNewsShield)
   {
      g_newsShieldActive = false;
      g_newsStatusText = "DISABLED";
      return;
   }

   datetime now = TimeCurrent();
   datetime fromTime = now - (InpNewsPostBlockMinutes + 5) * 60;
   datetime toTime   = now + (InpNewsPreBlockMinutes + 120) * 60; // scan ahead 2 hours

   g_nextEventName = "";
   g_nextEventTime = 0;
   g_minsToNextEvent = 999;
   g_minsSinceLastEvent = 999;
   g_newsShieldActive = false;

   MqlCalendarValue values[];
   int totalValues = CalendarValueHistory(values, fromTime, toTime, "US", NULL);

   if(totalValues > 0)
   {
      for(int i = 0; i < totalValues; i++)
      {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
         {
            // Filter strictly for HIGH importance USD events
            if(event.importance == CALENDAR_IMPORTANCE_HIGH)
            {
               datetime eventTime = values[i].time;
               int diffSecs = (int)(eventTime - now);
               int diffMins = diffSecs / 60;

               // If event is in the future and closest
               if(diffSecs >= 0 && diffMins < g_minsToNextEvent)
               {
                  g_minsToNextEvent = diffMins;
                  g_nextEventName = event.name;
                  g_nextEventTime = eventTime;
               }
               // If event happened recently in the past
               else if(diffSecs < 0)
               {
                  int pastMins = MathAbs(diffMins);
                  if(pastMins < g_minsSinceLastEvent)
                  {
                     g_minsSinceLastEvent = pastMins;
                  }
               }
            }
         }
      }
   }

   // 1. Check if we are inside Pre-News or Post-News Block Window
   if(g_minsToNextEvent <= InpNewsPreBlockMinutes)
   {
      g_newsShieldActive = true;
      g_newsStatusText = StringFormat("PRE-NEWS STANDBY (%s in %d mins)", 
                                      (StringLen(g_nextEventName) > 0 ? g_nextEventName : "High-Impact USD News"), 
                                      g_minsToNextEvent);
   }
   else if(g_minsSinceLastEvent <= InpNewsPostBlockMinutes)
   {
      g_newsShieldActive = true;
      g_newsStatusText = StringFormat("POST-NEWS BLACKOUT (+%d mins after event)", g_minsSinceLastEvent);
   }
   else if(g_minsToNextEvent < 60)
   {
      g_newsShieldActive = false;
      g_newsStatusText = StringFormat("UPCOMING: %s in %d mins", g_nextEventName, g_minsToNextEvent);
   }
   else
   {
      g_newsShieldActive = false;
      g_newsStatusText = "ALL CLEAR (No High-Impact USD Events)";
   }
}

//+------------------------------------------------------------------+
//| ExecuteHybridSmartShieldOnPositions — Option 1 Open Trade Logic   |
//| (Called 5 minutes before High-Impact News Release)               |
//+------------------------------------------------------------------+
void ExecuteHybridSmartShieldOnPositions()
{
   if(!InpUseNewsShield || g_minsToNextEvent > InpNewsPositionManageMin || g_minsToNextEvent < 0)
      return;

   // Prevent multiple runs for the same news event
   if(g_nextEventTime > 0 && g_lastNewsPositionManagedTime == g_nextEventTime)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double profit     = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double lot        = PositionGetDouble(POSITION_VOLUME);
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double currentTP  = PositionGetDouble(POSITION_TP);

      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0 || lot <= 0.0) continue;

      // OPTION 1A: PROFITABLE TRADES (>= $30 Profit) -> CONVERT TO 100% FREE ROLL
      if(profit >= InpNewsProfitFreeRollUSD)
      {
         double profitDist = (InpNewsFreeRollLockUSD * tickSize) / (lot * tickValue);
         double targetSL   = (type == POSITION_TYPE_BUY) ? NormalizeDouble(entryPrice + profitDist, _Digits)
                                                         : NormalizeDouble(entryPrice - profitDist, _Digits);

         bool modifyNeeded = false;
         if(type == POSITION_TYPE_BUY  && (targetSL > currentSL || currentSL == 0.0)) modifyNeeded = true;
         if(type == POSITION_TYPE_SELL && (targetSL < currentSL || currentSL == 0.0)) modifyNeeded = true;

         if(modifyNeeded)
         {
            CTradeSafe trade;
            if(trade.PositionModify(ticket, targetSL, currentTP))
            {
               PrintFormat("[News-Smart-Shield] #%I64u (+%.2f USD profit) converted to FREE-ROLL before %s! SL locked at %.2f (+%.2f USD).",
                           ticket, profit, g_nextEventName, targetSL, InpNewsFreeRollLockUSD);
            }
         }
      }
      // OPTION 1B: FLAT OR LOSING TRADES (< $30 Profit) -> CLOSE BEFORE NEWS (ZERO SLIPPAGE)
      else
      {
         CTradeSafe trade;
         if(trade.PositionClose(ticket))
         {
            PrintFormat("[News-Smart-Shield] #%I64u (PnL: %+.2f USD < $%.2f threshold) closed 5m before %s to eliminate slippage risk!",
                        ticket, profit, InpNewsProfitFreeRollUSD, g_nextEventName);
         }
      }
   }

   if(g_nextEventTime > 0)
      g_lastNewsPositionManagedTime = g_nextEventTime;
}

//+------------------------------------------------------------------+
//| CheckSpreadShock — Unscheduled Event & Widening Protection       |
//+------------------------------------------------------------------+
bool CheckSpreadShock(string &shockReason)
{
   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(spreadPts > InpMaxAllowedSpreadPts)
   {
      shockReason = StringFormat("SPREAD_SHOCK: Spread %.2f pts > %.2f pts limit (Illiquidity / News Spike)",
                                 spreadPts, InpMaxAllowedSpreadPts);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| CheckVolatilitySpikeShock — Sudden Flash Anomaly Guard          |
//+------------------------------------------------------------------+
bool CheckVolatilitySpikeShock(const double atrVal, string &spikeReason)
{
   if(atrVal <= 0.0) return false;

   double h0 = iHigh(_Symbol, _Period, 0);
   double l0 = iLow(_Symbol, _Period, 0);
   double barRange = MathMax(h0 - l0, 0.0);

   if(barRange >= InpVolSpikeAtrMult * atrVal)
   {
      g_lastVolSpikeTime = TimeCurrent();
      spikeReason = StringFormat("VOLATILITY_SHOCK: Bar Range %.2f pts >= %.1fx ATR (%.2f pts)",
                                 barRange, InpVolSpikeAtrMult, atrVal);
      return true;
   }

   // 10-minute cooldown after any severe volatility shock
   if(g_lastVolSpikeTime > 0 && (TimeCurrent() - g_lastVolSpikeTime) <= 600)
   {
      int remainSecs = (int)(600 - (TimeCurrent() - g_lastVolSpikeTime));
      spikeReason = StringFormat("VOLATILITY_SHOCK_COOLDOWN (%d sec remaining)", remainSecs);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| IsNewsShieldBlocking — Master Chokepoint Gate for Entry Gates    |
//+------------------------------------------------------------------+
bool IsNewsShieldBlocking(string &blockReason)
{
   if(!InpUseNewsShield)
      return false;

   UpdateNewsCalendarState();
   ExecuteHybridSmartShieldOnPositions();

   // 1. Check Economic Calendar Scheduled Block
   if(g_newsShieldActive)
   {
      blockReason = g_newsStatusText;
      return true;
   }

   // 2. Check Spread Shock
   string spreadReason = "";
   if(CheckSpreadShock(spreadReason))
   {
      blockReason = spreadReason;
      return true;
   }

   // 3. Check Volatility Shock
   string spikeReason = "";
   double atrBuf[1];
   int atrH = iATR(_Symbol, _Period, 14);
   double atrNow = 2.0;
   if(atrH != INVALID_HANDLE && CopyBuffer(atrH, 0, 0, 1, atrBuf) > 0) atrNow = atrBuf[0];

   if(CheckVolatilitySpikeShock(atrNow, spikeReason))
   {
      blockReason = spikeReason;
      return true;
   }

   return false;
}

#endif // GE_NEWSSHIELD_MQH
