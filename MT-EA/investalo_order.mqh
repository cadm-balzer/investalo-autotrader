//+------------------------------------------------------------------+
//|                                        Investalo_Autotrader.mq5  |
//|                                  Copyright 2026, investalo.de    |
//|                                      https://www.investalo.de    |
//+------------------------------------------------------------------+
#property copyright "investalo.de"
#property link      "https://www.investalo.de"
#property version   "1.00"
#property strict

// Include für JSON-Parsing (JAson.mqh muss im Include-Ordner liegen)
#include <JAson.mqh>
#include <Trade\Trade.mqh>

//--- Inlines & Trade-Instanz
CTrade trade;

//--- INPUT PARAMETERS ---
input group "--- API GATEWAY CONFIG ---"
input string   InpApiUrl         = "https://orderapi.investalo.de"; // API Basis-URL (Ohne Slash am Ende)
input string   InpApiKey         = "DEIN_GEHEIMER_UUID_TOKEN";       // X-API-KEY (Dein Krypto-Token)
input int      InpPollingInterval= 200;                             // Polling Intervall (in Millisekunden)

input group "--- RISK Engine ---"
input double   InpRiskPercent    = 0.5;                             // Risiko pro Trade (%) vom Kontostand
input double   InpMaxLotSize     = 10.0;                            // Maximal erlaubte Lot-Größe

//--- Globale Variablen ---
ulong  PollingTimerID;
string TypeToClose = "";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Verbindungstyp für CTrade auf Market Execution oder Instant setzen (brokerabhängig)
   trade.SetExpertMagicNumber(133723); // Eigene MagicNumber zur Identifikation
   trade.SetDeviationInPoints(30);     // Max. Slippage in Punkten
   
   // Timer für das schnelle Polling starten
   EventSetMillisecondTimer(InpPollingInterval);
   Print("Investalo Autotrader gestartet. Polling läuft alle ", InpPollingInterval, " ms.");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("Investalo Autotrader gestoppt.");
}

//+------------------------------------------------------------------+
//| Timer function - Hier schlägt das Herz des Pollings             |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Timer kurz anhalten, um Überlappungen bei langsamen Netzwerk-Requests zu verhindern
   EventKillTimer();
   
   FetchAndExecuteSignals();
   
   // Timer wieder aktivieren
   EventSetMillisecondTimer(InpPollingInterval);
}

//+------------------------------------------------------------------+
//| Holt ausstehende Signale von der FastAPI und verarbeitet sie     |
//+------------------------------------------------------------------+
void FetchAndExecuteSignals()
{
   string url = InpApiUrl + "/v1/signals/poll";
   string headers = "X-API-KEY: " + InpApiKey + "\r\n";
   char post[], result[];
   string result_headers;
   
   // HTTP GET Request an die API senden
   int res = WebRequest("GET", url, headers, 500, post, result, result_headers);
   
   if(res == -1)
   {
      int err = _LastError;
      if(err != 4014) // 4014 bedeutet "URL nicht erlaubt" -> Muss in MT5 Optionen eingetragen werden
         Print("API WebRequest fehlgeschlagen. Fehler-Code: ", err);
      else
         Print("FEHLER: URL '", InpApiUrl, "' ist nicht im MT5 freigegeben! Bitte unter Optionen -> Experten hinzufügen.");
      return;
   }
   
   if(res == 200)
   {
      string jsonResponse = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      
      // Wenn das Array leer ist "[]", gibt es keine neuen Signale
      if(jsonResponse == "[]" || jsonResponse == "") return;
      
      CJAVal jsonRoot;
      if(!jsonRoot.Deserialize(jsonResponse))
      {
         Print("Fehler beim Deserialisieren der JSON-Antwort: ", jsonResponse);
         return;
      }
      
      // Da die API ein Array zurückgibt, holen wir uns das erste Element (Index 0)
      CJAVal signal = jsonRoot[0];
      string signalId = signal["signal_id"].ToStr();
      string action   = signal["payload"]["action"].ToStr();
      string symbol   = signal["payload"]["symbol"].ToStr();
      double price    = signal["payload"]["price"].ToDbl();
      double sl       = signal["payload"]["sl"].ToDbl();
      double tp1      = signal["payload"]["tp1"].ToDbl();
      double tp2      = signal["payload"]["tp2"].ToDbl();
      int    qtyPct   = (int)signal["payload"]["qty_pct"].ToInt();
      
      Print("Signal empfangen! ID: ", signalId, " | Action: ", action, " | Asset: ", symbol);
      
      // Signal an die Order-Execution übergeben
      bool success = ProcessTrade(action, symbol, price, sl, tp1, tp2, qtyPct);
      
      // Quittung (Ack) an API senden
      SendAcknowledgment(signalId, success);
   }
}

