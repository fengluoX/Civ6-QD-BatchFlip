-- ===========================================================================
-- DealManager helpers (UI context)
-- ===========================================================================

include("qd_utils"); -- DIPLOMATIC_FAVOR_INDEX, DIPLOMATIC_FAVOR_THRESHOLD

BatchFlipDealUtil = BatchFlipDealUtil or {}

local FAVOR_INDEX = (DIPLOMATIC_FAVOR_INDEX ~= nil) and DIPLOMATIC_FAVOR_INDEX or 1;

function BatchFlipDealUtil.GetFavorType()
  if DealItemTypes == nil then
    return nil;
  end
  return DealItemTypes.FAVOR or DealItemTypes.DIPLOMATIC_FAVOR;
end

function BatchFlipDealUtil.GetLocalPlayerID()
  return Game.GetLocalPlayer();
end

function BatchFlipDealUtil.IsMajorAlive(playerID)
  local p = Players[playerID];
  if p == nil or not p:IsAlive() or not p:IsMajor() then
    return false;
  end
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  if localID < 0 or playerID == localID then
    return false;
  end
  local dip = Players[localID]:GetDiplomacy();
  if dip == nil or not dip:HasMet(playerID) or dip:IsAtWarWith(playerID) then
    return false;
  end
  return true;
end

function BatchFlipDealUtil.ForEachMetAi(callback)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  if localID < 0 then
    return;
  end
  for _, pid in ipairs(PlayerManager.GetAliveMajorIDs()) do
    if BatchFlipDealUtil.IsMajorAlive(pid) then
      callback(pid);
    end
  end
end

function BatchFlipDealUtil.GetTreasuryGold(playerID)
  local p = Players[playerID];
  if p == nil then
    return 0;
  end
  local treasury = p:GetTreasury();
  if treasury == nil then
    return 0;
  end
  return math.floor(treasury:GetGoldBalance() or 0);
end

function BatchFlipDealUtil.GetFavorBalance(playerID)
  local p = Players[playerID];
  if p == nil or p.GetFavor == nil then
    return 0;
  end
  return math.floor(p:GetFavor() or 0);
end

function BatchFlipDealUtil.ClearOutgoing(localID, otherID)
  if DealManager.HasPendingDeal(localID, otherID) then
    return false;
  end
  DealManager.ClearWorkingDeal(DealDirection.OUTGOING, localID, otherID);
  return true;
end

function BatchFlipDealUtil.GetWorkingDeal(localID, otherID)
  return DealManager.GetWorkingDeal(DealDirection.OUTGOING, localID, otherID);
end

function BatchFlipDealUtil.CloseSession(localID, otherID)
  local sid = DiplomacyManager.FindOpenSessionID(localID, otherID);
  if sid ~= nil then
    DiplomacyManager.CloseSession(sid);
  end
end

-- Close leftover MAKE_DEAL sessions / working deals so QD & BQD tabs
-- do not get stuck on "加载中" waiting for diplomacy responses.
function BatchFlipDealUtil.CleanupDiplomacy()
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  if localID < 0 then
    return;
  end
  if CloseAllDiplomacySessions ~= nil then
    pcall(function() CloseAllDiplomacySessions(); end);
  else
    BatchFlipDealUtil.ForEachMetAi(function(aiID)
      BatchFlipDealUtil.CloseSession(localID, aiID);
    end);
  end
  BatchFlipDealUtil.ForEachMetAi(function(aiID)
    pcall(function()
      DealManager.ClearWorkingDeal(DealDirection.OUTGOING, localID, aiID);
    end);
  end);
end

-- After mass MAKE_DEAL, leader / DAV can linger and freeze AI turns.
-- Do NOT close the Quick Deals popup — player stays on 批量倒卖 to see results.
function BatchFlipDealUtil.DismissDiplomacyUi()
  BatchFlipDealUtil.CleanupDiplomacy();
  pcall(function() LuaEvents.DiplomacyActionView_ShowIngameUI(); end);
end

-- Accept without opening a new diplomacy session. Do not close sessions here;
-- BatchFlipFavor.Run cleans up once at the end so QD fetch is not interrupted mid-flight.
function BatchFlipDealUtil.TrySend(localID, otherID)
  if DealProposalAction == nil or DealProposalAction.ACCEPTED == nil then
    return false;
  end
  DealManager.SendWorkingDeal(DealProposalAction.ACCEPTED, localID, otherID);
  return true;
