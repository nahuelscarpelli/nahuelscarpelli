//+------------------------------------------------------------------+
//|                                              MathPatternEA.mq5   |
//|                          Copyright 2026, Nahuel Scarpelli        |
//|                    EA Matematico: Z-Score + Recuperacion Zonas    |
//+------------------------------------------------------------------+
//
//  LOGICA CENTRAL:
//  ===============
//  1. ENTRADA por Z-Score (desviacion estadistica del precio vs media).
//     No usa indicadores clasicos: pura estadistica.
//     - Z-Score <= -umbral  →  precio estadisticamente BAJO  →  BUY
//     - Z-Score >= +umbral  →  precio estadisticamente ALTO  →  SELL
//
//  2. RECUPERACION por zonas si la operacion pierde.
//     No es martingala (no duplica ciegamente). Calcula el lote exacto
//     para que UN movimiento de zona en la nueva direccion recupere
//     TODAS las perdidas + el target de ganancia.
//
//  3. CIERRE cuando el P&L neto del basket >= target profit.
//
//  4. SEGURIDAD: max capas, max drawdown %, limite diario de perdida.
//
//  REQUIERE: Cuenta HEDGING (necesita BUY y SELL simultaneos)
//  TIMEFRAME RECOMENDADO: M15
//
//+------------------------------------------------------------------+
#property copyright "Nahuel Scarpelli"
#property version   "1.00"
#property description "EA Matematico: Z-Score + Recuperacion por Zonas"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+
input group "══════ MOTOR ESTADISTICO ══════"
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;     // Timeframe de analisis
input int             InpZScorePeriod  = 100;            // Periodo Z-Score (barras)
input double          InpZScoreEntry   = 2.0;            // Umbral Z-Score para entrada
input int             InpATRPeriod     = 14;             // Periodo ATR

input group "══════ SISTEMA DE RECUPERACION ══════"
input double          InpBaseLot       = 0.01;           // Lote base
input int             InpMaxLayers     = 6;              // Capas maximas de recuperacion
input double          InpZoneATRMult   = 1.5;            // Distancia zona = ATR x este valor
input double          InpTargetProfit  = 3.0;            // Ganancia objetivo por ciclo (USD)

input group "══════ GESTION DE RIESGO ══════"
input double          InpMaxDrawdownPct = 30.0;          // Drawdown maximo % del balance
input double          InpDailyLossMax   = 50.0;          // Perdida diaria maxima (USD)
input int             InpMagicNumber    = 777777;        // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hSMA;
int    g_hATR;

// Cycle state
bool   g_cycleActive    = false;
int    g_layerCount     = 0;
double g_zoneSize       = 0;
double g_lastLayerPrice = 0;
int    g_lastLayerDir   = 0;       // +1 = BUY, -1 = SELL

// Daily tracking
double g_dailyLoss      = 0;
int    g_dailyDate      = 0;

