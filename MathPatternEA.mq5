//+------------------------------------------------------------------+
//|                                              MathPatternEA.mq5   |
//|                          Copyright 2026, Nahuel Scarpelli        |
//|              v3: Z-Score Crossback + Averaging Estadistico       |
//+------------------------------------------------------------------+
// v3: Same-direction averaging with DECREASING lots.
// v1/v2 (zone recovery) blew accounts: opposite-direction exponential lots.
// v3: all adds are SAME direction, lots shrink each layer.
// Max exposure ~2.2x base vs 10x+ in v1/v2.
//+------------------------------------------------------------------+
#property copyright "Nahuel Scarpelli"
#property version   "3.00"
#property description "v3: Z-Score Crossback + Averaging Estadistico"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
input group "══════ MOTOR ESTADISTICO ══════"
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_M15;
input int             InpZScorePeriod  = 100;            // Periodo Z-Score
input double          InpZScoreEntry   = 2.5;            // Umbral Z-Score
input int             InpATRPeriod     = 14;             // Periodo ATR

input group "══════ FILTROS ══════"
input int             InpSessionStart  = 7;              // Hora inicio sesion
input int             InpSessionEnd    = 20;             // Hora fin sesion
input double          InpMaxSMASlope   = 0.0004;         // Pendiente max SMA
input int             InpCooldownBars  = 10;             // Cooldown tras perdida

input group "══════ AVERAGING ══════"
input double          InpBaseLot       = 0.01;           // Lote base
input int             InpMaxLayers     = 3;              // Max niveles averaging
input double          InpZoneATRMult   = 2.0;            // Zona = ATR x esto
input double          InpLotReduction  = 0.7;            // Cada capa = anterior x esto
input double          InpTargetProfit  = 5.0;            // Target USD por ciclo

input group "══════ GESTION DE RIESGO ══════"
input double          InpHardSL_ATR    = 4.0;            // Hard SL = ATR x esto
input double          InpMaxDrawdownPct = 20.0;          // Drawdown maximo %
input double          InpDailyLossMax   = 30.0;          // Perdida diaria max USD
input int             InpMaxBarsInTrade = 200;           // Time stop (barras)
input int             InpMagicNumber    = 777777;

//+------------------------------------------------------------------+
CTrade g_trade;
int    g_hSMA, g_hATR;

bool   g_cycleActive    = false;
int    g_layerCount     = 0;
double g_zoneSize       = 0;
double g_lastLayerPrice = 0;
int    g_cycleDir       = 0;
double g_avgEntry       = 0;
double g_totalLots      = 0;
int    g_barsInTrade    = 0;

