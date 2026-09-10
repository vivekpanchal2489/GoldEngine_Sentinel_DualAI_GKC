//+------------------------------------------------------------------+
//| GE_DecisionLog.mqh                                               |
//| Full decision-logging system (Step 7 + addendum).                |
//|                                                                  |
//| One row per trade attempt (PLACED or BLOCKED), written to        |
//| MQL5/Files/GoldDecisionLog.csv at the single attempt chokepoint. |
//|                                                                  |
//| STEP 7 ADDENDUM COMPLIANCE:                                      |
//|   - Every TEXT field is CSV-quoted (wrapped in double quotes,    |
//|     internal double-quotes escaped by doubling) — even if the    |
//|     value currently contains no comma. Free text (ai_reason_text |
//|     etc.) can never corrupt the row layout.                      |
//|   - ONE persistent file handle, opened once in DecisionLogInit() |
//|     (called from OnInit), kept for the EA's lifetime, closed in  |
//|     DecisionLogDeinit() (called from OnDeinit). NO per-row open/ |
//|     close.                                                       |
//|   - FileFlush() after EVERY write — no lost rows on crash.       |
//|                                                                  |
//| DEPENDENCY POSITION (Step 6 addendum): leaf module — used by any |
//| module above it, includes NO other new module.                   |
//|                                                                  |
//| GUARD RAILS:                                                     |
//|   - Logging only records outcomes; it never influences decisions |
//|   - Every attempted entry MUST pass through LogTradeAttempt() —  |
//|     if a strategy can place without a row here, that is a bug.   |
//+------------------------------------------------------------------+
#ifndef GE_DECISIONLOG_MQH
#define GE_DECISIONLOG_MQH

//+------------------------------------------------------------------+
//| Decision record — mirrors the CSV schema, one row per attempt    |
//+------------------------------------------------------------------+
struct SDecisionRecord
{
   string timestamp;          // moment the attempt was evaluated
   string symbol;             // e.g. XAUUSD
   string direction;          // BUY / SELL
   string strategy_source;    // ONNX_CORE / GNN_REVERSION / PULLBACK / ...
   double onnx_prob_bull;     // P(BULL)
   double onnx_prob_bear;     // P(BEAR)
   double onnx_margin;        // |P(BULL)-P(BEAR)|
   string onnx_predicted_class; // BULL / BEAR
   double adx_value;          // current ADX
   double atr_value;          // current ATR
   string regime_mode;        // TRENDING / SIDEWAYS
   bool   ai_active;          // AI engine enabled/responding
   int    ai_conviction;      // 0-100
   string ai_reason_text;     // AI's stated reason
   string daily_bias_state;   // current daily-bias subsystem state
   string result;             // PLACED / BLOCKED
   string block_reason;       // gate name or "NONE"
   double entry_price;        // if placed
   double sl_price;           // if placed
   double tp_price;           // if placed
   double lot_size;           // if placed
   double risk_usd;           // if placed
};

//+------------------------------------------------------------------+
//| Persistent file handle — opened ONCE, held for the EA's lifetime |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Persistent file handles — opened ONCE, held for the EA's lifetime|
//+------------------------------------------------------------------+
int g_decisionLogHandle   = INVALID_HANDLE;
int g_predictionLogHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Last blocked attempt (source + reason) — owned here, updated by   |
//| LogTradeAttempt on every blocked attempt, read by the dashboard. |
//+------------------------------------------------------------------+
string g_lastBlockSource = "";
string g_lastBlockReason = "";

//+------------------------------------------------------------------+
//| Today's trade tally — cached here (scan of closed deals for the   |
//| current calendar day), read by the dashboard. The dashboard never |
//| computes its own version; it renders these values.                |
//+------------------------------------------------------------------+
int    g_todayTrades = 0;
int    g_todayWins   = 0;
int    g_todayLosses = 0;
double g_todayNet    = 0.0;