end



function BatchFlipDealUtil.AddGold(deal, fromPlayerID, amount, duration)
  if deal == nil or amount == nil or amount <= 0 then
    return nil;
  end
  local item = deal:AddItemOfType(DealItemTypes.GOLD, fromPlayerID);
  if item == nil then
    return nil;
  end
  item:SetAmount(math.floor(amount));
  item:SetDuration(duration or 0);
  return item;
end

function BatchFlipDealUtil.AddFavor(deal, fromPlayerID, amount)
  local favorType = BatchFlipDealUtil.GetFavorType();
  if favorType == nil or deal == nil or amount == nil or amount <= 0 then
    return nil;
  end
  local item = deal:AddItemOfType(favorType, fromPlayerID);
  if item == nil then
    return nil;
  end
  if item.SetValueType ~= nil then
    item:SetValueType(FAVOR_INDEX);
  end
  if item.SetAmount ~= nil then
    item:SetAmount(math.floor(amount));
  end
  if item.SetDuration ~= nil then
    item:SetDuration(0);
  end
  return item;
end

-- OTG + GPT*30 (QD GOLD_RATIO default 21; use 30 for conservative 30-turn lease).
function BatchFlipDealUtil.GoldValue(otg, mtg)
  local ratio = (GOLD_RATIO ~= nil) and GOLD_RATIO or 30;
  return math.floor(otg or 0) + math.floor(mtg or 0) * ratio;
end

function BatchFlipDealUtil.GetResourceAmount(playerID, resourceIndex)
  local p = Players[playerID];
  if p == nil then return 0; end
  local res = p:GetResources();
  if res == nil then return 0; end
  local desc = GameInfo.Resources[resourceIndex];
  if desc == nil then return 0; end
  return math.floor(res:GetResourceAmount(desc.ResourceType) or 0);
end

-- Stockpile cap for a strategic resource (huge when unknown).
function BatchFlipDealUtil.GetStockpileCap(playerID, resourceIndex)
  local p = Players[playerID];
  local desc = GameInfo.Resources[resourceIndex];
  if p == nil or desc == nil then return 0; end
  local ok, cap = pcall(function() return p:GetResources():GetResourceStockpileCap(desc.ResourceType); end);
  if ok and cap ~= nil and cap > 0 then return math.floor(cap); end
  return 9999;
end

function BatchFlipDealUtil.GetResourceName(resourceIndex)
  local desc = GameInfo.Resources[resourceIndex];
  if desc == nil then return "资源" .. tostring(resourceIndex); end
  local ok, name = pcall(function() return Locale.Lookup(desc.Name); end);
  if ok and name ~= nil and name ~= "" then return name; end
  return desc.ResourceType or ("资源" .. tostring(resourceIndex));
end

function BatchFlipDealUtil.AddResource(deal, fromPlayerID, resourceIndex, amount, duration)
  if deal == nil or resourceIndex == nil or amount == nil or amount <= 0 then
    return nil;
  end
  if DealItemTypes == nil or DealItemTypes.RESOURCES == nil then
    return nil;
  end
  local item = deal:AddItemOfType(DealItemTypes.RESOURCES, fromPlayerID);
  if item == nil then
    return nil;
  end
  if item.SetValueType ~= nil then
    item:SetValueType(resourceIndex);
  end
  if item.SetAmount ~= nil then
    item:SetAmount(math.floor(amount));
  end
  if item.SetDuration ~= nil then
    item:SetDuration(duration ~= nil and duration or 30);
  end
  return item;
end

-- Max amount + duration for resource from->to via DealManager possibles.
function BatchFlipDealUtil.MaxResourceTradable(fromID, toID, resourceIndex)
  if DealItemTypes == nil or DealItemTypes.RESOURCES == nil then
    return 0, 30;
  end
  local deal = nil;
  pcall(function()
    deal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, fromID, toID);
  end);
  local possible = DealManager.GetPossibleDealItems(fromID, toID, DealItemTypes.RESOURCES, deal) or {};
  for _, entry in ipairs(possible) do
    if entry.ForType == resourceIndex and (entry.MaxAmount or 0) > 0 then
      return math.floor(entry.MaxAmount), entry.Duration or 30;
    end
  end
  return 0, 30;