double g_dailyLoss      = 0;
int    g_dailyDate      = 0;
datetime g_lastBarTime  = 0;
int    g_cooldownLeft   = 0;
double g_prevZScore     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
      != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   { Alert("Requiere cuenta HEDGING."); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(10);
   long f = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) != 0)      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((f & SYMBOL_FILLING_IOC) != 0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                    g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   g_hSMA = iMA(_Symbol, InpTimeframe, InpZScorePeriod, 0, MODE_SMA, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   if(g_hSMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   { Alert("Error indicadores."); return INIT_FAILED; }

   double pl = 0;
   if(CountMyPositions(pl) > 0) { g_cycleActive = true; RecoverCycleState(); }

   Print("=== MathPatternEA v3.0 - Averaging Estadistico ===");
   Print(StringFormat("  Z±%.1f | Layers:%d | LotRedux:%.0f%% | SL:%.1fATR | Target:$%.1f",
         InpZScoreEntry, InpMaxLayers, InpLotReduction*100, InpHardSL_ATR, InpTargetProfit));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_hSMA != INVALID_HANDLE) IndicatorRelease(g_hSMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Daily reset
   MqlDateTime dt; TimeCurrent(dt);
   int d = dt.year*10000 + dt.mon*100 + dt.day;
   if(d != g_dailyDate) { g_dailyLoss = 0; g_dailyDate = d; }

   double netPL = 0;
   int positions = CountMyPositions(netPL);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Daily loss limit
   if(g_dailyLoss >= InpDailyLossMax)
   { if(positions > 0) CloseAll("LIMITE DIARIO"); UpdateChart(netPL); return; }

   // Max drawdown
   if(positions > 0 && netPL < -(balance * InpMaxDrawdownPct / 100.0))
   {
      g_dailyLoss += MathAbs(netPL);
      g_cooldownLeft = InpCooldownBars;
      CloseAll(StringFormat("MAX DD: %.2f", netPL));
      UpdateChart(netPL); return;
   }

   //=== CYCLE ACTIVE ===
   if(g_cycleActive && positions > 0)
   {
      datetime barTime = iTime(_Symbol, InpTimeframe, 0);
      if(barTime != g_lastBarTime)
      {
         g_lastBarTime = barTime;
         g_barsInTrade++;
         if(g_barsInTrade >= InpMaxBarsInTrade)
         {
            if(netPL < 0) g_dailyLoss += MathAbs(netPL);
            g_cooldownLeft = InpCooldownBars;
            CloseAll(StringFormat("TIME STOP %d bars P&L:%.2f", g_barsInTrade, netPL));
            UpdateChart(netPL); return;
         }
      }

      // Hard SL (every tick)
      if(IsHardSLHit())
      {
         g_dailyLoss += MathAbs(netPL);
         g_cooldownLeft = InpCooldownBars;
         CloseAll(StringFormat("HARD SL P&L:%.2f", netPL));
         UpdateChart(netPL); return;
      }

      // Target profit
      if(netPL >= InpTargetProfit)
      { CloseAll(StringFormat("TARGET +%.2f L%d %db", netPL, g_layerCount, g_barsInTrade));
        UpdateChart(netPL); return; }

      // Mean reversion TP: price crossed SMA
      if(IsMeanReversionDone() && netPL > 0)
      { CloseAll(StringFormat("MEAN REV +%.2f", netPL)); UpdateChart(netPL); return; }

      // Averaging layer
      if(g_layerCount < InpMaxLayers && ShouldAddLayer())
         AddAveragingLayer(netPL);

      UpdateChart(netPL); return;
   }

   // External close
   if(g_cycleActive && positions == 0)
   { g_cycleActive = false; g_layerCount = 0; g_totalLots = 0; }

   //=== IDLE: Z-Score crossback ===
   if(!g_cycleActive)
   {
      datetime barTime = iTime(_Symbol, InpTimeframe, 0);
      if(barTime == g_lastBarTime) { UpdateChart(0); return; }
      g_lastBarTime = barTime;

      if(g_cooldownLeft > 0)
      { g_cooldownLeft--; g_prevZScore = CalcZScore(); UpdateChart(0); return; }

      if(!IsWithinSession())
      { g_prevZScore = CalcZScore(); UpdateChart(0); return; }

      double zScore = CalcZScore();
      double atr = GetATR();
      if(atr <= 0) { g_prevZScore = zScore; UpdateChart(0); return; }
      if(IsTrending()) { g_prevZScore = zScore; UpdateChart(0); return; }

      g_zoneSize = NormalizeDouble(atr * InpZoneATRMult, _Digits);

      int dir = 0;
      if(g_prevZScore <= -InpZScoreEntry && zScore > -InpZScoreEntry) dir = +1;
      else if(g_prevZScore >= InpZScoreEntry && zScore < InpZScoreEntry) dir = -1;
      g_prevZScore = zScore;

      if(dir != 0) OpenFirstLayer(dir, zScore);
      UpdateChart(0);
   }
}

//+------------------------------------------------------------------+
//| STATISTICS                                                        |
//+------------------------------------------------------------------+
double CalcZScore()
{
   double closes[]; ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, InpTimeframe, 0, InpZScorePeriod, closes) < InpZScorePeriod) return 0;
   double sma[]; ArraySetAsSeries(sma, true);
   if(CopyBuffer(g_hSMA, 0, 0, 1, sma) < 1) return 0;
   double mean = sma[0], sumSq = 0;
   for(int i = 0; i < InpZScorePeriod; i++)
      sumSq += (closes[i] - mean) * (closes[i] - mean);
   double sd = MathSqrt(sumSq / InpZScorePeriod);
   if(sd < _Point) return 0;
   return (closes[0] - mean) / sd;
}

double GetATR()
{
   double a[]; ArraySetAsSeries(a, true);
   if(CopyBuffer(g_hATR, 0, 0, 1, a) < 1) return 0;
   return a[0];
}

double GetSMA()
{
   double s[]; ArraySetAsSeries(s, true);
   if(CopyBuffer(g_hSMA, 0, 0, 1, s) < 1) return 0;
   return s[0];
}

//+------------------------------------------------------------------+
//| AVERAGING ENGINE                                                  |
//+------------------------------------------------------------------+
void OpenFirstLayer(int dir, double zScore)
{
   double price = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                             : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!HasEnoughMargin(dir, InpBaseLot, price)) return;

   Print(StringFormat("=== CICLO: %s %.2f @ %.5f Z:%.2f ===",
         (dir>0)?"BUY":"SELL", InpBaseLot, price, zScore));

   bool ok = (dir > 0) ? g_trade.Buy(InpBaseLot, _Symbol, price, 0, 0, "MathEA_L1")
                        : g_trade.Sell(InpBaseLot, _Symbol, price, 0, 0, "MathEA_L1");
   if(ok)
   {
      g_cycleActive = true; g_layerCount = 1;
      g_lastLayerPrice = price; g_cycleDir = dir;
      g_avgEntry = price; g_totalLots = InpBaseLot;
      g_barsInTrade = 0;
   }
}

bool ShouldAddLayer()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_cycleDir > 0) return (g_lastLayerPrice - bid) >= g_zoneSize;
   else               return (bid - g_lastLayerPrice) >= g_zoneSize;
}

