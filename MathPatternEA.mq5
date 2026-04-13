//+------------------------------------------------------------------+
//|                                              MathPatternEA.mq5   |
//|                          Copyright 2026, Nahuel Scarpelli        |
//|                    EA Matematico: Z-Score + Recuperacion Zonas    |
//+------------------------------------------------------------------+
//
//  LOGICA CENTRAL v2:
//  ==================
//  1. ENTRADA por Z-Score CROSSBACK: no entra cuando el precio es extremo
//     (puede ser tendencia), sino cuando ERA extremo y ESTA VOLVIENDO.
//     Confirma que la reversion a la media ya comenzo.
//
//  2. FILTROS: sesion London+NY, pendiente de SMA (anti-tendencia).
//
//  3. RECUPERACION por zonas (2 zonas para recuperar, no 1).
//     Calcula lote exacto para que 2 movimientos de zona en la nueva
//     direccion recuperen TODAS las perdidas + target.
//     Menos presion de margen que v1.
//
//  4. CIERRE cuando el P&L neto del basket >= target profit.
//
//  5. SEGURIDAD: max capas, max drawdown %, limite diario, cooldown.
//
//  REQUIERE: Cuenta HEDGING (necesita BUY y SELL simultaneos)
//  TIMEFRAME RECOMENDADO: M15
//
//+------------------------------------------------------------------+
#property copyright "Nahuel Scarpelli"
#property version   "2.00"
#property description "EA Matematico v2: Z-Score Crossback + Recuperacion Zonas"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+
input group "══════ MOTOR ESTADISTICO ══════"
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;     // Timeframe de analisis
input int             InpZScorePeriod  = 100;            // Periodo Z-Score (barras)
input double          InpZScoreEntry   = 2.5;            // Umbral Z-Score para entrada (v1=2.0)
input int             InpATRPeriod     = 14;             // Periodo ATR

input group "══════ FILTROS ══════"
input int             InpSessionStart  = 7;              // Hora inicio sesion (servidor)
input int             InpSessionEnd    = 20;             // Hora fin sesion (servidor)
input double          InpMaxSMASlope   = 0.0004;         // Pendiente max SMA (filtro tendencia)
input int             InpCooldownBars  = 10;             // Barras de espera tras ciclo perdedor

input group "══════ SISTEMA DE RECUPERACION ══════"
input double          InpBaseLot       = 0.01;           // Lote base
input int             InpMaxLayers     = 5;              // Capas maximas (v1=6)
input double          InpZoneATRMult   = 2.0;            // Distancia zona = ATR x este valor (v1=1.5)
input double          InpTargetProfit  = 5.0;            // Ganancia objetivo por ciclo USD (v1=3.0)
input int             InpRecoveryZones = 2;              // Zonas para recuperar (v1=1, menos lote)

input group "══════ GESTION DE RIESGO ══════"
input double          InpMaxDrawdownPct = 30.0;          // Drawdown maximo % del balance
input double          InpDailyLossMax   = 30.0;          // Perdida diaria maxima USD (v1=50)
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

// Cooldown after losing cycle
int    g_cooldownLeft   = 0;