// New bar tracking
datetime g_lastBarTime  = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Verify hedging account
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("MathPatternEA: Este EA requiere cuenta HEDGING.");
      return INIT_FAILED;
   }

   //--- Configure trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   AutoDetectFilling();

   //--- Create indicator handles
   g_hSMA = iMA(_Symbol, InpTimeframe, InpZScorePeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(g_hSMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Alert("MathPatternEA: Error creando indicadores.");
      return INIT_FAILED;
   }

   //--- Recover state if EA restarted with open positions
   double pl = 0;
   if(CountMyPositions(pl) > 0)
   {
      g_cycleActive = true;
      RecoverCycleState();
      Print(StringFormat("MathPatternEA: Estado recuperado - %d capas activas, P&L: %.2f",
            g_layerCount, pl));
   }

   Print("===================================================");
   Print("  Math Pattern EA v1.0 - Inicializado");
   Print(StringFormat("  Timeframe: %s | Z-Score: %d periodos, umbral ±%.1f",
         EnumToString(InpTimeframe), InpZScorePeriod, InpZScoreEntry));
   Print(StringFormat("  Lote base: %.2f | Max capas: %d | Target: $%.2f",
         InpBaseLot, InpMaxLayers, InpTargetProfit));
   Print(StringFormat("  Drawdown max: %.0f%% | Loss diario max: $%.0f",
         InpMaxDrawdownPct, InpDailyLossMax));
   Print("===================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hSMA != INVALID_HANDLE) IndicatorRelease(g_hSMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyIfNeeded();

   double netPL   = 0;
   int positions  = CountMyPositions(netPL);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   //=== SAFETY: Daily loss limit ===
   if(g_dailyLoss >= InpDailyLossMax)
   {
      if(positions > 0)
         CloseAllPositions("LIMITE DIARIO ALCANZADO: $" + DoubleToString(g_dailyLoss, 2));
      UpdateChartComment(netPL);
      return;
   }

   //=== SAFETY: Max drawdown per cycle ===
   if(positions > 0 && netPL < -(balance * InpMaxDrawdownPct / 100.0))
   {
      g_dailyLoss += MathAbs(netPL);
      CloseAllPositions(StringFormat("DRAWDOWN MAXIMO: %.2f USD (%.1f%%)",
                        netPL, (netPL / balance) * 100.0));
      UpdateChartComment(netPL);
      return;
   }

   //=== CYCLE ACTIVE: manage basket ===
   if(g_cycleActive && positions > 0)
   {
      // Target hit -> close all with profit
      if(netPL >= InpTargetProfit)
      {
         Print("===================================================");
         Print(StringFormat("  TARGET ALCANZADO! +%.2f USD en %d capas", netPL, g_layerCount));
         Print("===================================================");
         CloseAllPositions(StringFormat("TARGET: +%.2f USD", netPL));
         UpdateChartComment(netPL);
         return;
      }

      // Check if new recovery layer needed
      if(g_layerCount < InpMaxLayers && ShouldAddRecoveryLayer())
      {
         AddRecoveryLayer(netPL);
      }

      UpdateChartComment(netPL);
      return;
   }

   //=== Handle external close (user closed positions manually) ===
   if(g_cycleActive && positions == 0)
   {
      g_cycleActive = false;
      g_layerCount  = 0;
      Print("MathPatternEA: Ciclo terminado (posiciones cerradas externamente)");
   }

   //=== IDLE: Look for Z-Score entry on new bar ===
   if(!g_cycleActive)
   {
      datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
      if(currentBarTime == g_lastBarTime)
      {
         UpdateChartComment(0);
         return;
      }
      g_lastBarTime = currentBarTime;

      double zScore = CalcZScore();
      double atr    = GetATR();
      if(atr <= 0)
      {
         UpdateChartComment(0);
         return;
      }

      g_zoneSize = NormalizeDouble(atr * InpZoneATRMult, _Digits);

      int direction = 0;
      if(zScore <= -InpZScoreEntry)      direction = +1;   // Oversold  -> BUY
      else if(zScore >= InpZScoreEntry)  direction = -1;   // Overbought -> SELL

      if(direction != 0)
         OpenFirstLayer(direction, zScore);

      UpdateChartComment(0);
   }
}

//+------------------------------------------------------------------+
//|                  STATISTICAL ENGINE                                |
//+------------------------------------------------------------------+

//--- Calculate Z-Score: (Price - SMA) / StdDev
double CalcZScore()
{
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, InpTimeframe, 0, InpZScorePeriod, closes) < InpZScorePeriod)
      return 0;

   double sma[];
   ArraySetAsSeries(sma, true);
   if(CopyBuffer(g_hSMA, 0, 0, 1, sma) < 1)
      return 0;

   double mean  = sma[0];
   double sumSq = 0;
   for(int i = 0; i < InpZScorePeriod; i++)
      sumSq += (closes[i] - mean) * (closes[i] - mean);

   double stdDev = MathSqrt(sumSq / InpZScorePeriod);
   if(stdDev < _Point) return 0;

   return (closes[0] - mean) / stdDev;
}