void AddAveragingLayer(double currentPL)
{
   double lot = InpBaseLot * MathPow(InpLotReduction, g_layerCount);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   lot = MathFloor(lot / step + 0.5) * step;
   lot = MathMax(lot, minL);

   double price = (g_cycleDir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                    : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(!HasEnoughMargin(g_cycleDir, lot, price))
   { g_dailyLoss += MathAbs(currentPL); g_cooldownLeft = InpCooldownBars;
     CloseAll("SIN MARGEN AVG"); return; }

   g_layerCount++;
   Print(StringFormat("  >> AVG L%d: %s %.3f @ %.5f (P&L:%.2f)",
         g_layerCount, (g_cycleDir>0)?"BUY":"SELL", lot, price, currentPL));

   bool ok = (g_cycleDir > 0) ? g_trade.Buy(lot, _Symbol, price, 0, 0, StringFormat("MathEA_L%d", g_layerCount))
                               : g_trade.Sell(lot, _Symbol, price, 0, 0, StringFormat("MathEA_L%d", g_layerCount));
   if(ok)
   {
      g_avgEntry = (g_avgEntry * g_totalLots + price * lot) / (g_totalLots + lot);
      g_totalLots += lot; g_lastLayerPrice = price;
   }
   else g_layerCount--;
}

bool IsHardSLHit()
{
   double atr = GetATR();
   if(atr <= 0 || g_totalLots <= 0) return false;
   double slDist = atr * InpHardSL_ATR;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_cycleDir > 0) return (g_avgEntry - bid) >= slDist;
   else               return (bid - g_avgEntry) >= slDist;
}

bool IsMeanReversionDone()
{
   double sma = GetSMA();
   if(sma <= 0) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_cycleDir > 0) return (bid >= sma);
   else               return (bid <= sma);
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT                                               |
//+------------------------------------------------------------------+
int CountMyPositions(double &netPL)
{
   int count = 0; netPL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      netPL += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP)
             + PositionGetDouble(POSITION_COMMISSION);
      count++;
   }
   return count;
}

void CloseAll(string reason)
{
   Print("=== ", reason, " ===");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      g_trade.PositionClose(ticket);
   }
   g_cycleActive = false; g_layerCount = 0;
   g_totalLots = 0; g_avgEntry = 0; g_barsInTrade = 0;
}

void RecoverCycleState()
{
   g_layerCount = 0; g_totalLots = 0; double tw = 0;
   datetime newest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      g_layerCount++;
      double lot = PositionGetDouble(POSITION_VOLUME);
      double px = PositionGetDouble(POSITION_PRICE_OPEN);
      g_totalLots += lot; tw += px * lot;
      g_cycleDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? +1 : -1;
      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t > newest) { newest = t; g_lastLayerPrice = px; }
   }
   if(g_totalLots > 0) g_avgEntry = tw / g_totalLots;
   double atr = GetATR();
   if(atr > 0) g_zoneSize = NormalizeDouble(atr * InpZoneATRMult, _Digits);
}

//+------------------------------------------------------------------+
//| FILTERS & UTILITIES                                               |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt; TimeCurrent(dt);
   if(InpSessionStart < InpSessionEnd)
      return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
   return (dt.hour >= InpSessionStart || dt.hour < InpSessionEnd);
}

bool IsTrending()
{
   double s[]; ArraySetAsSeries(s, true);
   if(CopyBuffer(g_hSMA, 0, 0, 3, s) < 3) return false;
   return (MathAbs(s[0] - s[2]) / 2.0 > InpMaxSMASlope);
}

bool HasEnoughMargin(int dir, double lot, double price)
{
   ENUM_ORDER_TYPE t = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double needed = 0;
   if(!OrderCalcMargin(t, _Symbol, lot, price, needed)) return false;
   return (needed < AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.80);
}

void UpdateChart(double netPL)
{
   string st;
   if(g_dailyLoss >= InpDailyLossMax) st = "BLOQUEADO";
   else if(g_cycleActive) st = StringFormat("ACTIVO L%d/%d P&L:%.2f %db",
                                             g_layerCount, InpMaxLayers, netPL, g_barsInTrade);
   else st = "IDLE";
   string cd = (g_cooldownLeft > 0) ? StringFormat(" CD:%d", g_cooldownLeft) : "";

   Comment(StringFormat(
      "\n  === MATH PATTERN EA v3.0 ===\n"
      "  %s%s\n"
      "  Z:%.2f (±%.1f) Prev:%.2f\n"
      "  AvgEntry:%.5f Lots:%.3f\n"
      "  Zone:%.0fpts SL:%.1fATR\n"
      "  Daily:%.1f/%.1f Bal:%.2f\n"
      "  ============================\n",
      st, cd, CalcZScore(), InpZScoreEntry, g_prevZScore,
      g_avgEntry, g_totalLots, g_zoneSize/_Point, InpHardSL_ATR,
      g_dailyLoss, InpDailyLossMax, AccountInfoDouble(ACCOUNT_BALANCE)));
}
//+------------------------------------------------------------------+
