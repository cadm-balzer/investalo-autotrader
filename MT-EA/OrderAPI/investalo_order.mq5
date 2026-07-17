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



input int      InpPartialClosePct= 50;                             // Teilschließung Fallback (%) wenn Signal kein qty_pct liefert



input bool     InpEnforcePartialLotCheck = true;                    // Entry nur erlauben, wenn spätere Teilschließung lot-technisch möglich ist







input group "--- SYMBOL MAPPING (TradingView -> Broker) ---"



// Format: "TV1=BROKER1,TV2=BROKER2"  (z.B. "US500=US500.cash,NAS100=NAS100.cash,GER40=DE40.cash")



// Leer lassen, wenn die Symbole bei Broker und TradingView identisch sind.



input string   InpSymbolMap      = "SP500=US500.cash,SPX=US500.cash,NAS100=NAS100.cash,BTCUSDT.P=BTCUSD";



input string   InpSymbolSuffix   = "";                              // Optional: Suffix an ALLE Symbole anhängen (z.B. ".cash")







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



      string signalId  = signal["signal_id"].ToStr();



      string action    = signal["payload"]["action"].ToStr();



      string tvSymbol  = signal["payload"]["symbol"].ToStr();



      string symbol    = MapSymbol(tvSymbol);



      double price     = signal["payload"]["price"].ToDbl();



      double sl        = signal["payload"]["sl"].ToDbl();



      double tp1       = signal["payload"]["tp1"].ToDbl();



      double tp2       = signal["payload"]["tp2"].ToDbl();



      int    qtyPct    = (int)signal["payload"]["qty_pct"].ToInt();



      bool   beFlag    = signal["payload"]["breakeven"].ToBool();



      



      if(symbol != tvSymbol)



         PrintFormat("Symbol-Mapping: %s -> %s", tvSymbol, symbol);



      Print("Signal empfangen! ID: ", signalId, " | Action: ", action, " | Asset: ", symbol);



      



      // Signal an die Order-Execution übergeben



      bool success = ProcessTrade(action, symbol, price, sl, tp1, tp2, qtyPct, beFlag);



      



      // Quittung (Ack) an API senden



      SendAcknowledgment(signalId, success);



   }



}







//+------------------------------------------------------------------+



//| Berechnet das Risiko und führt die Order über CTrade aus         |



//+------------------------------------------------------------------+



bool ProcessTrade(string action, string symbol, double price, double sl, double tp1, double tp2, int qtyPct, bool breakeven)



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







   if(action == "PARTIAL_CLOSE")



   {



      // qty_pct aus dem Signal nutzen (1..99), sonst Fallback aus dem Input



      int pct = (qtyPct >= 1 && qtyPct <= 99) ? qtyPct : (int)InpPartialClosePct;



      bool ok = PartialClosePositions(symbol, pct);



      if(ok && breakeven) MoveToBreakeven(symbol);



      return ok;



   }







   // 2. NEUE TRADES (Market & Limit)



   bool isBuy   = (action == "BUY"  || action == "BUY_LIMIT");



   bool isSell  = (action == "SELL" || action == "SELL_LIMIT");



   bool isEntry = isBuy || isSell;



   string side  = isBuy ? "BUY" : "SELL";



   // Bei Multi-Target-Strategien ist tp1 oft nur das Teilziel.

   // Deshalb setzen wir brokerseitig bevorzugt tp2, falls vorhanden.

   double orderTp = (tp2 > 0.0) ? tp2 : tp1;







   double lotSize = 0.0;



   if(isEntry)



   {



      if(sl <= 0)



      {



         Print("Fehler: Für risiko-basierte Lots wird ein valider SL-Preis benötigt.");



         return false;



      }



      lotSize = CalculateLotSize(symbol, side, sl);



      if(lotSize <= 0) return false;







      // Multi-Target-Setups mit TP2 implizieren spätere Teilschließung.



      if(tp2 > 0.0 && InpEnforcePartialLotCheck)



      {



         if(!CanSupportPartialClose(symbol, lotSize, (int)InpPartialClosePct))



         {



            Print("Entry abgelehnt: Lotgröße unterstützt keine spätere Teilschließung. Symbol=", symbol,



                  " Lot=", DoubleToString(lotSize, 2), " PartialPct=", InpPartialClosePct);



            return false;



         }



      }



   }







   // Order-Platzierung – strikt: BUY/SELL = Market JETZT, *_LIMIT = pending



   if(action == "BUY")



   {



      double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);



      return trade.Buy(lotSize, symbol, currentAsk, sl, orderTp);



   }



   else if(action == "BUY_LIMIT")



   {



      return trade.BuyLimit(lotSize, price, symbol, sl, orderTp, ORDER_TIME_DAY);



   }



   else if(action == "SELL")



   {



      double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);



      return trade.Sell(lotSize, symbol, currentBid, sl, orderTp);



   }



   else if(action == "SELL_LIMIT")



   {



      return trade.SellLimit(lotSize, price, symbol, sl, orderTp, ORDER_TIME_DAY);



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



//| Prüft, ob für eine gegebene Lotgröße später sinnvoll teilweise   |



//| geschlossen werden kann, ohne unter MinLot zu fallen.           |



//+------------------------------------------------------------------+



bool CanSupportPartialClose(string symbol, double volume, int pct)



{



   if(pct < 1)  pct = 1;



   if(pct > 99) pct = 99;







   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);



   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);



   if(step <= 0) step = 0.01;







   double requestedCloseVol = MathFloor((volume * pct / 100.0) / step) * step;



   double maxCloseVol = MathFloor((MathMax(0.0, volume - minVol)) / step) * step;







   if(requestedCloseVol < minVol && maxCloseVol >= minVol)



      requestedCloseVol = minVol;







   return requestedCloseVol >= minVol && requestedCloseVol <= maxCloseVol;



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



