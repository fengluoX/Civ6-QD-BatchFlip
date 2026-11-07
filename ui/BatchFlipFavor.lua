-- ===========================================================================
-- Diplomatic Favor batch flip (v38)
-- Per-AI caps (community ~20/turn), tracked per GAME TURN (not per click):
--   boughtFrom[ai] <= 20, soldTo[ai] <= 20
-- Flow:
--   1) buy sweep: buy cheap stacks (total 1–2 gold, and cheaper than the sell floor)
--   2) sell alloc: sell only to AIs that sold to us this turn (two-way; avoids
--      one-way dumping into hoarders). Always 1 favor per deal at a fresh
--      EQUALIZE price (the bid drops as the AI accumulates favor).
--   3) re-buy what they now hold (quota left) → sell again
--   4) dismiss diplomacy sessions on finish (QD popup stays open)
-- ===========================================================================

include("BatchFlipConfig");
include("BatchFlipDealUtil");
include("qd_utils");

BatchFlipFavor = BatchFlipFavor or {}

local VERSION = "v38";
local CHEAP_MIN, CHEAP_MAX = 1, 2;
local TURN_TRADE_CAP = 20;
local MAX_CYCLES = 8; -- sell→buy→sell loops (hard cap; thrash guard)
local COMMIT_WAIT_TICKS = 60;
local m_Job, m_HandlersReady = nil, false;

-- Per-turn memory shared across clicks in the same turn.
local m_Turn = nil;

local function GetTurnLedger()
  local turn = (Game ~= nil and Game.GetCurrentGameTurn ~= nil) and Game.GetCurrentGameTurn() or -1;
  if m_Turn == nil or m_Turn.turn ~= turn then
    m_Turn = {
      turn = turn,
      boughtFrom = {}, soldTo = {}, sellPrice = {},
      wontSellToUs = {},
    };
  end
  return m_Turn;
end

local function FavorCap()
  return (DIPLOMATIC_FAVOR_THRESHOLD ~= nil) and DIPLOMATIC_FAVOR_THRESHOLD or 20;
end

local function SellFloor(cfg)
  return math.max(CHEAP_MIN, math.floor((cfg and cfg.FavorMinSellUnitPrice) or CHEAP_MIN));
end

-- Buy: whole stack for 1–2 gold TOTAL, and strictly cheaper than reselling at the floor.
local function IsGoodBuy(otg, mtg, amount, cfg)
  if (mtg or 0) ~= 0 then return false; end
  local g = math.floor(otg or 0);
  local n = math.max(1, math.floor(amount or 1));
  if g < CHEAP_MIN or g > CHEAP_MAX then return false; end
  return g < n * SellFloor(cfg);
end

-- Sell: at least the floor per favor; no upper bound (higher is pure profit).
local function IsGoodSell(otg, mtg, amount, cfg)
  if (mtg or 0) ~= 0 then return false; end
  local n = math.max(1, math.floor(amount or 1));
  return math.floor(otg or 0) >= n * SellFloor(cfg);
end

local function ReadDealGold(deal, goldPlayerID)
  if deal == nil or goldPlayerID == nil then return 0, 0; end
  local otg, mtg = 0, 0;
  for dealItem in deal:Items() do
    if dealItem:GetFromPlayerID() == goldPlayerID and dealItem:GetType() == DealItemTypes.GOLD then
      local amt = math.floor(dealItem:GetAmount() or 0);
      if dealItem:GetDuration() == 0 then otg = otg + amt; else mtg = mtg + amt; end
    end
  end
  return otg, mtg;
end

local function ReadEqualizedGold(localID, aiID, goldFromPlayerID)
  pcall(function()
    DealManager.CopyIncomingToOutgoingWorkingDeal(localID, aiID);
  end);
  local deal = BatchFlipDealUtil.GetWorkingDeal(localID, aiID);
  local otg, mtg = ReadDealGold(deal, goldFromPlayerID);
  if otg <= 0 and mtg <= 0 then
    local incoming = nil;
    pcall(function()
      incoming = DealManager.GetWorkingDeal(DealDirection.INCOMING, localID, aiID);
    end);
    local iOtg, iMtg = ReadDealGold(incoming, goldFromPlayerID);
    if (iOtg + iMtg) > (otg + mtg) then otg, mtg = iOtg, iMtg; end
  end
  return otg, mtg;
