//+------------------------------------------------------------------+
//| GE_OutcomeTracker.mqh                                            |
//| Persistent cumulative SL/TP outcome tracker for LIVE trades.     |
//|                                                                  |
//| Goal: build a real sample size over weeks so the live SL-hit     |
//| rate can be compared against the 57.8% backtest baseline (and    |
//| the 66.7% TP-hit day observed on 2026-08-18) instead of a fresh  |
//| n=6 analysis each time a trade hits SL.                          |
//|                                                                  |
//| Design:                                                          |
//|   - Append-only CSV MQL5/Files/SentinelOutcomes.csv              |
//|     columns: close_time,ticket,direction,entry,exit,reason,      |
//|              running_sl,running_tp,running_other,sl_rate_pct     |
//|   - reason: SL | TP | OTHER (time-decay, reversal-exit, manual)  |
//|   - Every row carries the cumulative running counts AT CLOSE     |
//|     time, so the file is a self-contained running ledger.        |
//|   - On init the file is scanned to reseed in-memory counters,    |
//|     so restarting the terminal/EA never loses the cumulative     |
//|     total (unlike a per-day snapshot).                           |
//|   - sl_rate = SL / (SL + TP); OTHER closes excluded from the     |
//|     denominator because they are neither SL nor TP hits.         |
//|   - Hooked via OnTradeTransaction() in the EA (DEAL_ENTRY_OUT    |
//|     deals for _Symbol).                                          |
//|                                                                  |
//| GUARD RAILS:                                                     |
//|   - Record-only; never influences entry or exit decisions.       |
//|   - One persistent handle, FileFlush after every write.          |
//|   - Classifies by DEAL_REASON (authoritative):                   |
//|       DEAL_REASON_SL   -> SL                                     |
//|       DEAL_REASON_TP   -> TP                                     |
//|       anything else    -> OTHER (e.g. EXPERT, CLIENT, ...)       |
//+------------------------------------------------------------------+
#ifndef GE_OUTCOMETRACKER_MQH
#define GE_OUTCOMETRACKER_MQH