//| Schließt einen prozentualen Anteil aller Positionen des Symbols  |



//| pct = 1..99. Volumen wird auf Lot-Step abgerundet.                |



//+------------------------------------------------------------------+



bool PartialClosePositions(string symbol, int pct)



{



   if(pct < 1)  pct = 1;



   if(pct > 99) pct = 99;







   double step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);



   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);



   if(step <= 0) step = 0.01;







   bool anyClosed = false;

   bool anyMatched = false;



   for(int i = PositionsTotal() - 1; i >= 0; i--)



   {



      if(PositionGetSymbol(i) != symbol) continue;

      anyMatched = true;







      ulong  ticket = PositionGetInteger(POSITION_TICKET);



      double volume = PositionGetDouble(POSITION_VOLUME);







      // Gewünschtes Teilvolumen auf Lot-Step abrunden.



      double requestedCloseVol = MathFloor((volume * pct / 100.0) / step) * step;







      // Maximal schließbares Volumen, sodass immer ein sinnvoller Rest offen bleibt.

      // Falls der Broker MinLot=0 meldet, behalten wir mindestens 1 Lot-Step offen,

      // damit PARTIAL_CLOSE nie implizit zur Vollschließung wird.

      double minRemainVol = (minVol > 0.0) ? minVol : step;

      double maxCloseVol = MathFloor((MathMax(0.0, volume - minRemainVol)) / step) * step;







      // Wenn die Prozentrechnung unter MinLot fällt, schließen wir best effort MinLot,



      // aber nur dann, wenn danach noch mindestens MinLot offen bleibt.



      double closeVol = requestedCloseVol;



      if(closeVol < minVol && maxCloseVol >= minVol)



         closeVol = minVol;







      // Nie mehr schließen als zulässig, wenn die Position teilweise offen bleiben soll.



      if(closeVol > maxCloseVol)



         closeVol = maxCloseVol;







      if(closeVol < minVol)



      {

         Print("Teilschließung nicht möglich: Volume=", DoubleToString(volume, 4),

            " MinLot=", DoubleToString(minVol, 4),

            " Step=", DoubleToString(step, 4),

            " Ticket ", ticket);



         continue;



      }







      bool ok = trade.PositionClosePartial(ticket, closeVol);



      if(ok)



      {

         anyClosed = true;

         Print("Teilschließung OK: ", DoubleToString(closeVol, 2), " von ",

               DoubleToString(volume, 2), " Lot (Ticket ", ticket, ", ", pct, "%)",

               " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());

      }



      else



      {

         Print("Teilschließung fehlgeschlagen Ticket ", ticket,

               " closeVol=", DoubleToString(closeVol, 4),

               " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());



      }



   }



   if(!anyMatched)

   {

      Print("Teilschließung: keine offene Position für Symbol ", symbol);

      return false;

   }



   return anyClosed;



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

         double currentTP = PositionGetDouble(POSITION_TP);



         



         // Nur modifizieren, wenn der SL nicht bereits auf oder hinter Breakeven liegt



         if(MathAbs(currentSL - openPrice) > (_Point * 0.1))



         {



            if(!trade.PositionModify(ticket, openPrice, currentTP))



            {



               allMoved = false;



               Print("Breakeven-Modifikation fehlgeschlagen für Ticket: ", ticket,

                     " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());



            }

            else

            {

               Print("Breakeven gesetzt für Ticket ", ticket,

                     " newSL=", DoubleToString(openPrice, _Digits),

                     " retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());



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



   



   string jsonPost = ackBody.Serialize();



   char post[], result[];



   string result_headers;



   



   // WICHTIG: Länge des JSON-Strings, OHNE das von StringToCharArray angehängte



   // Null-Byte. Sonst erhält FastAPI ein '\0' im Body und antwortet mit 422.



   int len = StringToCharArray(jsonPost, post, 0, StringLen(jsonPost), CP_UTF8);



   ArrayResize(post, StringLen(jsonPost));



   



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







//+------------------------------------------------------------------+



//| Mappt ein TradingView-Symbol auf den Broker-Namen                |



//| Reihenfolge: 1) explizites Mapping aus InpSymbolMap              |



//|              2) Suffix aus InpSymbolSuffix anhängen, wenn nötig  |



//|              3) unverändert zurückgeben                          |



//+------------------------------------------------------------------+



string MapSymbol(string tvSymbol)



{



   string src = tvSymbol;



   StringTrimLeft(src);



   StringTrimRight(src);







   // 1) explizites Mapping "TV=BROKER,TV2=BROKER2"



   if(StringLen(InpSymbolMap) > 0)



   {



      string pairs[];



      int n = StringSplit(InpSymbolMap, ',', pairs);



      for(int i = 0; i < n; i++)



      {



         string pair = pairs[i];



         StringTrimLeft(pair);



         StringTrimRight(pair);



         if(StringLen(pair) == 0) continue;







         string kv[];



         if(StringSplit(pair, '=', kv) != 2) continue;



         StringTrimLeft(kv[0]); StringTrimRight(kv[0]);



         StringTrimLeft(kv[1]); StringTrimRight(kv[1]);







         if(StringCompare(kv[0], src, false) == 0)



            return kv[1];



      }



   }







   // 2) globaler Suffix (nur anhängen, falls nicht bereits enthalten)



   if(StringLen(InpSymbolSuffix) > 0 && StringFind(src, InpSymbolSuffix) < 0)



      return src + InpSymbolSuffix;







   // 3) unverändert



   return src;



}