//--- Get current ATR
double GetATR()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hATR, 0, 0, 1, atr) < 1)
      return 0;
   return atr[0];
}

//+------------------------------------------------------------------+
//|                  RECOVERY ENGINE                                   |
//+------------------------------------------------------------------+

//--- Open first layer (new cycle)
void OpenFirstLayer(int direction, double zScore)
{
   double price = (direction > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Margin check
   if(!HasEnoughMargin(direction, InpBaseLot, price))
   {
      Print("MathPatternEA: Margen insuficiente para abrir Layer 1");
      return;
   }

   string dirStr = (direction > 0) ? "BUY" : "SELL";

   Print("===================================================");
   Print(StringFormat("  NUEVO CICLO: %s %.2f @ %.5f", dirStr, InpBaseLot, price));
   Print(StringFormat("  Z-Score: %.2f | Zona: %.1f pts | ATR: %.5f",
         zScore, g_zoneSize / _Point, GetATR()));
   Print("===================================================");

   bool ok = false;
   if(direction > 0)
      ok = g_trade.Buy(InpBaseLot, _Symbol, price, 0, 0, "MathEA_L1");
   else
      ok = g_trade.Sell(InpBaseLot, _Symbol, price, 0, 0, "MathEA_L1");

   if(ok)
   {
      g_cycleActive    = true;
      g_layerCount     = 1;
      g_lastLayerPrice = price;
      g_lastLayerDir   = direction;
   }
   else
      Print("MathPatternEA: Error abriendo Layer 1 - code ", GetLastError());
}

//--- Check if price moved against last layer by one zone
bool ShouldAddRecoveryLayer()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_lastLayerDir > 0)       // Last was BUY -> price must DROP one zone
      return (g_lastLayerPrice - bid) >= g_zoneSize;
   else                          // Last was SELL -> price must RISE one zone
      return (bid - g_lastLayerPrice) >= g_zoneSize;
}

//--- Add recovery layer in opposite direction
void AddRecoveryLayer(double currentNetPL)
{
   int newDir = -g_lastLayerDir;
   double lot = CalcRecoveryLot(currentNetPL);

   double price = (newDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Margin check
   if(!HasEnoughMargin(newDir, lot, price))
   {
      Print(StringFormat("MathPatternEA: Margen insuficiente para Layer %d (%.2f lots)",
            g_layerCount + 1, lot));
      // Force close - can't recover without margin
      g_dailyLoss += MathAbs(currentNetPL);
      CloseAllPositions("SIN MARGEN PARA RECUPERACION");
      return;
   }

   g_layerCount++;
   string dirStr  = (newDir > 0) ? "BUY" : "SELL";
   string comment = StringFormat("MathEA_L%d", g_layerCount);

   Print(StringFormat("  >> CAPA %d: %s %.2f @ %.5f (Recuperando %.2f USD)",
         g_layerCount, dirStr, lot, price, currentNetPL));

   bool ok = false;
   if(newDir > 0)
      ok = g_trade.Buy(lot, _Symbol, price, 0, 0, comment);
   else
      ok = g_trade.Sell(lot, _Symbol, price, 0, 0, comment);

   if(ok)
   {
      g_lastLayerPrice = price;
      g_lastLayerDir   = newDir;
   }
   else
   {
      g_layerCount--;
      Print("MathPatternEA: Error abriendo recovery layer - code ", GetLastError());
   }
}

//--- Calculate exact lot to recover all losses + target in one zone move
//    Formula: lot = (|totalLoss| + targetProfit) / zoneValuePerLot
double CalcRecoveryLot(double totalNetPL)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0 || g_zoneSize <= 0)
      return InpBaseLot;

   // Dollar value of one zone movement for 1.0 lot
   double zoneValuePerLot = (g_zoneSize / tickSize) * tickValue;

   if(zoneValuePerLot <= 0)
      return InpBaseLot;

   double needed = (MathAbs(totalNetPL) + InpTargetProfit) / zoneValuePerLot;

   // Normalize to broker lot constraints
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   needed = MathCeil(needed / step) * step;   // Round UP to guarantee coverage
   needed = MathMax(needed, minL);
   needed = MathMin(needed, maxL);

   return NormalizeDouble(needed, 2);
}

