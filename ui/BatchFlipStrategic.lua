-- ===========================================================================
-- Strategic resource pump: drain one AI's gold/GPT with one resource.
--
-- AI valuation quirks (CivFanatics "AI pricing of strategic resources"):
--   * holding >= 40 → treats the resource as surplus, sells the whole pile cheap;
--   * holding exactly 0 → pays ~double for every unit of a lot of up to 40.
-- So per (resource, AI) we loop, one deal per step, no separate quoting:
--   buy the AI's whole pile (it drops to 0) → sell it a 40-lot in one deal
--   (premium price, usually GPT) → buy the lot back (it is at 40 again) → ...
-- An AI holding 1..39 won't sell, so we first sell it the missing units to
-- reach 40, then start buying. Zero-stock AIs only ever get a full 40-lot.
-- Pairs that can't trade yet (we lack stock) are retried in later sweeps, so
-- a pile bought from one AI can be pumped through the others.
-- Both stockpile caps bound every step (our room when buying, the AI's room
-- when selling). The loop for a pair stops after any buy+sell round that lost
-- value, when a quote misses the profit line, or when a deal fails.
-- ===========================================================================

include("BatchFlipConfig");
include("BatchFlipDealUtil");
include("BatchFlipDealSession");
include("qd_utils");

BatchFlipStrategic = BatchFlipStrategic or {}

local VERSION = "str13";

function BatchFlipStrategic.GetVersion()
  return VERSION;
end

function BatchFlipStrategic.IsBusy()
  return BatchFlipDealSession.IsBusy();
end

function BatchFlipStrategic.ForceAbort(reason)
  BatchFlipDealSession.ForceAbort(reason);
end

local function Amount(playerID, resourceIndex)
  return BatchFlipDealUtil.GetResourceAmount(playerID, resourceIndex);
end

local function Money(playerID)
  local gold, gpt = 0, 0;
  pcall(function()
    local t = Players[playerID]:GetTreasury();
    gold = math.floor(t:GetGoldBalance());
    gpt = math.floor(t:GetGoldYield() - t:GetTotalMaintenance());
  end);
  return gold, gpt;
end

local function Snapshot(p)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local gold, gpt = Money(p.aiID);
  return string.format("AI %d/%d 金%d 回合金%+d | 我 %d/%d",
    Amount(p.aiID, p.resourceIndex), BatchFlipDealUtil.GetStockpileCap(p.aiID, p.resourceIndex), gold, gpt,
    Amount(localID, p.resourceIndex), BatchFlipDealUtil.GetStockpileCap(localID, p.resourceIndex));
end

local function Log(p, fmt, ...)
  print(string.format("BatchFlip STR %s AI=%d(%s) ", p.label, p.aiID, BatchFlipDealUtil.GetAiName(p.aiID))
    .. string.format(fmt, ...));
end

-- One summary line per pair that traded, shown in the result panel.
local function FinishPair(job, p)
  if p.summarized then return; end
  p.done = true;
  p.summarized = true;
  p.endReason = p.endReason or p.waitReason or "结束";
  if (p.deals or 0) == 0 then return; end
  local topup = "";
  if (p.topupAmt or 0) > 0 then topup = string.format("先补足%d个，", p.topupAmt); end
  local line = string.format("%s↔%s：%s对倒%d轮(累计%+d)，卖出得 %d金+%d金/回合，买入花 %d金+%d金/回合，结束原因：%s；%s",
    p.label, BatchFlipDealUtil.GetAiName(p.aiID), topup, p.rounds or 0, p.roundProfit or 0,
    p.sellGold or 0, p.sellGpt or 0, p.buyGold or 0, p.buyGpt or 0, p.endReason, Snapshot(p));
  BatchFlipDealUtil.LogLine(job.log, line);
end

local function Room(playerID, resourceIndex)
  return BatchFlipDealUtil.GetStockpileCap(playerID, resourceIndex) - Amount(playerID, resourceIndex);
end

local function Action(p, side, amount)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local fromID, toID = localID, p.aiID;
  if side == "buy" then fromID, toID = p.aiID, localID; end
  local _, dur = BatchFlipDealUtil.MaxResourceTradable(fromID, toID, p.resourceIndex);
  return {
    side = side, aiID = p.aiID, resourceIndex = p.resourceIndex, label = p.label,
    amount = amount, duration = dur or 30, pair = p,
  };
end

-- Pair can't trade right now (stock/room); it may later in another pass.
local function Wait(p, fmt, ...)
  local reason = string.format(fmt, ...);
  p.phase = nil;
  if p.waitReason ~= reason then
    p.waitReason = reason;
    if (p.deals or 0) > 0 or not reason:find("^我方") then Log(p, "wait: %s", reason); end
  end
  return nil;
end