//+------------------------------------------------------------------+
//| Berechnet das Risiko und führt die Order über CTrade aus         |
//+------------------------------------------------------------------+
bool ProcessTrade(string action, string symbol, double price, double sl, double tp1, double tp2, int qtyPct)
{
   // Prüfen, ob das Asset im Market Watch Fenster existiert und geladen ist
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT))
   {
      if(!SymbolSelect(symbol, true))
      {
         Print("Fehler: Symbol ", symbol, " existiert nicht oder kann nicht ausgewählt werden.");
         return false;
      }
   }

   // 1. HARD EXITS (CLOSE ALL & PARTIALS)
   if(action == "CLOSE_ALL")
   {
      return CloseAllPositionsForSymbol(symbol);
   }
   
   if(action == "BREAKEVEN")
   {
      return MoveToBreakeven(symbol);
   }

   // 2. NEUE TRADES (BUY / SELL)
   double lotSize = 0.0;
   
   if(action == "BUY" || action == "SELL")
   {
      if(sl <= 0)
      {
         Print("Fehler: Für risiko-basierte Lots wird ein valider SL-Preis benötigt.");
         return false;
      }
      
      // Dynamische Lot-Berechnung anhand des Kontostands (Equity) und des SL-Abstands
      lotSize = CalculateLotSize(symbol, action, sl);
      if(lotSize <= 0) return false;
   }
   
   // Order-Platzierung
   if(action == "BUY")
   {
      // Da wir Limit-Orders nutzen: Wenn TV-Preis unter dem aktuellen Ask liegt -> Limit Order, sonst Market
      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(price < currentAsk)
         return trade.BuyLimit(lotSize, price, symbol, sl, tp1, ORDER_TIME_DAY);
      else
         return trade.Buy(lotSize, symbol, currentAsk, sl, tp1);
   }
   else if(action == "SELL")
   {
      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(price > currentBid)
         return trade.SellLimit(lotSize, price, symbol, sl, tp1, ORDER_TIME_DAY);
      else
         return trade.Sell(lotSize, symbol, currentBid, sl, tp1);
   }
   
   Print("Aktion '", action, "' wird aktuell nicht unterstützt.");
   return false;
}

//+------------------------------------------------------------------+
//| Präzise Lot-Berechnung basierend auf dem prozentualen Risiko     |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, string action, double slPrice)
{
   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount    = accountEquity * (InpRiskPercent / 100.0);
   
   double entryPrice = (action == "BUY") ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minLot     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   
   if(tickSize <= 0 || tickValue <= 0) return 0.0;
   
   // Abstand in Punkten berechnen
   double pointsDistance = MathAbs(entryPrice - slPrice);
   
   // Lot-Berechnung über Tick-Value-Formel
   double lot = riskAmount / ((pointsDistance / tickSize) * tickValue);
   
   // Runden auf den nächsten erlaubten Lot-Schritt (Lot Step)
   lot = MathRound(lot / lotStep) * lotStep;
   
   // Validierung gegen Broker-Grenzen
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(lot > InpMaxLotSize) lot = InpMaxLotSize;
   
   return lot;
}

//+------------------------------------------------------------------+
//| Schließt alle offenen Positionen eines bestimmten Assets         |
//+------------------------------------------------------------------+
bool CloseAllPositionsForSymbol(string symbol)
{
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol)
      {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         if(!trade.PositionClose(ticket))
         {
            allClosed = false;
            Print("Fehler beim Schließen des Tickets: ", ticket);
         }
      }
   }
   return allClosed;
}

//+------------------------------------------------------------------+
//| Zieht den Stop-Loss für alle Positionen des Assets auf Breakeven  |
//+------------------------------------------------------------------+
bool MoveToBreakeven(string symbol)
{
   bool allMoved = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol)
      {
         ulong ticket     = PositionGetInteger(POSITION_TICKET);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         
         // Nur modifizieren, wenn der SL nicht bereits auf oder hinter Breakeven liegt
         if(currentSL != openPrice)
         {
            if(!trade.PositionModify(ticket, openPrice, PositionGetDouble(POSITION_TP)))
            {
               allMoved = false;
               Print("Breakeven-Modifikation fehlgeschlagen für Ticket: ", ticket);
            }
         }
      }
   }
   return allMoved;
}

//+------------------------------------------------------------------+
//| Sendet das Ausführungsergebnis (Quittung) zurück an die API       |
//+------------------------------------------------------------------+
void SendAcknowledgment(string signalId, bool success)
{
   string url = InpApiUrl + "/v1/signals/" + signalId + "/ack";
   string headers = "X-API-KEY: " + InpApiKey + "\r\nContent-Type: application/json\r\n";
   
   CJAVal ackBody;
   ackBody["success"] = success;
   if(!success) ackBody["error_message"] = "Execution failed inside MT5 terminal.";
   else ackBody["error_message"] = "";
   
   string jsonPost = ackBody.Serialize();
   char post[], result[];
   string result_headers;
   
   StringToCharArray(jsonPost, post, 0, WHOLE_ARRAY, CP_UTF8);
   
   int res = WebRequest("POST", url, headers, 500, post, result, result_headers);
   if(res == 200)
   {
      Print("Quittung erfolgreich an API gesendet für Signal ID: ", signalId);
   }
   else
   {
      Print("Fehler beim Senden der Quittung an API. HTTP-Code: ", res);
   }
}