end

function BatchFlipDealUtil.MergeLogs(into, from)
  if into == nil or from == nil then return into; end
  into.attempted = (into.attempted or 0) + (from.attempted or 0);
  into.success = (into.success or 0) + (from.success or 0);
  into.skipped = (into.skipped or 0) + (from.skipped or 0);
  into.failed = (into.failed or 0) + (from.failed or 0);
  into.goldSpent = (into.goldSpent or 0) + (from.goldSpent or 0);
  into.goldEarned = (into.goldEarned or 0) + (from.goldEarned or 0);
  into.favorBought = (into.favorBought or 0) + (from.favorBought or 0);
  into.favorSold = (into.favorSold or 0) + (from.favorSold or 0);
  into.resBought = (into.resBought or 0) + (from.resBought or 0);
  into.resSold = (into.resSold or 0) + (from.resSold or 0);
  for _, t in ipairs(from.trades or {}) do
    table.insert(into.trades, t);
  end
  for _, line in ipairs(from.lines or {}) do
    table.insert(into.lines, line);
  end
  if from.note ~= nil and from.note ~= "" then
    into.note = (into.note and (into.note .. "；") or "") .. from.note;
  end
  return into;
end

function BatchFlipDealUtil.Validate(deal)
  if deal == nil or DealValidationResult == nil then
    return false;
  end
  return deal:Validate() == DealValidationResult.VALID;
end

function BatchFlipDealUtil.GetPossible(fromID, toID, itemType)
  return DealManager.GetPossibleDealItems(fromID, toID, itemType) or {};
end

-- How much favor `fromID` can put on a deal toward `toID` this turn.
function BatchFlipDealUtil.MaxFavorTradable(fromID, toID)
  local favorType = BatchFlipDealUtil.GetFavorType();
  if favorType == nil then
    return 0;
  end
  local possible = BatchFlipDealUtil.GetPossible(fromID, toID, favorType);
  local maxAmt = 0;
  for _, item in ipairs(possible) do
    local amt = item.MaxAmount or item.Amount or 0;
    if amt > maxAmt then
      maxAmt = amt;
    end
  end
  local bal = BatchFlipDealUtil.GetFavorBalance(fromID);
  if bal > 0 then
    maxAmt = math.min(maxAmt > 0 and maxAmt or bal, bal);
  end
  local cap = (DIPLOMATIC_FAVOR_THRESHOLD ~= nil) and DIPLOMATIC_FAVOR_THRESHOLD or 20;
  return math.min(maxAmt, cap);
end

function BatchFlipDealUtil.CanSpendMyGold(amount, cfg)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local bal = BatchFlipDealUtil.GetTreasuryGold(localID);
  return (bal - amount) >= (cfg.ReserveMyGold or 0);
end

function BatchFlipDealUtil.AiGoldLeftAfter(aiID, takeAmount, cfg)
  local bal = BatchFlipDealUtil.GetTreasuryGold(aiID);
  return (bal - takeAmount) >= (cfg.ReserveAiGold or 0);
end

function BatchFlipDealUtil.GetAiName(playerID)
  local ok, name = pcall(function()
    local cfg = PlayerConfigurations[playerID];
    if cfg == nil then
      return nil;
    end
    if cfg.GetLeaderName ~= nil then
      local n = Locale.Lookup(cfg:GetLeaderName());
      if n ~= nil and n ~= "" then
        return n;
      end
    end
    if cfg.GetPlayerName ~= nil then
      local n = Locale.Lookup(cfg:GetPlayerName());
      if n ~= nil and n ~= "" then
        return n;
      end
    end
    if cfg.GetCivilizationShortDescription ~= nil then
      local n = Locale.Lookup(cfg:GetCivilizationShortDescription());
      if n ~= nil and n ~= "" then
        return n;
      end
    end
    return nil;
  end);
  if ok and name ~= nil and name ~= "" then
    return name;
  end
  return "AI" .. tostring(playerID);
end

function BatchFlipDealUtil.NewLog()
  return {
    attempted = 0,
    success = 0,
    skipped = 0,
    failed = 0,
    goldSpent = 0,
    goldEarned = 0,
    favorBought = 0,
    favorSold = 0,
    resBought = 0,
    resSold = 0,
    trades = {}, -- chronological per-deal lines
    lines = {},
    note = nil,
  };