-- Next deal for one (resource, AI) pair, or nil when it can't trade now.
-- p.done marks the pair finished for the whole run (bad price / loss / failure).
local function NextFor(st, p)
  if p.done then return nil; end
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local res = p.resourceIndex;
  local aiAmt = Amount(p.aiID, res);
  local have = Amount(localID, res);

  if p.phase == nil then
    if aiAmt >= st.richAmount then
      p.phase = "buy";
    elseif aiAmt == 0 then
      if have < st.lot then
        return Wait(p, "我方持有%d不足%d，等补货", have, st.lot);
      end
      p.phase = "sell";
    elseif have >= st.richAmount - aiAmt then
      p.phase = "topup";
    else
      return Wait(p, "AI持有%d（需≥%d可买、=0可卖），我方%d不够补足", aiAmt, st.richAmount, have);
    end
    p.waitReason = nil;
    Log(p, "start phase=%s %s", p.phase, Snapshot(p));
  end

  -- AI below the surplus line won't sell; top it up to exactly richAmount first.
  if p.phase == "topup" then
    local amt = st.richAmount - aiAmt;
    local tradable = BatchFlipDealUtil.MaxResourceTradable(localID, p.aiID, res);
    if aiAmt <= 0 or amt < 1 or amt > have or amt > Room(p.aiID, res) or amt > tradable then
      return Wait(p, "无法补足(AI%d,我%d,可卖%d)", aiAmt, have, tradable);
    end
    local a = Action(p, "sell", amt);
    a.topup = true;
    return a;
  end

  if p.phase == "buy" then
    -- Only cheap while the AI is at/above the surplus line when the deal starts.
    if aiAmt < st.richAmount then
      return Wait(p, "AI库存%d低于%d不再贱卖", aiAmt, st.richAmount);
    end
    local room = Room(localID, res);
    local tradable = BatchFlipDealUtil.MaxResourceTradable(p.aiID, localID, res);
    local amt = math.floor(math.min(aiAmt, room, tradable));
    if amt < 1 then
      return Wait(p, "我方无空间买入(空间%d,AI可卖%d)", room, tradable);
    end
    return Action(p, "buy", amt);
  end

  -- sell: premium only while the AI holds exactly 0; always one full lot, so the
  -- AI lands exactly on the surplus line and will sell it back.
  if aiAmt ~= 0 then
    return Wait(p, "AI库存%d不为0", aiAmt);
  end
  local aiRoom = Room(p.aiID, res);
  local tradable = BatchFlipDealUtil.MaxResourceTradable(localID, p.aiID, res);
  if have < st.lot or aiRoom < st.lot or tradable < st.lot then
    return Wait(p, "我方持有%d不足%d，等补货(AI空间%d,可卖%d)", have, st.lot, aiRoom, tradable);
  end
  return Action(p, "sell", st.lot);
end

local Planner = {};

-- Sweep all pairs; repeat the sweep while the previous one traded, so stock
-- bought from one AI can be sold to the others (and vice versa).
function Planner.Next(job)
  local st = job.state;
  while true do
    while st.pairs[st.idx] ~= nil do
      local p = st.pairs[st.idx];
      local a = NextFor(st, p);
      if a ~= nil then return a; end
      st.idx = st.idx + 1;
    end
    if not st.passTraded or st.pass >= st.maxPasses then break end
    st.pass = st.pass + 1;
    st.passTraded = false;
    st.idx = 1;
    print(string.format("BatchFlip Strategic %s pass %d", VERSION, st.pass));
  end
  return nil;
end

function Planner.OnFinish(job)
  for _, p in ipairs(job.state.pairs) do FinishPair(job, p); end
end

function Planner.OnQuote(job, a, q)
  local st, p = job.state, a.pair;
  if a.topup then
    local ok = q.value >= 1;
    Log(p, "topup x%d bid OTG=%d MTG=%d val=%d → %s", q.amount, q.otg, q.mtg, q.value, ok and "成交" or "放弃");
    if not ok then
      p.endReason = "补足时AI不出价";
      p.done = true;
    end
    return ok;
  end
  if a.side == "buy" then
    -- First round is unbounded and judged by CloseRound; once a round has
    -- proven profitable, a buy-back must stay under what the AI just paid us.
    local limit = math.huge;
    if p.roundSell ~= nil and (p.rounds or 0) > 0 then
      limit = p.roundSell.value - st.minProfit;
    end
    if q.value > limit then
      Log(p, "buy  x%d ask OTG=%d MTG=%d val=%d limit=%d → 放弃", q.amount, q.otg, q.mtg, q.value, limit);
      BatchFlipDealSession.NoteSkip(job, p.label .. "买入价过高");
      p.endReason = string.format("买入要价%d超过上限%d", q.value, limit);
      p.done = true;
      return false;
    end
    -- Pay exactly the AI's own gold/GPT mix; only the spread matters.
    Log(p, "buy  x%d ask OTG=%d MTG=%d val=%d limit=%s → 成交", q.amount, q.otg, q.mtg, q.value,
      limit == math.huge and "-" or tostring(limit));
    return true;
  end
  -- Sell: must cover what this lot cost us (scaled to the lot size) + profit.
  local need = math.max(1, math.ceil(q.amount * st.minSellUnit));
  if p.roundBuy ~= nil and p.roundBuy.amount > 0 then
    need = math.ceil(p.roundBuy.value * q.amount / p.roundBuy.amount) + st.minProfit;
  else
    -- Stock bought from another AI: still has to beat what we paid for it.
    local unit = st.buyUnit[p.resourceIndex];
    if unit ~= nil then need = math.max(need, math.ceil(unit * q.amount) + st.minProfit); end
  end
  local ok = q.value >= need;
  Log(p, "sell x%d bid OTG=%d MTG=%d val=%d need=%d → %s", q.amount, q.otg, q.mtg, q.value, need,
    ok and "成交" or "放弃");
  if ok then return true; end
  BatchFlipDealSession.NoteSkip(job, p.label .. "AI出价不足");
  p.endReason = string.format("AI出价%d低于成本线%d", q.value, need);
  p.done = true;
  return false;