void RefreshTodayStats()
{
   g_todayTrades = 0;
   g_todayWins   = 0;
   g_todayLosses = 0;
   g_todayNet    = 0.0;

   datetime now = TimeCurrent();
   MqlDateTime dnow;
   TimeToStruct(now, dnow);
   dnow.hour = 0; dnow.min = 0; dnow.sec = 0;
   datetime dayStart = StructToTime(dnow);

   if(!HistorySelect(dayStart, now))
      return;

   int total = HistoryDealsTotal();
   for(int d = 0; d < total; d++)
   {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                      HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);
      g_todayTrades++;
      if(profit >= 0.0) g_todayWins++; else g_todayLosses++;
      g_todayNet += profit;
   }
}

//+------------------------------------------------------------------+
//| CsvQuote — standard CSV escaping for a text field.               |
//| Every text value is ALWAYS wrapped in double quotes; any internal |
//| double-quote character is escaped by doubling it.                |
//+------------------------------------------------------------------+
string CsvQuote(const string text)
{
   string esc = "";
   int len = StringLen(text);
   for(int i = 0; i < len; i++)
   {
      string ch = StringSubstr(text, i, 1);
      if(ch == "\"")
         esc += "\"\"";
      else
         esc += ch;
   }
   return "\"" + esc + "\"";
}

//+------------------------------------------------------------------+
//| PredictionLogInit — open the prediction log ONCE (append)       |
//+------------------------------------------------------------------+
bool PredictionLogInit()
{
   g_predictionLogHandle = FileOpen("GoldOnnxPredictionLog.csv", FILE_READ | FILE_WRITE | FILE_ANSI);
   if(g_predictionLogHandle == INVALID_HANDLE)
   {
      Print("[DecisionLog] failed to open GoldOnnxPredictionLog.csv, error ", GetLastError());
      return false;
   }

   FileSeek(g_predictionLogHandle, 0, SEEK_END);

   if(FileSize(g_predictionLogHandle) == 0)
   {
      FileWriteString(g_predictionLogHandle,
         "timestamp" + "," +
         "symbol" + "," +
         "bull_prob" + "," +
         "bear_prob" + "," +
         "margin" + "," +
         "predicted_class" + "," +
         "valid" + "\r\n");
      FileFlush(g_predictionLogHandle);
   }

   return true;
}