end

local function FormatGoldText(gold, gpt)
  gold = math.floor(gold or 0);
  gpt = math.floor(gpt or 0);
  if gpt > 0 and gold > 0 then
    return string.format("%d金+%d金/回合", gold, gpt);
  elseif gpt > 0 then
    return string.format("%d金/回合", gpt);
  end
  return string.format("%d金", gold);
end

local function TradeEntryText(entry, withName)
  if type(entry) == "string" then
    return entry;
  end
  local name = entry.name or ("AI" .. tostring(entry.aiID or "?"));
  local goldText = FormatGoldText(entry.gold, entry.gpt);
  local label = entry.itemLabel or "支持";
  local amt = math.floor(entry.amount or entry.favor or 0);
  local body;
  if entry.side == "sell" then
    body = string.format("卖出%s×%d，收回%s", label, amt, goldText);
  else
    body = string.format("买入%s×%d，支付%s", label, amt, goldText);
  end
  if withName then
    return name .. "：" .. body;
  end
  return "  · " .. body;
end

-- Append one deal. favorAmount kept for favor engines; optional itemLabel/resourceIndex.
-- goldAmount = immediate lump gold; gptAmount optional multi-turn gold/turn.
function BatchFlipDealUtil.RecordTrade(log, aiID, side, favorAmount, goldAmount, gptAmount, itemLabel, resourceIndex)
  local name = BatchFlipDealUtil.GetAiName(aiID);
  local amt = math.floor(favorAmount or 0);
  local entry = {
    aiID = aiID,
    name = name,
    side = side,
    favor = amt, -- legacy field for favor summary
    amount = amt,
    itemLabel = itemLabel or "支持",
    resourceIndex = resourceIndex,
    gold = math.floor(goldAmount or 0),
    gpt = math.floor(gptAmount or 0),
  };
  entry.text = TradeEntryText(entry, true);
  table.insert(log.trades, entry);
  print("BatchFlip: " .. entry.text);
end

function BatchFlipDealUtil.LogLine(log, text)
  table.insert(log.lines, text);
  print("BatchFlip: " .. tostring(text));
end

local function AppendNoteLines(chunks, note)
  if note == nil or note == "" then return; end
  table.insert(chunks, "【说明】");
  for part in string.gmatch(tostring(note), "([^；;]+)") do
    part = string.gsub(part, "^%s+", "");
    part = string.gsub(part, "%s+$", "");
    if part ~= "" then
      table.insert(chunks, "  " .. part);
    end
  end
end

local function SummaryHeaderBlocks(log)
  local net = (log.goldEarned or 0) - (log.goldSpent or 0);
  local bought = log.favorBought or 0;
  local sold = log.favorSold or 0;
  local resBought = log.resBought or 0;
  local resSold = log.resSold or 0;
  local gptIn, gptOut = 0, 0;
  for _, entry in ipairs(log.trades or {}) do
    if type(entry) == "table" and (entry.gpt or 0) > 0 then
      if entry.side == "sell" then gptIn = gptIn + entry.gpt; else gptOut = gptOut + entry.gpt; end
    end
  end
  local chunks = {
    "【合计】",
    string.format("  成交 %d 笔", log.success or 0),
    string.format("  买支持 %d  /  卖支持 %d", bought, sold),
    string.format("  买资源 %d  /  卖资源 %d", resBought, resSold),
    string.format("  花费 %d金  /  收入 %d金  /  净赚 %d金",
      log.goldSpent or 0, log.goldEarned or 0, net),
    string.format("  回合金 收入 +%d/回合  /  支出 -%d/回合（30回合）", gptIn, gptOut),
    "  ※ 支持：廉价窗买入、逐点卖出；战略：买空→整批卖回→再买回",
  };
  if log.lines ~= nil and #log.lines > 0 then
    table.insert(chunks, "【战略循环】");
    for _, line in ipairs(log.lines) do
      table.insert(chunks, "  " .. line);
    end
  end
  AppendNoteLines(chunks, log.note);
  return chunks;
end