//+------------------------------------------------------------------+
//|                  POSITION MANAGEMENT                               |
//+------------------------------------------------------------------+

//--- Count our positions and sum net P&L (profit + swap + commission)
int CountMyPositions(double &netPL)
{
   int count = 0;
   netPL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      netPL += PositionGetDouble(POSITION_PROFIT)
             + PositionGetDouble(POSITION_SWAP)
             + PositionGetDouble(POSITION_COMMISSION);
      count++;
   }
   return count;
}

//--- Close all EA positions and reset cycle
void CloseAllPositions(string reason)
{
   Print("=== CERRANDO TODO: ", reason, " ===");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      g_trade.PositionClose(ticket);
   }
   g_cycleActive = false;
   g_layerCount  = 0;
   Print("=== Ciclo reseteado. Esperando proxima senal... ===");
}

//--- Rebuild cycle state from existing positions (after restart)
void RecoverCycleState()
{
   g_layerCount = 0;
   datetime newestTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      g_layerCount++;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(openTime > newestTime)
      {
         newestTime       = openTime;
         g_lastLayerPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         g_lastLayerDir   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
      }
   }

   // Recalculate zone from current ATR
   double atr = GetATR();
   if(atr > 0)
      g_zoneSize = NormalizeDouble(atr * InpZoneATRMult, _Digits);
}

//+------------------------------------------------------------------+
//|                  UTILITIES                                         |
//+------------------------------------------------------------------+

//--- Auto-detect best filling mode for the symbol
void AutoDetectFilling()
{
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//--- Check if we have enough free margin (with 20% safety buffer)
bool HasEnoughMargin(int direction, double lot, double price)
{
   ENUM_ORDER_TYPE orderType = (direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double marginNeeded = 0;

   if(!OrderCalcMargin(orderType, _Symbol, lot, price, marginNeeded))
      return false;

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (marginNeeded < freeMargin * 0.80);
}

//--- Reset daily loss counter on new day
void ResetDailyIfNeeded()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int d = dt.year * 10000 + dt.mon * 100 + dt.day;
   if(d != g_dailyDate)
   {
      g_dailyLoss  = 0;
      g_dailyDate  = d;
   }
}

//--- Update chart comment with current status
void UpdateChartComment(double netPL)
{
   string stateStr;
   if(g_dailyLoss >= InpDailyLossMax)
      stateStr = "BLOQUEADO (limite diario)";
   else if(g_cycleActive)
      stateStr = StringFormat("ACTIVO | Capas: %d/%d | P&L: %.2f USD",
                              g_layerCount, InpMaxLayers, netPL);
   else
      stateStr = "ESPERANDO SENAL Z-SCORE";

   double zScore = CalcZScore();

   Comment(StringFormat(
      "\n"
      "  ========================================\n"
      "    MATH PATTERN EA v1.0\n"
      "  ========================================\n"
      "    Estado:     %s\n"
      "    Z-Score:    %.2f  (umbral: ±%.1f)\n"
      "    Zona:       %.1f pts\n"
      "    Loss diario: %.2f / %.2f USD\n"
      "    Balance:    %.2f USD\n"
      "  ========================================\n",
      stateStr,
      zScore, InpZScoreEntry,
      g_zoneSize / _Point,
      g_dailyLoss, InpDailyLossMax,
      AccountInfoDouble(ACCOUNT_BALANCE)
   ));
}
//+------------------------------------------------------------------+