end

-- A round is one buy plus one sell of this pair (either order). Stop the pair
-- after any round that lost value: this AI does not support the pump.
local function CloseRound(p)
  local s, b = p.roundSell, p.roundBuy;
  if s == nil or b == nil then return; end
  p.roundSell, p.roundBuy = nil, nil;
  p.rounds = (p.rounds or 0) + 1;
  local cost = (b.amount > 0) and math.ceil(b.value * s.amount / b.amount) or b.value;
  local profit = s.value - cost;
  p.roundProfit = (p.roundProfit or 0) + profit;
  Log(p, "round %d: sell val=%d buy val=%d profit=%+d", p.rounds, s.value, b.value, profit);
  if profit < 0 then
    p.endReason = string.format("第%d轮对倒亏损%d，停止", p.rounds, -profit);
    p.done = true;
  end
end

function Planner.OnTraded(job, a, r)
  local p = a.pair;
  p.deals = (p.deals or 0) + 1;
  job.state.passTraded = true;
  local value = r.value or r.gold;
  if a.topup then
    p.topupAmt = (p.topupAmt or 0) + r.amount;
    p.sellGold = (p.sellGold or 0) + r.gold;
    p.sellGpt = (p.sellGpt or 0) + (r.mtg or 0);
    p.phase = "buy";
  elseif a.side == "buy" then
    p.roundBuy = { value = math.max(r.gold, value), amount = r.amount };
    if r.amount > 0 then job.state.buyUnit[p.resourceIndex] = p.roundBuy.value / r.amount; end
    p.buyGold = (p.buyGold or 0) + r.gold;
    p.buyGpt = (p.buyGpt or 0) + (r.mtg or 0);
    p.phase = "sell";
  else
    p.roundSell = { value = value, amount = r.amount };
    p.cycles = (p.cycles or 0) + 1;
    p.sellGold = (p.sellGold or 0) + r.gold;
    p.sellGpt = (p.sellGpt or 0) + (r.mtg or 0);
    p.phase = "buy";
  end
  Log(p, "done %s%s x%d gold=%d gpt=%d cycle=%d %s", a.side, a.topup and "(补足)" or "",
    r.amount, r.gold, r.mtg or 0, p.cycles or 0, Snapshot(p));
  if not a.topup then CloseRound(p); end
end

function Planner.OnFailed(job, a, reason)
  local p = a.pair;
  Log(p, "%s failed: %s %s", a.side, tostring(reason), Snapshot(p));
  p.endReason = (a.side == "buy" and "买入" or "卖出") .. "失败:" .. tostring(reason);
  p.done = true;
end

function BatchFlipStrategic.Start(onDone)
  if BatchFlipDealSession.IsBusy() then return; end
  local cfg = BatchFlipConfig.Get();
  local st = {
    pairs = {}, idx = 1, pass = 1, maxPasses = 20, passTraded = false,
    richAmount = cfg.StrategicRichAmount or 40,
    lot = cfg.StrategicSellLot or 40,
    minProfit = cfg.MinArbitrageProfit or 5,
    minSellUnit = cfg.StrategicMinSellUnit or 1,
    buyUnit = {},
  };
  local ais = {};
  BatchFlipDealUtil.ForEachMetAi(function(aiID) table.insert(ais, aiID); end);
  for row in GameInfo.Resources() do
    if row.ResourceClassType == "RESOURCECLASS_STRATEGIC" then
      local label = BatchFlipDealUtil.GetResourceName(row.Index);
      for _, aiID in ipairs(ais) do
        table.insert(st.pairs, { resourceIndex = row.Index, label = label, aiID = aiID });
      end
    end
  end
  print(string.format("BatchFlip Strategic %s start ais=%d pairs=%d", VERSION, #ais, #st.pairs));
  BatchFlipDealSession.Start(Planner, { tag = "战略套利/" .. VERSION, state = st }, onDone);
end