local function BuildAiRows(log)
  local byAi = {};
  local order = {};
  for _, entry in ipairs(log.trades or {}) do
    if type(entry) == "table" then
      local key = entry.aiID;
      if key == nil then key = entry.name or "?"; end
      local row = byAi[key];
      if row == nil then
        row = {
          name = entry.name or ("AI" .. tostring(key)),
          buyFavor = 0, sellFavor = 0,
          buyRes = 0, sellRes = 0,
          buyGold = 0, sellGold = 0,
          buyCount = 0, sellCount = 0,
          deals = {},
        };
        byAi[key] = row;
        table.insert(order, key);
      end
      table.insert(row.deals, entry);
      local amt = entry.amount or entry.favor or 0;
      local isRes = entry.resourceIndex ~= nil or (entry.itemLabel ~= nil and entry.itemLabel ~= "支持");
      if entry.side == "sell" then
        if isRes then row.sellRes = row.sellRes + amt; else row.sellFavor = row.sellFavor + amt; end
        row.sellGold = row.sellGold + (entry.gold or 0);
        row.sellCount = row.sellCount + 1;
      else
        if isRes then row.buyRes = row.buyRes + amt; else row.buyFavor = row.buyFavor + amt; end
        row.buyGold = row.buyGold + (entry.gold or 0);
        row.buyCount = row.buyCount + 1;
      end
    end
  end
  return byAi, order;
end

-- Aggregate per AI: buy/sell favor & gold totals.
function BatchFlipDealUtil.SummaryTextByAi(log)
  local chunks = SummaryHeaderBlocks(log);
  if log.trades == nil or #log.trades == 0 then
    table.insert(chunks, "【按文明汇总】");
    table.insert(chunks, "  没有与任何文明成交");
    return table.concat(chunks, "[NEWLINE]");
  end

  local byAi, order = BuildAiRows(log);
  table.insert(chunks, "【按文明汇总】");
  for _, key in ipairs(order) do
    local row = byAi[key];
    local net = (row.sellGold or 0) - (row.buyGold or 0);
    table.insert(chunks, row.name);
    if (row.buyFavor or 0) > 0 or (row.sellFavor or 0) > 0 then
      table.insert(chunks, string.format("  买支持 %d / %d金（%d笔）",
        row.buyFavor, row.buyGold, row.buyCount));
      table.insert(chunks, string.format("  卖支持 %d / %d金（%d笔）",
        row.sellFavor, row.sellGold, row.sellCount));
    end
    if (row.buyRes or 0) > 0 or (row.sellRes or 0) > 0 then
      table.insert(chunks, string.format("  买资源 %d / 卖资源 %d", row.buyRes, row.sellRes));
      table.insert(chunks, string.format("  资源相关金 买%d / 卖%d", row.buyGold, row.sellGold));
    end
    if (row.buyFavor or 0) == 0 and (row.sellFavor or 0) == 0
        and (row.buyRes or 0) == 0 and (row.sellRes or 0) == 0 then
      table.insert(chunks, string.format("  买 %d金（%d笔） / 卖 %d金（%d笔）",
        row.buyGold, row.buyCount, row.sellGold, row.sellCount));
    end
    table.insert(chunks, string.format("  净 %+d金", net));
  end
  return table.concat(chunks, "[NEWLINE]");
end

function BatchFlipDealUtil.SummaryTextDetail(log)
  local chunks = SummaryHeaderBlocks(log);
  if log.trades == nil or #log.trades == 0 then
    table.insert(chunks, "【成交明细】");
    table.insert(chunks, "  没有与任何文明成交");
    return table.concat(chunks, "[NEWLINE]");
  end

  local byAi, order = BuildAiRows(log);
  table.insert(chunks, "【成交明细】");
  for _, key in ipairs(order) do
    local row = byAi[key];
    table.insert(chunks, "── " .. row.name .. " ──");
    for _, entry in ipairs(row.deals) do
      table.insert(chunks, TradeEntryText(entry, false));
    end
  end
  return table.concat(chunks, "[NEWLINE]");
end

-- Default: by-AI aggregate. Pass detailed=true for per-deal lines.
function BatchFlipDealUtil.SummaryText(log, detailed)
  if detailed then
    return BatchFlipDealUtil.SummaryTextDetail(log);
  end
  return BatchFlipDealUtil.SummaryTextByAi(log);
end



