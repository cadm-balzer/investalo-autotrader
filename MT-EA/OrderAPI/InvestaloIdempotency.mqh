// Persistenter Ausführungsnachweis pro Konto/Signal. Keine Retry-Order bei Unklarheit.
#ifndef INVESTALO_IDEMPOTENCY_MQH
#define INVESTALO_IDEMPOTENCY_MQH

int HexNibble(ushort c)
{
   if(c >= '0' && c <= '9') return (int)c - '0';
   if(c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
   if(c >= 'A' && c <= 'F') return (int)c - 'A' + 10;
   return -1;
}

string SignalComment(string id)
{
   if(StringLen(id)!=36 || StringGetCharacter(id,8)!='-' ||
      StringGetCharacter(id,13)!='-' || StringGetCharacter(id,18)!='-' ||
      StringGetCharacter(id,23)!='-') return "";
   StringReplace(id,"-","");
   if(StringLen(id)!=32) return "";
   uchar bytes[16];
   for(int i=0;i<16;i++)
   {
      int a=HexNibble(StringGetCharacter(id,2*i));
      int b=HexNibble(StringGetCharacter(id,2*i+1));
      if(a<0 || b<0) return "";
      bytes[i]=(uchar)(a*16+b);
   }
   string chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
   string out="iv:";
   uint bits=0; int available=0;
   for(int i=0;i<16;i++)
   {
      bits=(bits<<8)|bytes[i]; available+=8;
      while(available>=6)
      {
         available-=6;
         out+=StringSubstr(chars,(int)((bits>>available)&63),1);
      }
   }
   if(available>0) out+=StringSubstr(chars,(int)((bits<<(6-available))&63),1);
   return out;
}

string ExecutionAccountHash()
{
   string identity=AccountInfoString(ACCOUNT_SERVER)+":"+(string)AccountInfoInteger(ACCOUNT_LOGIN);
   uchar data[],key[],hash[];
   int n=StringToCharArray(identity,data,0,WHOLE_ARRAY,CP_UTF8);
   ArrayResize(data,n-1);
   if(CryptEncode(CRYPT_HASH_SHA256,data,key,hash)!=32) return "";
   string out="";
   for(int i=0;i<ArraySize(hash);i++) out+=StringFormat("%02x",hash[i]);
   return out;
}

bool BrokerAccepted()
{
   uint code=trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_DONE_PARTIAL ||
          code==TRADE_RETCODE_PLACED || code==TRADE_RETCODE_NO_CHANGES;
}

int ExecutionEvidence(const string tag)
{
   for(int i=0;i<PositionsTotal();i++)
      if(PositionGetTicket(i)>0 && PositionGetInteger(POSITION_MAGIC)==133723 &&
         PositionGetString(POSITION_COMMENT)==tag) return 1;
   for(int i=0;i<OrdersTotal();i++)
      if(OrderGetTicket(i)>0 && OrderGetInteger(ORDER_MAGIC)==133723 &&
         OrderGetString(ORDER_COMMENT)==tag) return 1;
   if(!HistorySelect(0,TimeCurrent())) return -1;
   for(int i=0;i<HistoryDealsTotal();i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket>0 && HistoryDealGetInteger(ticket,DEAL_MAGIC)==133723 &&
         HistoryDealGetString(ticket,DEAL_COMMENT)==tag) return 1;
   }
   for(int i=0;i<HistoryOrdersTotal();i++)
   {
      ulong ticket=HistoryOrderGetTicket(i);
      if(ticket>0 && HistoryOrderGetInteger(ticket,ORDER_MAGIC)==133723 &&
         HistoryOrderGetString(ticket,ORDER_COMMENT)==tag &&
         HistoryOrderGetInteger(ticket,ORDER_STATE)!=ORDER_STATE_REJECTED) return 1;
   }
   return 0;
}

bool WriteExecutionState(int file,const string state)
{
   FileSeek(file,0,SEEK_SET);
   uint written=FileWriteString(file,state+"\n");
   FileFlush(file);
   return written>0;
}

bool ProcessTrade(string action,string symbol,double price,double sl,double tp1,double tp2,
                  int qtyPct,bool breakeven,string signalComment);

bool ExecuteOnce(string id,string action,string symbol,double price,double sl,double tp1,
                 double tp2,int qtyPct,bool breakeven,bool &success)
{
   success=false;
   string tag=SignalComment(id), account=ExecutionAccountHash();
   if(tag=="" || account=="") { Print("Ungültige Signal-/Konto-ID"); return true; }
   string folder="InvestaloExecution\\"+account;
   FolderCreate("InvestaloExecution",FILE_COMMON);
   FolderCreate(folder,FILE_COMMON);
   // Kein FILE_SHARE_*: auch mehrere Terminals auf demselben Host werden serialisiert.
   int file=FileOpen(folder+"\\"+StringSubstr(tag,3)+".state",
                     FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(file==INVALID_HANDLE) { Print("Ausführungsjournal gesperrt/nicht schreibbar"); return false; }
   string state=FileSize(file)>0 ? FileReadString(file) : "";
   if(state=="done") { success=true; FileClose(file); return true; }
   bool entry=(action=="BUY" || action=="SELL" || action=="BUY_LIMIT" || action=="SELL_LIMIT");
   int evidence=entry ? ExecutionEvidence(tag) : 0;
   if(evidence==1)
   {
      success=true;
      bool saved=WriteExecutionState(file,"done");
      FileClose(file);
      return saved;
   }
   if(evidence<0 || state!="" || !TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("Signal ",id,": Ausführung ungeklärt/History offline; keine erneute Order.");
      FileClose(file); return false;
   }
   // Vor jeder Nebenwirkung dauerhaft markieren. Crash danach -> niemals blind wiederholen.
   if(!WriteExecutionState(file,"pending")) { FileClose(file); return false; }
   success=ProcessTrade(action,symbol,price,sl,tp1,tp2,qtyPct,breakeven,tag);
   if(success && !WriteExecutionState(file,"done")) success=false;
   FileClose(file);
   if(!success)
   {
      Print("Signal ",id,": keine sichere Ausführungsbestätigung; Journal bleibt pending.");
      return false;
   }
   return true;
}
#endif