//+------------------------------------------------------------------+
//| PredictionLogDeinit — flush and close the prediction log handle  |
//+------------------------------------------------------------------+
void PredictionLogDeinit()
{
   if(g_predictionLogHandle != INVALID_HANDLE)
   {
      FileFlush(g_predictionLogHandle);
      FileClose(g_predictionLogHandle);
      g_predictionLogHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| DecisionLogInit — open the log ONCE (append) at OnInit; write    |
//| the header if the file is new. Returns true on success.          |
//+------------------------------------------------------------------+
bool DecisionLogInit()
{
   bool pOk = PredictionLogInit();
   if(!pOk)
   {
      Print("[DecisionLog] Failed to initialize GoldOnnxPredictionLog.csv");
   }

   g_decisionLogHandle = FileOpen("GoldDecisionLog.csv", FILE_READ | FILE_WRITE | FILE_ANSI);
   if(g_decisionLogHandle == INVALID_HANDLE)
   {
      Print("[DecisionLog] failed to open GoldDecisionLog.csv, error ", GetLastError());
      return false;
   }

   FileSeek(g_decisionLogHandle, 0, SEEK_END);

   if(FileSize(g_decisionLogHandle) == 0)
   {
      FileWriteString(g_decisionLogHandle,
         "timestamp" + "," +
         "symbol" + "," +
         "attempted_direction" + "," +
         "strategy_source" + "," +
         "onnx_prob_bull" + "," +
         "onnx_prob_bear" + "," +
         "onnx_margin" + "," +
         "onnx_predicted_class" + "," +
         "adx_value" + "," +
         "atr_value" + "," +
         "regime_mode" + "," +
         "ai_active" + "," +
         "ai_conviction" + "," +
         "ai_reason_text" + "," +
         "daily_bias_state" + "," +
         "result" + "," +
         "block_reason" + "," +
         "entry_price" + "," +
         "sl_price" + "," +
         "tp_price" + "," +
         "lot_size" + "," +
         "risk_usd" + "\r\n");
      FileFlush(g_decisionLogHandle);
   }

   return true;
}

//+------------------------------------------------------------------+
//| DecisionLogDeinit — flush and close the persistent handle once.  |
//+------------------------------------------------------------------+
void DecisionLogDeinit()
{
   PredictionLogDeinit();

   if(g_decisionLogHandle != INVALID_HANDLE)
   {
      FileFlush(g_decisionLogHandle);
      FileClose(g_decisionLogHandle);
      g_decisionLogHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| LogOnnxPrediction — append ONE row to the prediction log.        |
//+------------------------------------------------------------------+
void LogOnnxPrediction(double bull, double bear, double margin, string predClass, bool valid)
{
   if(g_predictionLogHandle == INVALID_HANDLE)
   {
      if(!PredictionLogInit())
         return;
   }

   string row =
      CsvQuote(TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS)) + "," +
      CsvQuote(_Symbol) + "," +
      DoubleToString(bull, 4) + "," +
      DoubleToString(bear, 4) + "," +
      DoubleToString(margin, 4) + "," +
      CsvQuote(predClass) + "," +
      (valid ? "true" : "false") + "\r\n";

   FileWriteString(g_predictionLogHandle, row);
   FileFlush(g_predictionLogHandle);
}

//+------------------------------------------------------------------+
//| LogTradeAttempt — append ONE fully-escaped CSV row to the log.   |
//| Uses the single persistent handle; flushes after every write.    |
//| Numeric fields are written bare (valid CSV); all text fields go  |
//| through CsvQuote() regardless of content.                        |
//+------------------------------------------------------------------+
void LogTradeAttempt(const SDecisionRecord &rec)
{
   if(g_decisionLogHandle == INVALID_HANDLE)
   {
      if(!DecisionLogInit())
         return;
   }

   // The dashboard's "last block" line reads this cache — updated
   // centrally here so every blocked attempt (any gate) is captured.
   if(rec.result == "BLOCKED")
   {
      g_lastBlockSource = rec.strategy_source;
      g_lastBlockReason = rec.block_reason;
   }

   string row =
      CsvQuote(rec.timestamp) + "," +
      CsvQuote(rec.symbol) + "," +
      CsvQuote(rec.direction) + "," +
      CsvQuote(rec.strategy_source) + "," +
      DoubleToString(rec.onnx_prob_bull, 4) + "," +
      DoubleToString(rec.onnx_prob_bear, 4) + "," +
      DoubleToString(rec.onnx_margin, 4) + "," +
      CsvQuote(rec.onnx_predicted_class) + "," +
      DoubleToString(rec.adx_value, 2) + "," +
      DoubleToString(rec.atr_value, 2) + "," +
      CsvQuote(rec.regime_mode) + "," +
      (rec.ai_active ? "true" : "false") + "," +
      IntegerToString(rec.ai_conviction) + "," +
      CsvQuote(rec.ai_reason_text) + "," +
      CsvQuote(rec.daily_bias_state) + "," +
      CsvQuote(rec.result) + "," +
      CsvQuote(rec.block_reason) + "," +
      (rec.entry_price > 0.0 ? DoubleToString(rec.entry_price, _Digits) : "") + "," +
      (rec.sl_price    > 0.0 ? DoubleToString(rec.sl_price,    _Digits) : "") + "," +
      (rec.tp_price    > 0.0 ? DoubleToString(rec.tp_price,    _Digits) : "") + "," +
      (rec.lot_size    > 0.0 ? DoubleToString(rec.lot_size,    2)      : "") + "," +
      (rec.risk_usd    > 0.0 ? DoubleToString(rec.risk_usd,    2)      : "") + "\r\n";

   FileWriteString(g_decisionLogHandle, row);
   FileFlush(g_decisionLogHandle);
}

#endif // GE_DECISIONLOG_MQH