end

local function CloseAi(aiID)
  if aiID == nil then return; end
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  BatchFlipDealUtil.CloseSession(localID, aiID);
  pcall(function()
    DealManager.ClearWorkingDeal(DealDirection.OUTGOING, localID, aiID);
  end);
end

local function NoteSkip(job, reason)
  job.skipReasons = job.skipReasons or {};
  job.skipReasons[reason] = (job.skipReasons[reason] or 0) + 1;
end

-- Writes both the per-turn ledger (quota/two-way rules) and this run's flow (display).
local function Track(job, mapName, aiID, amount)
  local t = job.turn[mapName];
  t[aiID] = (t[aiID] or 0) + amount;
  local runName = (mapName == "boughtFrom") and "runBought" or "runSold";
  job[runName][aiID] = (job[runName][aiID] or 0) + amount;
end

local Advance;

local function FavorLedgerText(job)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local lines = {};
  table.insert(lines, string.format("余额快照 自己=%d", BatchFlipDealUtil.GetFavorBalance(localID)));
  BatchFlipDealUtil.ForEachMetAi(function(aiID)
    table.insert(lines, string.format("%s=%d",
      BatchFlipDealUtil.GetAiName(aiID),
      BatchFlipDealUtil.GetFavorBalance(aiID)));
  end);
  local moved = {};
  for aiID, n in pairs(job.runBought or {}) do
    table.insert(moved, string.format("从%s买入%d", BatchFlipDealUtil.GetAiName(aiID), n));
  end
  for aiID, n in pairs(job.runSold or {}) do
    table.insert(moved, string.format("卖给%s共%d", BatchFlipDealUtil.GetAiName(aiID), n));
  end
  if #moved > 0 then
    table.insert(lines, "流向:" .. table.concat(moved, "，"));
  end
  return table.concat(lines, " | ");
end

local function FinishJob()
  if m_Job == nil then return; end
  local job = m_Job;
  m_Job = nil;
  for _, aiID in ipairs(job.aiList or {}) do CloseAi(aiID); end
  pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);

  local log = job.log;
  local bits = { VERSION, "真实成交" };
  if job.skipReasons then
    local parts = {};
    for k, v in pairs(job.skipReasons) do
      table.insert(parts, string.format("%s×%d", k, v));
    end
    table.sort(parts);
    if #parts > 0 then table.insert(bits, "跳过:" .. table.concat(parts, ",")); end
  end
  table.insert(bits, FavorLedgerText(job));
  table.insert(bits, string.format(
    "说明:每AI每回合买入/卖出各约上限%d（按回合累计）；只卖给本回合卖过支持给我们的AI；卖价≥%d金/点",
    TURN_TRADE_CAP, SellFloor(job.cfg)));
  if (log.success or 0) <= 0 and (log.note == nil or log.note == "") then
    log.note = "没有可成交的买卖（买入需整叠1–2金，卖出需≥底价）";
  end
  log.note = table.concat(bits, "；") .. ((log.note and ("；" .. log.note)) or "");

  print("BatchFlip " .. VERSION .. ":\n" .. string.gsub(BatchFlipDealUtil.SummaryText(log), "%[NEWLINE%]", "\n"));
  print("BatchFlip " .. VERSION .. " ledger: " .. FavorLedgerText(job));
  if job.onDone then job.onDone(log); end
end

function BatchFlipFavor.ForceAbort(reason)
  if m_Job == nil then
    pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
    return;
  end
  NoteSkip(m_Job, reason or "回合结束中止");
  FinishJob();
end

local function OwnedNow(job)
  return BatchFlipDealUtil.GetFavorBalance(BatchFlipDealUtil.GetLocalPlayerID()) - (job.cfg.FavorKeepOwn or 0);
end

local function BoughtFrom(job, aiID)
  return job.turn.boughtFrom[aiID] or 0;