int    g_outSlCount    = 0;
int    g_outTpCount    = 0;
int    g_outOtherCount = 0;
bool   g_outTrackerReady = false;
string g_outFileName   = "SentinelOutcomes.csv";
int    g_outHandle     = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| OutCsvQuote — minimal CSV quote for tracker rows (text is        |
//| limited to direction/reason, but keep it safe anyway).           |
//+------------------------------------------------------------------+
string OutCsvQuote(const string s)
{
   string esc = s;
   StringReplace(esc, "\"", "\"\"");
   return "\"" + esc + "\"";
}

//+------------------------------------------------------------------+
//| OutcomeTrackerInit — scan existing file to reseed counters, then |
//| open the persistent append handle and write header if new.       |
//+------------------------------------------------------------------+
bool OutcomeTrackerInit()
{
   g_outSlCount    = 0;
   g_outTpCount    = 0;
   g_outOtherCount = 0;

   //--- reseed from any existing rows (survives terminal/EA restarts)
   int readH = FileOpen(g_outFileName, FILE_READ | FILE_ANSI);
   if(readH != INVALID_HANDLE)
   {
      string line;
      bool first = true;
      while(!FileIsEnding(readH))
      {
         line = FileReadString(readH);
         if(first)   // skip header
         {
            first = false;
            continue;
         }
         StringTrimLeft(line);
         StringTrimRight(line);
         if(StringLen(line) == 0)
            continue;
         string parts[];
         int n = StringSplit(line, ',', parts);
         if(n >= 6)
         {
            string reason = parts[5];
            StringReplace(reason, "\"", "");
            if(reason == "SL")      g_outSlCount++;
            else if(reason == "TP") g_outTpCount++;
            else                    g_outOtherCount++;
         }
      }
      FileClose(readH);
   }

   //--- open append handle
   g_outHandle = FileOpen(g_outFileName, FILE_READ | FILE_WRITE | FILE_ANSI);
   if(g_outHandle == INVALID_HANDLE)
   {
      Print("[OutcomeTracker] failed to open ", g_outFileName, ", error ", GetLastError());
      return false;
   }

   FileSeek(g_outHandle, 0, SEEK_END);

   if(FileSize(g_outHandle) == 0)
   {
      FileWriteString(g_outHandle,
         "close_time,ticket,direction,entry,exit,reason,running_sl,running_tp,running_other,sl_rate_pct\r\n");
      FileFlush(g_outHandle);
   }

   g_outTrackerReady = true;
   PrintFormat("[OutcomeTracker] seeded cumulative: SL=%d TP=%d OTHER=%d",
               g_outSlCount, g_outTpCount, g_outOtherCount);
   return true;
}

//+------------------------------------------------------------------+
//| OutcomeTrackerDeinit — flush and close the persistent handle.    |
//+------------------------------------------------------------------+
void OutcomeTrackerDeinit()
{
   if(g_outHandle != INVALID_HANDLE)
   {
      FileFlush(g_outHandle);
      FileClose(g_outHandle);
      g_outHandle = INVALID_HANDLE;
   }
   g_outTrackerReady = false;
}

//+------------------------------------------------------------------+
//| OutcomeTrackerRecord — append one closed-trade row and update    |
//| the running cumulative counters.                                 |
//+------------------------------------------------------------------+
void OutcomeTrackerRecord(const string closeTime, const ulong ticket,
                          const string direction, const double entry,
                          const double exitPrice, const string reason)
{
   if(!g_outTrackerReady)
      return;

   if(reason == "SL")      g_outSlCount++;
   else if(reason == "TP") g_outTpCount++;
   else                    g_outOtherCount++;

   int denom = g_outSlCount + g_outTpCount;
   double slRate = (denom > 0) ? (100.0 * g_outSlCount / denom) : 0.0;

   string row =
      OutCsvQuote(closeTime) + "," +
      IntegerToString(ticket) + "," +
      OutCsvQuote(direction) + "," +
      DoubleToString(entry, _Digits) + "," +
      DoubleToString(exitPrice, _Digits) + "," +
      OutCsvQuote(reason) + "," +
      IntegerToString(g_outSlCount) + "," +
      IntegerToString(g_outTpCount) + "," +
      IntegerToString(g_outOtherCount) + "," +
      DoubleToString(slRate, 1) + "\r\n";

   FileWriteString(g_outHandle, row);
   FileFlush(g_outHandle);

   PrintFormat("[OutcomeTracker] #%I64u %s close %.2f -> %s | cumulative SL=%d TP=%d OTHER=%d SL%%=%.1f",
               ticket, direction, exitPrice, reason,
               g_outSlCount, g_outTpCount, g_outOtherCount, slRate);
}

//+------------------------------------------------------------------+
//| OutcomeTrackerOnDeal — called from the EA's OnTradeTransaction.  |
//| Classifies DEAL_ENTRY_OUT deals on _Symbol via DEAL_REASON.      |
//+------------------------------------------------------------------+
void OutcomeTrackerOnDeal(const ulong deal)
{
   if(!HistoryDealSelect(deal))
      return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
      return;

   ENUM_DEAL_REASON reasonEnum = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   double netProfit = HistoryDealGetDouble(deal, DEAL_PROFIT);
   string reason;
   if(reasonEnum == DEAL_REASON_TP)
      reason = "TP";
   else if(reasonEnum == DEAL_REASON_SL)
   {
      // If deal closed in net profit (> 0), it was a trailing stop / profit lock!
      if(netProfit > 0.0)
         reason = "TP";
      else
         reason = "SL";
   }
   else
   {
      reason = (netProfit > 0.0) ? "TP" : "OTHER";
   }

   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE);
   string direction = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";

   string closeTime = TimeToString((datetime)HistoryDealGetInteger(deal, DEAL_TIME),
                                   TIME_DATE | TIME_MINUTES);
   ulong  ticket    = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   double exitPrice = HistoryDealGetDouble(deal, DEAL_PRICE);

   //--- find the matching entry deal for this position to log entry price
   double entryPrice = 0.0;
   if(HistorySelectByPosition(ticket))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            entryPrice = HistoryDealGetDouble(d, DEAL_PRICE);
            break;
         }
      }
   }

   OutcomeTrackerRecord(closeTime, ticket, direction, entryPrice, exitPrice, reason);
}

#endif // GE_OUTCOMETRACKER_MQH