// Previous bar Z-Score (for crossback detection)
double g_prevZScore     = 0;

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
   Print("  Math Pattern EA v2.0 - Inicializado");
   Print(StringFormat("  Timeframe: %s | Z-Score: %d periodos, umbral ±%.1f",
         EnumToString(InpTimeframe), InpZScorePeriod, InpZScoreEntry));
   Print(StringFormat("  Sesion: %02d:00-%02d:00 | Cooldown: %d barras",
         InpSessionStart, InpSessionEnd, InpCooldownBars));
   Print(StringFormat("  Lote base: %.2f | Max capas: %d | Target: $%.2f | RecZones: %d",
         InpBaseLot, InpMaxLayers, InpTargetProfit, InpRecoveryZones));
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
      g_cooldownLeft = InpCooldownBars;
      CloseAllPositions(StringFormat("DRAWDOWN MAXIMO: %.2f USD (%.1f%%) - Cooldown %d barras",
                        netPL, (netPL / balance) * 100.0, InpCooldownBars));
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

   //=== IDLE: Look for Z-Score CROSSBACK entry on new bar ===
   if(!g_cycleActive)
   {
      datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
      if(currentBarTime == g_lastBarTime)
      {
         UpdateChartComment(0);
         return;
      }
      g_lastBarTime = currentBarTime;

      //--- Cooldown check
      if(g_cooldownLeft > 0)
      {
         g_cooldownLeft--;
         g_prevZScore = CalcZScore();
         UpdateChartComment(0);
         return;
      }

      //--- Session filter
      if(!IsWithinSession())
      {
         g_prevZScore = CalcZScore();
         UpdateChartComment(0);
         return;
      }

      double zScore = CalcZScore();
      double atr    = GetATR();
      if(atr <= 0)
      {
         g_prevZScore = zScore;
         UpdateChartComment(0);
         return;
      }

      //--- Trend filter: skip if SMA slope is too steep
      if(IsTrending())
      {
         g_prevZScore = zScore;
         UpdateChartComment(0);
         return;
      }

      g_zoneSize = NormalizeDouble(atr * InpZoneATRMult, _Digits);

      //--- Z-Score CROSSBACK: was extreme, now returning toward zero
      int direction = 0;

      // BUY: previous bar was below -threshold, current crossed back above it
      if(g_prevZScore <= -InpZScoreEntry && zScore > -InpZScoreEntry)
         direction = +1;
      // SELL: previous bar was above +threshold, current crossed back below it
      else if(g_prevZScore >= InpZScoreEntry && zScore < InpZScoreEntry)
         direction = -1;

      g_prevZScore = zScore;

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
      g_cooldownLeft = InpCooldownBars;
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

//--- Calculate lot to recover losses + target over InpRecoveryZones zone moves
//    Formula: lot = (|totalLoss| + targetProfit) / (zoneValuePerLot * recoveryZones)
//    v2: spreads recovery over multiple zones = smaller lots = less margin pressure
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

   // Spread recovery over multiple zones (less aggressive lot sizing)
   double needed = (MathAbs(totalNetPL) + InpTargetProfit) / (zoneValuePerLot * InpRecoveryZones);

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
//|                  FILTERS                                           |
//+------------------------------------------------------------------+

//--- Check if current time is within allowed trading session
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(InpSessionStart < InpSessionEnd)
      return (hour >= InpSessionStart && hour < InpSessionEnd);
   else  // Wraps midnight
      return (hour >= InpSessionStart || hour < InpSessionEnd);
}

//--- Check if market is trending (SMA slope too steep)
bool IsTrending()
{
   double sma[];
   ArraySetAsSeries(sma, true);
   if(CopyBuffer(g_hSMA, 0, 0, 3, sma) < 3)
      return false;

   // Slope = (SMA[0] - SMA[2]) / 2  (normalized over 2 bars)
   double slope = MathAbs(sma[0] - sma[2]) / 2.0;
   return (slope > InpMaxSMASlope);
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

   string cooldownStr = (g_cooldownLeft > 0) ? StringFormat(" | Cooldown: %d", g_cooldownLeft) : "";
   string sessionStr = IsWithinSession() ? "SI" : "NO";

   Comment(StringFormat(
      "\n"
      "  ========================================\n"
      "    MATH PATTERN EA v2.0\n"
      "  ========================================\n"
      "    Estado:     %s%s\n"
      "    Z-Score:    %.2f  (umbral: ±%.1f)\n"
      "    Prev Z:     %.2f\n"
      "    Zona:       %.1f pts | RecZones: %d\n"
      "    Sesion:     %s (%02d-%02d)\n"
      "    Loss diario: %.2f / %.2f USD\n"
      "    Balance:    %.2f USD\n"
      "  ========================================\n",
      stateStr, cooldownStr,
      zScore, InpZScoreEntry,
      g_prevZScore,
      g_zoneSize / _Point, InpRecoveryZones,
      sessionStr, InpSessionStart, InpSessionEnd,
      g_dailyLoss, InpDailyLossMax,
      AccountInfoDouble(ACCOUNT_BALANCE)
   ));
}
//+------------------------------------------------------------------+
