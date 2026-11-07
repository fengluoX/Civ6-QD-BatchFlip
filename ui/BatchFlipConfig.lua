-- ===========================================================================
-- Shared settings for Batch Flip (Favor / Strategic arbitrage)
-- ===========================================================================

BatchFlipConfig = BatchFlipConfig or {}

local DEFAULTS = {
  ReserveAiGold = 100,
  ReserveMyGold = 0,
  DryRun = false,
  MaxDealsPerClick = 200,
  MaxSessions = 200, -- hard cap MAKE_DEAL sessions per resource engine run
  AutoRun = false,
  FavorMinSellUnitPrice = 1, -- favor sell floor per point (no upper bound)
  FavorKeepOwn = 0,
  MinArbitrageProfit = 5, -- min gold profit per strategic sell / buy-back
  StrategicRichAmount = 40, -- AI at/above this treats the resource as surplus
  StrategicSellLot = 40, -- zero-stock AI pays the premium for up to 40 units
  StrategicMinSellUnit = 1, -- opening sale must fetch at least this per unit
  -- Run checkboxes (persisted); auto runs the same selection
  RunFavor = true,
  RunStrategicArb = true,
}

local g_Config = {}

local function CopyDefaults()
  local t = {}
  for k, v in pairs(DEFAULTS) do
    t[k] = v
  end
  return t
end

function BatchFlipConfig.Get()
  return g_Config
end

function BatchFlipConfig.Reset()
  g_Config = CopyDefaults()
  return g_Config
end

function BatchFlipConfig.Load()
  g_Config = CopyDefaults()
  if GameConfiguration ~= nil then
    local function ReadNumber(key, fallback)
      local v = GameConfiguration.GetValue(key)
      if v == nil then
        return fallback
      end
      return tonumber(v) or fallback
    end
    local function ReadBool(key, fallback)
      local v = GameConfiguration.GetValue(key)
      if v == nil then
        return fallback
      end
      if type(v) == "boolean" then
        return v
      end
      return tostring(v) == "1" or string.lower(tostring(v)) == "true"
    end

    g_Config.ReserveAiGold = ReadNumber("BF_ReserveAiGoldV2", g_Config.ReserveAiGold)
    g_Config.ReserveMyGold = ReadNumber("BF_ReserveMyGold", g_Config.ReserveMyGold)
    g_Config.DryRun = ReadBool("BF_DryRun", g_Config.DryRun)
    g_Config.MaxDealsPerClick = ReadNumber("BF_MaxDeals", g_Config.MaxDealsPerClick)
    g_Config.MaxSessions = ReadNumber("BF_MaxSessionsV2", g_Config.MaxSessions)
    -- AutoRun is session-only: never restore from save; always start off.
    g_Config.AutoRun = false
    g_Config.FavorMinSellUnitPrice = ReadNumber("BF_FavorMinSellV2", g_Config.FavorMinSellUnitPrice)
    g_Config.MinArbitrageProfit = ReadNumber("BF_MinArbProfit", g_Config.MinArbitrageProfit)
    g_Config.RunFavor = ReadBool("BF_RunFavor", g_Config.RunFavor)
    g_Config.RunStrategicArb = ReadBool("BF_RunStrategicArbV2", g_Config.RunStrategicArb)
  end
  return g_Config
end

function BatchFlipConfig.Save()
  if GameConfiguration == nil then
    return
  end
  GameConfiguration.SetValue("BF_ReserveAiGoldV2", g_Config.ReserveAiGold)
  GameConfiguration.SetValue("BF_ReserveMyGold", g_Config.ReserveMyGold)
  GameConfiguration.SetValue("BF_DryRun", g_Config.DryRun and 1 or 0)
  GameConfiguration.SetValue("BF_MaxDeals", g_Config.MaxDealsPerClick)
  GameConfiguration.SetValue("BF_MaxSessionsV2", g_Config.MaxSessions)
  -- Do not persist AutoRun into the save; clear any old flag.
  GameConfiguration.SetValue("BF_AutoRun", 0)
  GameConfiguration.SetValue("BF_FavorMinSellV2", g_Config.FavorMinSellUnitPrice)
  GameConfiguration.SetValue("BF_MinArbProfit", g_Config.MinArbitrageProfit)
  GameConfiguration.SetValue("BF_RunFavor", g_Config.RunFavor and 1 or 0)
  GameConfiguration.SetValue("BF_RunStrategicArbV2", g_Config.RunStrategicArb and 1 or 0)
end

BatchFlipConfig.Load()