end

local function SoldTo(job, aiID)
  return job.turn.soldTo[aiID] or 0;
end

local function BuyQuotaLeft(job, aiID)
  return TURN_TRADE_CAP - BoughtFrom(job, aiID);
end

local function SellQuotaLeft(job, aiID)
  return TURN_TRADE_CAP - SoldTo(job, aiID);
end

local function KnownSellPrice(job, aiID)
  local p = job.turn.sellPrice[aiID];
  if p ~= nil and p >= SellFloor(job.cfg) then return p; end
  return nil;
end

-- AI must keep ReserveAiGold after paying for `amount` favor.
local function CanAiPayForSell(aiID, job, amount)
  local n = math.max(1, math.floor(amount or 1));
  local unit = KnownSellPrice(job, aiID) or CHEAP_MAX;
  return BatchFlipDealUtil.AiGoldLeftAfter(aiID, unit * n, job.cfg);
end

-- Mark AIs that hold favor but refuse a cheap sell-to-us (don't dump to them).
-- An AI that already sold to us this turn is two-way even if its window is now closed.
local function MarkWontSellToUs(job, aiID, reason)
  if job == nil or aiID == nil then return; end
  if BoughtFrom(job, aiID) >= 1 then return; end
  local bal = BatchFlipDealUtil.GetFavorBalance(aiID);
  if bal < 1 then return; end
  if job.turn.wontSellToUs[aiID] then return; end
  job.turn.wontSellToUs[aiID] = true;
  NoteSkip(job, "拒卖AI不收货");
  print(string.format("BatchFlip %s mark wont-sell-to-us AI=%d bal=%d (%s)",
    VERSION, aiID, bal, reason or ""));
end

-- Only sell OUR favor to AIs that sold to us this turn (two-way).
local function CanSellFavorToAi(job, aiID)
  if aiID == nil then return false; end
  if SellQuotaLeft(job, aiID) < 1 then return false; end
  if not CanAiPayForSell(aiID, job, 1) then return false; end
  if job.turn.wontSellToUs[aiID] then return false; end
  if BoughtFrom(job, aiID) < 1 then return false; end
  if job.sellDead[aiID] then return false; end
  return true;
end

-- Never request more favor than the AI holds / buy-quota left.
local function BuyAmount(aiID)
  local job = m_Job;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local bal = BatchFlipDealUtil.GetFavorBalance(aiID);
  if bal < 1 then return 0; end
  local quotaLeft = job and BuyQuotaLeft(job, aiID) or TURN_TRADE_CAP;
  if quotaLeft < 1 then return 0; end
  local tradable = BatchFlipDealUtil.MaxFavorTradable(aiID, localID);
  if tradable <= 0 then
    -- Balance>0 but tradable=0 → engine turn buy-quota exhausted.
    return 0;
  end
  return math.max(0, math.floor(math.min(FavorCap(), tradable, bal, quotaLeft)));
end

local function StartSession(kind, aiID, amount)
  local job = m_Job;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  CloseAi(aiID);
  job.probeKind = kind;
  job.awaitAi = aiID;
  job.amount = amount;
  job.waitTicks = 0;
  if DiplomacyManager.FindOpenSessionID(localID, aiID) ~= nil then
    job.step = "session_ready";
    Advance();
  else
    job.step = "wait_session";
    DiplomacyManager.RequestSession(localID, aiID, "MAKE_DEAL");
  end
end

local function RebuildProbeDeal()
  local job = m_Job;
  local kind, aiID, amount = job.probeKind, job.awaitAi, job.amount or 1;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  DealManager.ClearWorkingDeal(DealDirection.OUTGOING, localID, aiID);
  local deal = DealManager.GetWorkingDeal(DealDirection.OUTGOING, localID, aiID);
  if deal == nil then return false; end
  local ok;
  if kind == "buy" then
    ok = BatchFlipDealUtil.AddFavor(deal, aiID, amount) ~= nil;
  else
    ok = BatchFlipDealUtil.AddFavor(deal, localID, amount) ~= nil;
  end
  return ok and BatchFlipDealUtil.Validate(deal);
end

local function SendBareEqualize()
  local job = m_Job;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  job.step = (job.probeKind == "buy") and "wait_buy_eq" or "wait_sell_eq";
  job.waitTicks = 0;
  DealManager.SendWorkingDeal(DealProposalAction.EQUALIZE, localID, job.awaitAi);
end

local function SendEqualizeProbe()
  local job = m_Job;
  if not RebuildProbeDeal() then
    NoteSkip(job, job.probeKind == "buy" and "无法买单" or "无法卖单");
    if job.probeKind == "buy" then
      MarkWontSellToUs(job, job.awaitAi, "无法买单");
    end
    CloseAi(job.awaitAi);
    job.step = "probe_fail";
    Advance();
    return;
  end
  job.step = (job.probeKind == "buy") and "wait_buy_insp" or "wait_sell_insp";
  job.waitTicks = 0;
  DealManager.SendWorkingDeal(DealProposalAction.INSPECT, BatchFlipDealUtil.GetLocalPlayerID(), job.awaitAi);
end

local function HasBuyableAi(job)
  for _, aiID in ipairs(job.aiList or {}) do
    if not job.turn.wontSellToUs[aiID]
        and BuyAmount(aiID) >= 1 and BatchFlipDealUtil.CanSpendMyGold(CHEAP_MAX, job.cfg) then
      return true;
    end
  end
  return false;
end

-- Sort AI list so larger cheap stacks are bought first.
local function SortAiListForBuy(job)
  table.sort(job.aiList, function(a, b)
    local ba = BuyAmount(a);
    local bb = BuyAmount(b);
    if ba ~= bb then return ba > bb; end
    return a < b;
  end);
end

-- After sell alloc: buy again if AIs regained stock and buy-quota remains.
-- Never re-buy when we already cannot sell — that ping-pongs 1 favor forever.
local function MaybeRebuyOrFinish(reason)
  local job = m_Job;
  if job == nil then return; end
  if reason == "no sell target" or reason == "sell exhausted" then
    FinishJob();
    return;
  end
  local moved = (job.log.favorBought or 0) + (job.log.favorSold or 0);
  local progressed = moved > (job.progressMark or 0);
  job.progressMark = moved;
  if progressed and HasBuyableAi(job) and (job.cycle or 1) < MAX_CYCLES then
    job.cycle = (job.cycle or 1) + 1;
    print(string.format("BatchFlip %s re-buy cycle=%d (%s)", VERSION, job.cycle, reason or ""));
    SortAiListForBuy(job);
    job.phase = "buy";
    job.aiIndex = 1;
    job.dumpFailStreak = 0;
    job.step = "next_ai";
    Advance();
    return;
  end
  FinishJob();
end

local TryCommit;

-- Pick the best AI to sell to, given current inventory / quotas / known prices.
local function BeginAllocSell()
  local job = m_Job;
  if OwnedNow(job) < 1 then
    MaybeRebuyOrFinish("inventory empty");
    return;
  end
  if (job.dumpFailStreak or 0) >= #job.aiList then
    print("BatchFlip " .. VERSION .. " sell alloc done (no buyers / caps)");
    MaybeRebuyOrFinish("sell exhausted");
    return;
  end
  -- Known price first (higher better), then sell-quota left, then how much they sold us.
  local function sellScore(aiID)
    if not CanSellFavorToAi(job, aiID) then return -1; end
    local price = KnownSellPrice(job, aiID) or CHEAP_MAX;
    local score = price * 1000;
    score = score + SellQuotaLeft(job, aiID) * 10;
    score = score + math.min(BoughtFrom(job, aiID), 9);
    return score;
  end
  local bestID, bestScore = nil, -1;
  for _, aiID in ipairs(job.aiList) do
    local s = sellScore(aiID);
    if s > bestScore then
      bestScore = s;
      bestID = aiID;
    end
  end
  if bestID == nil or bestScore < 0 then
    NoteSkip(job, "无合适卖出对象");
    MaybeRebuyOrFinish("no sell target");
    return;
  end

  -- Always 1 favor at a fresh EQUALIZE price: the AI's bid drops as it accumulates favor.
  local aiID = bestID;
  job.curAi = aiID;
  job.phase = "sell";
  print(string.format("BatchFlip %s alloc sell → AI=%d last=%s owned=%d",
    VERSION, aiID, tostring(KnownSellPrice(job, aiID)), OwnedNow(job)));
  StartSession("sell", aiID, 1);
end

TryCommit = function(kind, aiID, amount, otg)
  local job = m_Job;
  local cfg = job.cfg;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();

  if kind == "sell" and OwnedNow(job) < amount then return false; end
  if kind == "buy" and not BatchFlipDealUtil.CanSpendMyGold(math.max(otg, 1), cfg) then return false; end
  if kind == "sell" and not BatchFlipDealUtil.AiGoldLeftAfter(aiID, otg, cfg) then return false; end

  CloseAi(aiID);
  if not BatchFlipDealUtil.ClearOutgoing(localID, aiID) then return false; end
  if DiplomacyManager.FindOpenSessionID(localID, aiID) == nil then
    DiplomacyManager.RequestSession(localID, aiID, "MAKE_DEAL");
  end

  local deal = BatchFlipDealUtil.GetWorkingDeal(localID, aiID);
  if deal == nil then return false; end

  local pay = math.max(otg, 1);
  local built;
  if kind == "buy" then
    built = BatchFlipDealUtil.AddFavor(deal, aiID, amount) ~= nil
        and BatchFlipDealUtil.AddGold(deal, localID, pay, 0) ~= nil;
  else
    built = BatchFlipDealUtil.AddFavor(deal, localID, amount) ~= nil
        and BatchFlipDealUtil.AddGold(deal, aiID, pay, 0) ~= nil;
  end
  if not built or not BatchFlipDealUtil.Validate(deal) then
    CloseAi(aiID);
    return false;
  end

  job.log.attempted = job.log.attempted + 1;
  job.commitKind = kind;
  job.commitAi = aiID;
  job.commitAmount = amount;
  job.commitGold = pay;
  job.favorBefore = BatchFlipDealUtil.GetFavorBalance(localID);
  job.goldBefore = BatchFlipDealUtil.GetTreasuryGold(localID);
  job.waitTicks = 0;
  job.step = "wait_commit";
  DealManager.SendWorkingDeal(DealProposalAction.ACCEPTED, localID, aiID);
  return true;
end

-- AI did not take the deal (rejected or timed out).
local function OnCommitFailed(job, why)
  local aiID = job.commitAi;
  CloseAi(aiID);
  NoteSkip(job, why);
  job.log.failed = (job.log.failed or 0) + 1;
  if job.commitKind == "sell" then
    job.sellDead[aiID] = true;
    job.dumpFailStreak = (job.dumpFailStreak or 0) + 1;
    job.step = "do_sell";
    Advance();
    return;
  end
  job.aiIndex = (job.aiIndex or 1) + 1;
  job.step = "next_ai";
  Advance();
end

local function OnCommitTickOrConfirm()
  local job = m_Job;
  if job == nil or job.step ~= "wait_commit" then return; end

  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local favorNow = BatchFlipDealUtil.GetFavorBalance(localID);
  local goldNow = BatchFlipDealUtil.GetTreasuryGold(localID);
  local kind, aiID, want = job.commitKind, job.commitAi, job.commitAmount;
  local expectGold = job.commitGold or 0;

  local dFavorBuy = favorNow - job.favorBefore;
  local dFavorSell = job.favorBefore - favorNow;
  local dGoldGain = goldNow - job.goldBefore;
  local dGoldLost = job.goldBefore - goldNow;

  local ok, realFavor, realGold = false, 0, 0;
  if kind == "buy" then
    if dFavorBuy >= want - 0.1 then
      if expectGold >= 1 and dGoldLost < 1 then
        -- wait for gold to settle
      else
        ok = true;
        realFavor = math.floor(dFavorBuy + 0.1);
        realGold = math.floor(math.max(0, dGoldLost) + 0.1);
      end
    end
  else
    if dFavorSell >= want - 0.1 and dGoldGain >= 1 then
      ok = true;
      realFavor = math.floor(dFavorSell + 0.1);
      realGold = math.floor(dGoldGain + 0.1);
    end
  end

  if ok then
    CloseAi(aiID);
    if kind == "buy" and realGold < 1 then
      NoteSkip(job, "买入未扣金跳过");
      job.log.failed = (job.log.failed or 0) + 1;
      job.aiIndex = job.aiIndex + 1;
      job.step = "next_ai";
      Advance();
      return;
    end
    job.log.success = job.log.success + 1;
    if kind == "buy" then
      job.log.favorBought = job.log.favorBought + realFavor;
      job.log.goldSpent = job.log.goldSpent + realGold;
      BatchFlipDealUtil.RecordTrade(job.log, aiID, "buy", realFavor, realGold, 0);
      Track(job, "boughtFrom", aiID, realFavor);
      job.aiIndex = (job.aiIndex or 1) + 1;
      job.step = "next_ai";
    else
      job.log.favorSold = job.log.favorSold + realFavor;
      job.log.goldEarned = job.log.goldEarned + realGold;
      BatchFlipDealUtil.RecordTrade(job.log, aiID, "sell", realFavor, realGold, 0);
      Track(job, "soldTo", aiID, realFavor);
      job.flips = (job.flips or 0) + 1;
      job.dumpFailStreak = 0;
      job.turn.sellPrice[aiID] = math.max(SellFloor(job.cfg),
        math.floor((realGold / math.max(1, realFavor)) + 0.1));
      job.step = "do_sell";
    end
    Advance();
    return;
  end

  job.waitTicks = (job.waitTicks or 0) + 1;
  if job.waitTicks < COMMIT_WAIT_TICKS then return; end
  OnCommitFailed(job, "成交未生效");
end

local function OnEqualize(dealAction)
  local job = m_Job;
  if job == nil then return; end
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local aiID = job.awaitAi;
  local kind = job.probeKind;
  local amount = job.amount or 1;

  local function FailWindow(buyRefuseReason)
    CloseAi(aiID);
    job.awaitAi = nil;
    if kind == "buy" and buyRefuseReason then
      MarkWontSellToUs(job, aiID, buyRefuseReason);
    end
    if kind == "sell" then
      job.dumpFailStreak = (job.dumpFailStreak or 0) + 1;
      job.step = "do_sell";
      Advance();
      return;
    end
    job.aiIndex = (job.aiIndex or 1) + 1;
    job.step = "next_ai";
    Advance();
  end

  if dealAction == DealProposalAction.EQUALIZE_FAILED then
    NoteSkip(job, kind == "buy" and "买均衡失败" or "卖均衡失败");
    if kind == "sell" then job.sellDead[aiID] = true; end
    FailWindow(kind == "buy" and "买均衡失败" or nil);
    return;
  end

  local goldFrom = (kind == "buy") and localID or aiID;
  local otg, mtg = ReadEqualizedGold(localID, aiID, goldFrom);
  local good;
  if kind == "buy" then
    good = IsGoodBuy(otg, mtg, amount, job.cfg);
  else
    good = IsGoodSell(otg, mtg, amount, job.cfg);
  end
  print(string.format("BatchFlip %s %s phase=%s AI=%d amt=%d OTG=%d MTG=%d good=%s",
    VERSION, kind, tostring(job.phase), aiID, amount, otg, mtg, tostring(good)));

  CloseAi(aiID);
  job.awaitAi = nil;

  if not good then
    if kind == "buy" then
      NoteSkip(job, "买价超窗口");
      FailWindow("买价超窗口");
    else
      NoteSkip(job, "卖价过低");
      job.sellDead[aiID] = true;
      FailWindow(nil);
    end
    return;
  end

  if kind == "sell" then
    job.turn.sellPrice[aiID] = math.max(SellFloor(job.cfg),
      math.floor((otg / math.max(1, amount)) + 0.1));
  end

  job.step = "committing";
  if not TryCommit(kind, aiID, amount, otg) then
    NoteSkip(job, "无法提交");
    FailWindow(kind == "buy" and "无法提交买单" or nil);
  end
end

Advance = function()
  local job = m_Job;
  if job == nil then return; end
  if job.flips >= (job.maxFlips or 200) then FinishJob(); return; end

  if job.step == "session_ready" then
    SendEqualizeProbe();
    return;
  end

  if job.step == "start" then
    print("BatchFlip " .. VERSION .. " buy-all → sell→buy→sell (fill caps)");
    SortAiListForBuy(job);
    job.phase = "buy";
    job.cycle = 1;
    job.aiIndex = 1;
    job.dumpFailStreak = 0;
    job.step = "next_ai";
    Advance();
    return;
  end

  if job.step == "next_ai" then
    -- buy sweep only
    while job.aiIndex <= #job.aiList do
      local aiID = job.aiList[job.aiIndex];
      job.curAi = aiID;
      if BuyQuotaLeft(job, aiID) < 1 then
        NoteSkip(job, "本回合买入额度已满");
        job.aiIndex = job.aiIndex + 1;
      elseif job.turn.wontSellToUs[aiID] then
        NoteSkip(job, "拒卖AI跳过买入");
        job.aiIndex = job.aiIndex + 1;
      elseif not BatchFlipDealUtil.CanSpendMyGold(CHEAP_MAX, job.cfg) then
        NoteSkip(job, "自己留金不足");
        job.aiIndex = job.aiIndex + 1;
      else
        local buyAmt = BuyAmount(aiID);
        local bal = BatchFlipDealUtil.GetFavorBalance(aiID);
        if buyAmt < 1 then
          if bal > 0 then
            NoteSkip(job, "有余额但本回合不可再买");
          else
            NoteSkip(job, "AI无支持可买");
          end
          job.aiIndex = job.aiIndex + 1;
        else
          job.step = "do_buy";
          StartSession("buy", aiID, buyAmt);
          return;
        end
      end
    end
    print(string.format("BatchFlip %s buy sweep done owned=%d → sell alloc", VERSION, OwnedNow(job)));
    job.phase = "sell";
    job.dumpFailStreak = 0;
    job.step = "do_sell";
    BeginAllocSell();
    return;
  end

  if job.step == "do_sell" then
    if OwnedNow(job) < 1 then
      MaybeRebuyOrFinish("sold out, try re-buy");
      return;
    end
    if (job.dumpFailStreak or 0) >= #job.aiList then
      MaybeRebuyOrFinish("sell fail streak");
      return;
    end
    BeginAllocSell();
    return;
  end

  if job.step == "probe_fail" then
    if job.phase == "sell" then
      job.dumpFailStreak = (job.dumpFailStreak or 0) + 1;
      if job.curAi ~= nil then job.sellDead[job.curAi] = true; end
      job.step = "do_sell";
      Advance();
      return;
    end
    if job.probeKind == "buy" and job.curAi ~= nil then
      MarkWontSellToUs(job, job.curAi, "询价失败");
    end
    job.aiIndex = (job.aiIndex or 1) + 1;
    job.step = "next_ai";
    Advance();
  end
end

local function OnDiplomacyStatement(fromPlayer, toPlayer, kVariants)
  local job = m_Job;
  if job == nil then return; end
  if toPlayer ~= BatchFlipDealUtil.GetLocalPlayerID() then return; end
  if job.awaitAi ~= nil and fromPlayer ~= job.awaitAi
      and not (job.step == "wait_commit" and fromPlayer == job.commitAi) then
    return;
  end
  if DiplomacyManager.GetKeyName(kVariants.StatementType) ~= "MAKE_DEAL" then return; end

  local respondingTo = kVariants.RespondingToDealAction;
  local dealAction = kVariants.DealAction;

  if job.step == "wait_session" and fromPlayer == job.awaitAi then
    if respondingTo == 0 or respondingTo == nil then
      job.step = "session_ready";
      Advance();
    end
    return;
  end
  if (job.step == "wait_buy_insp" or job.step == "wait_sell_insp") and fromPlayer == job.awaitAi then
    if RebuildProbeDeal() then SendBareEqualize(); else
      NoteSkip(job, "INSPECT后重建失败");
      if job.probeKind == "buy" then
        MarkWontSellToUs(job, job.awaitAi, "INSPECT后重建失败");
      end
      CloseAi(job.awaitAi);
      job.awaitAi = nil;
      job.step = "probe_fail";
      Advance();
    end
    return;
  end
  if (job.step == "wait_buy_eq" or job.step == "wait_sell_eq") and fromPlayer == job.awaitAi then
    OnEqualize(dealAction);
    return;
  end
  if job.step == "wait_commit" and fromPlayer == job.commitAi then
    local sub = DiplomacyManager.GetKeyName(kVariants.StatementSubType or 0);
    if sub == "HUMAN_ACCEPT_DEAL" or dealAction == DealProposalAction.ACCEPTED then
      OnCommitTickOrConfirm();
    elseif DealProposalAction.REJECTED ~= nil and dealAction == DealProposalAction.REJECTED then
      -- Give balances one more look before treating it as a refusal.
      OnCommitTickOrConfirm();
      if m_Job ~= nil and m_Job.step == "wait_commit" then
        OnCommitFailed(m_Job, "AI拒绝成交");
      end
    end
  end
end

local function OnTick()
  local job = m_Job;
  if job == nil then return; end
  if job.step == "wait_commit" then OnCommitTickOrConfirm(); return; end
  if job.step == "wait_session"
      or job.step == "wait_buy_insp" or job.step == "wait_sell_insp"
      or job.step == "wait_buy_eq" or job.step == "wait_sell_eq" then
    job.waitTicks = (job.waitTicks or 0) + 1;
    if job.waitTicks > 120 then
      if job.step == "wait_buy_insp" or job.step == "wait_sell_insp" then
        NoteSkip(job, "INSPECT超时改EQUALIZE");
        if RebuildProbeDeal() then SendBareEqualize(); return; end
      end
      NoteSkip(job, "询价超时");
      if job.awaitAi ~= nil then CloseAi(job.awaitAi); end
      job.awaitAi = nil;
      job.step = "probe_fail";
      Advance();
    end
  end
end

local function EnsureHandlers()
  if m_HandlersReady then return; end
  m_HandlersReady = true;
  Events.DiplomacyStatement.Add(OnDiplomacyStatement);
  Events.GameCoreEventPublishComplete.Add(OnTick);
end

function BatchFlipFavor.IsBusy()
  return m_Job ~= nil;
end

function BatchFlipFavor.GetVersion()
  return VERSION;
end

function BatchFlipFavor.Start(onDone)
  if m_Job ~= nil then return; end
  EnsureHandlers();

  local cfg = BatchFlipConfig.Get();
  cfg.DryRun = false;
  local log = BatchFlipDealUtil.NewLog();
  if BatchFlipDealUtil.GetFavorType() == nil then
    log.note = VERSION .. "；需要风云变幻（外交支持）";
    if onDone then onDone(log); end
    return;
  end

  local aiList = {};
  BatchFlipDealUtil.ForEachMetAi(function(id) table.insert(aiList, id); end);
  if #aiList == 0 then
    log.note = VERSION .. "；没有可交易的文明";
    if onDone then onDone(log); end
    return;
  end

  local owned = BatchFlipDealUtil.GetFavorBalance(BatchFlipDealUtil.GetLocalPlayerID());
  local maxFlips = math.max(1, cfg.MaxDealsPerClick or 200);
  local turn = GetTurnLedger();

  print(string.format("BatchFlip %s start turn=%d AIs=%d favor=%d (live)", VERSION, turn.turn, #aiList, owned));

  m_Job = {
    cfg = cfg, log = log, onDone = onDone, aiList = aiList, turn = turn,
    aiIndex = 1, step = "start", phase = "buy", cycle = 1,
    flips = 0, maxFlips = maxFlips, skipReasons = {},
    dumpFailStreak = 0,
    runBought = {}, runSold = {}, sellDead = {},
  };
  Advance();
end
