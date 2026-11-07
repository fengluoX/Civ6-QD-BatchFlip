-- ===========================================================================
-- Generic resource deal executor driven by a planner.
--
-- Each step: planner.Next(job) returns one action
--   { side = "sell"|"buy", aiID, resourceIndex, amount, duration, label }
-- The executor lists the resource, EQUALIZEs, and hands the fresh quote to
-- planner.OnQuote(job, action, quote) → true to commit at exactly that quote.
-- Results come back through planner.OnTraded / planner.OnFailed.
-- Prices are never reused across deals: every commit follows its own EQUALIZE.
-- ===========================================================================

include("BatchFlipConfig");
include("BatchFlipDealUtil");
include("qd_utils");

BatchFlipDealSession = BatchFlipDealSession or {}

local COMMIT_WAIT_TICKS = 60;
local SESSION_WAIT_TICKS = 120;

local m_Job = nil;
local m_HandlersReady = false;

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

local function ReadDealResource(deal, fromID, resourceIndex)
  if deal == nil then return nil; end
  local total = nil;
  for dealItem in deal:Items() do
    if dealItem:GetFromPlayerID() == fromID and dealItem:GetType() == DealItemTypes.RESOURCES
        and dealItem:GetValueType() == resourceIndex then
      total = (total or 0) + math.floor(dealItem:GetAmount() or 0);
    end
  end
  return total;
end

-- Returns otg, mtg, resource amount actually left in the equalized deal.
local function ReadEqualized(localID, aiID, goldFromPlayerID, resFromID, resourceIndex)
  pcall(function()
    DealManager.CopyIncomingToOutgoingWorkingDeal(localID, aiID);
  end);
  local deal = BatchFlipDealUtil.GetWorkingDeal(localID, aiID);
  local otg, mtg = ReadDealGold(deal, goldFromPlayerID);
  local amt = ReadDealResource(deal, resFromID, resourceIndex);
  if otg <= 0 and mtg <= 0 then
    local incoming = nil;
    pcall(function()
      incoming = DealManager.GetWorkingDeal(DealDirection.INCOMING, localID, aiID);
    end);
    local iOtg, iMtg = ReadDealGold(incoming, goldFromPlayerID);
    if (iOtg + iMtg) > (otg + mtg) then
      otg, mtg = iOtg, iMtg;
      amt = ReadDealResource(incoming, resFromID, resourceIndex) or amt;
    end
  end
  return otg, mtg, amt;
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
  job.log.skipped = (job.log.skipped or 0) + 1;
end

BatchFlipDealSession.NoteSkip = NoteSkip;

local Advance;

local function FinishJob()
  if m_Job == nil then return; end
  local job = m_Job;
  m_Job = nil;
  if job.planner.OnFinish then pcall(job.planner.OnFinish, job); end
  for aiID, _ in pairs(job.touched or {}) do CloseAi(aiID); end
  pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);

  local bits = { job.tag or "资源成交" };
  if job.skipReasons then
    local parts = {};
    for k, v in pairs(job.skipReasons) do
      table.insert(parts, string.format("%s×%d", k, v));
    end
    table.sort(parts);
    if #parts > 0 then table.insert(bits, "跳过:" .. table.concat(parts, ",")); end
  end
  table.insert(bits, string.format("会话%d/%d", job.sessions or 0, job.maxSessions or 0));
  job.log.note = table.concat(bits, "；") .. ((job.log.note and ("；" .. job.log.note)) or "");
  print("BatchFlip " .. (job.tag or "Session") .. " done success=" .. tostring(job.log.success));
  if job.onDone then job.onDone(job.log); end
end

local function Fail(job, a, reason)
  if reason then NoteSkip(job, reason); end
  if job.planner.OnFailed then job.planner.OnFailed(job, a, reason); end
end

-- Rebuild the working deal with just the resource item (no gold yet).
local function BuildResourceDeal(a)
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  pcall(function() DealManager.ClearWorkingDeal(DealDirection.OUTGOING, localID, a.aiID); end);
  local deal = BatchFlipDealUtil.GetWorkingDeal(localID, a.aiID);
  if deal == nil then return false; end
  local fromID = (a.side == "sell") and localID or a.aiID;
  return BatchFlipDealUtil.AddResource(deal, fromID, a.resourceIndex, a.amount, a.duration or 30) ~= nil;
end

local function SendEqualize()
  local job = m_Job;
  local a = job.action;
  if not BuildResourceDeal(a) then
    CloseAi(a.aiID);
    job.awaitAi = nil;
    Fail(job, a, "无法上架资源");
    Advance();
    return;
  end
  job.step = "wait_eq";
  job.waitTicks = 0;
  DealManager.SendWorkingDeal(DealProposalAction.EQUALIZE, BatchFlipDealUtil.GetLocalPlayerID(), a.aiID);
end

-- Same handshake as the favor engine: INSPECT first, then rebuild + EQUALIZE.
local function ListAndInspect()
  local job = m_Job;
  local a = job.action;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  if not BatchFlipDealUtil.ClearOutgoing(localID, a.aiID) or not BuildResourceDeal(a) then
    CloseAi(a.aiID);
    job.awaitAi = nil;
    Fail(job, a, "无法上架资源");
    Advance();
    return;
  end
  job.step = "wait_insp";
  job.waitTicks = 0;
  DealManager.SendWorkingDeal(DealProposalAction.INSPECT, localID, a.aiID);
end

local function StartActionSession(a)
  local job = m_Job;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  job.action = a;
  job.touched[a.aiID] = true;
  CloseAi(a.aiID);
  job.awaitAi = a.aiID;
  job.waitTicks = 0;
  job.sessions = (job.sessions or 0) + 1;
  print(string.format("BatchFlip %s %s AI=%d %s×%d", job.tag, a.side, a.aiID,
    tostring(a.label), a.amount));
  if DiplomacyManager.FindOpenSessionID(localID, a.aiID) ~= nil then
    ListAndInspect();
  else
    job.step = "wait_session";
    DiplomacyManager.RequestSession(localID, a.aiID, "MAKE_DEAL");
  end
end

local function TryCommit(a, q)
  local job = m_Job;
  local cfg = job.cfg;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local aiID = a.aiID;

  if a.side == "sell" then
    if q.otg > 0 and not BatchFlipDealUtil.AiGoldLeftAfter(aiID, q.otg, cfg) then
      NoteSkip(job, "AI留金不足");
      return false;
    end
  elseif not BatchFlipDealUtil.CanSpendMyGold(math.max(q.otg, 1), cfg) then
    NoteSkip(job, "自己留金不足");
    return false;
  end
  CloseAi(aiID);
  if not BatchFlipDealUtil.ClearOutgoing(localID, aiID) then return false; end
  if DiplomacyManager.FindOpenSessionID(localID, aiID) == nil then
    DiplomacyManager.RequestSession(localID, aiID, "MAKE_DEAL");
  end
  local deal = BatchFlipDealUtil.GetWorkingDeal(localID, aiID);
  if deal == nil then return false; end

  local resFrom = (a.side == "sell") and localID or aiID;
  local goldFrom = (a.side == "sell") and aiID or localID;
  local otg, mtg = q.otg, q.mtg;
  if a.side == "buy" and otg < 1 and mtg <= 0 then otg = 1; end
  local built = BatchFlipDealUtil.AddResource(deal, resFrom, a.resourceIndex, q.amount, a.duration or 30) ~= nil;
  if built and otg > 0 then built = BatchFlipDealUtil.AddGold(deal, goldFrom, otg, 0) ~= nil; end
  if built and mtg > 0 then built = BatchFlipDealUtil.AddGold(deal, goldFrom, mtg, 30) ~= nil; end
  if not built or not BatchFlipDealUtil.Validate(deal) then return false; end

  job.log.attempted = (job.log.attempted or 0) + 1;
  job.goldBefore = BatchFlipDealUtil.GetTreasuryGold(localID);
  job.resBefore = BatchFlipDealUtil.GetResourceAmount(localID, a.resourceIndex);
  job.commitAction = a;
  job.commitQuote = q;
  job.step = "wait_commit";
  job.waitTicks = 0;
  DealManager.SendWorkingDeal(DealProposalAction.ACCEPTED, localID, aiID);
  return true;
end

local function OnCommitFailed(job, why)
  local a = job.commitAction;
  CloseAi(a.aiID);
  job.log.failed = (job.log.failed or 0) + 1;
  Fail(job, a, why);
  Advance();
end

local function OnCommitTickOrConfirm()
  local job = m_Job;
  if job == nil or job.step ~= "wait_commit" then return; end
  local a, q = job.commitAction, job.commitQuote;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local goldNow = BatchFlipDealUtil.GetTreasuryGold(localID);
  local resNow = BatchFlipDealUtil.GetResourceAmount(localID, a.resourceIndex);
  local dGold = goldNow - (job.goldBefore or goldNow);
  local dRes = resNow - (job.resBefore or resNow);

  local ok = false;
  if a.side == "sell" then
    ok = dRes < 0 or dGold >= 1;
  else
    ok = dRes > 0 or dGold <= -1;
  end
  if not ok then
    job.waitTicks = (job.waitTicks or 0) + 1;
    if job.waitTicks >= COMMIT_WAIT_TICKS then OnCommitFailed(job, "成交未生效"); end
    return;
  end

  CloseAi(a.aiID);
  local realAmt = math.abs(dRes);
  if realAmt < 1 then realAmt = q.amount; end
  local realGold = math.floor(math.abs(dGold) + 0.1);
  if realGold < 1 then realGold = q.otg; end
  job.log.success = (job.log.success or 0) + 1;
  if a.side == "sell" then
    job.log.goldEarned = (job.log.goldEarned or 0) + realGold;
    job.log.resSold = (job.log.resSold or 0) + realAmt;
  else
    job.log.goldSpent = (job.log.goldSpent or 0) + realGold;
    job.log.resBought = (job.log.resBought or 0) + realAmt;
  end
  BatchFlipDealUtil.RecordTrade(job.log, a.aiID, a.side, realAmt, realGold, q.mtg, a.label, a.resourceIndex);
  if job.planner.OnTraded then
    job.planner.OnTraded(job, a, { amount = realAmt, gold = realGold, value = q.value, mtg = q.mtg });
  end
  Advance();
end

local function OnEqualize(dealAction)
  local job = m_Job;
  if job == nil then return; end
  local a = job.action;
  local localID = BatchFlipDealUtil.GetLocalPlayerID();
  local aiID = a.aiID;

  if dealAction == DealProposalAction.EQUALIZE_FAILED then
    CloseAi(aiID);
    job.awaitAi = nil;
    Fail(job, a, "均衡失败");
    Advance();
    return;
  end

  local goldFrom = (a.side == "buy") and localID or aiID;
  local resFrom = (a.side == "sell") and localID or aiID;
  local otg, mtg, amt = ReadEqualized(localID, aiID, goldFrom, resFrom, a.resourceIndex);
  local q = {
    otg = otg, mtg = mtg,
    value = BatchFlipDealUtil.GoldValue(otg, mtg),
    amount = (amt ~= nil and amt >= 1) and amt or a.amount,
  };
  print(string.format("BatchFlip %s quote %s AI=%d %s×%d OTG=%d MTG=%d val=%d",
    job.tag, a.side, aiID, tostring(a.label), q.amount, otg, mtg, q.value));
  CloseAi(aiID);
  job.awaitAi = nil;

  if not job.planner.OnQuote(job, a, q) then
    Advance();
    return;
  end
  if not TryCommit(a, q) then
    CloseAi(aiID);
    Fail(job, a, "无法提交");
    Advance();
  end
end

Advance = function()
  local job = m_Job;
  if job == nil then return; end
  if (job.sessions or 0) >= (job.maxSessions or 200) then
    NoteSkip(job, "会话上限");
    FinishJob();
    return;
  end
  local a = job.planner.Next(job);
  if a == nil then
    FinishJob();
    return;
  end
  StartActionSession(a);
end

local function OnDiplomacyStatement(fromPlayer, toPlayer, kVariants)
  local job = m_Job;
  if job == nil then return; end
  if toPlayer ~= BatchFlipDealUtil.GetLocalPlayerID() then return; end
  if DiplomacyManager.GetKeyName(kVariants.StatementType) ~= "MAKE_DEAL" then return; end
  local dealAction = kVariants.DealAction;
  local respondingTo = kVariants.RespondingToDealAction;

  if job.step == "wait_session" and fromPlayer == job.awaitAi then
    if respondingTo == 0 or respondingTo == nil then
      ListAndInspect();
    end
    return;
  end

  if job.step == "wait_insp" and fromPlayer == job.awaitAi then
    SendEqualize();
    return;
  end

  if job.step == "wait_eq" and fromPlayer == job.awaitAi then
    OnEqualize(dealAction);
    return;
  end

  if job.step == "wait_commit" and job.commitAction ~= nil and fromPlayer == job.commitAction.aiID then
    local sub = DiplomacyManager.GetKeyName(kVariants.StatementSubType or 0);
    if sub == "HUMAN_ACCEPT_DEAL" or dealAction == DealProposalAction.ACCEPTED then
      OnCommitTickOrConfirm();
    elseif DealProposalAction.REJECTED ~= nil and dealAction == DealProposalAction.REJECTED then
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
  if job.step == "wait_session" or job.step == "wait_insp" or job.step == "wait_eq" then
    job.waitTicks = (job.waitTicks or 0) + 1;
    if job.waitTicks > SESSION_WAIT_TICKS then
      if job.step == "wait_insp" then
        NoteSkip(job, "INSPECT超时改EQUALIZE");
        SendEqualize();
        return;
      end
      if job.awaitAi ~= nil then CloseAi(job.awaitAi); end
      job.awaitAi = nil;
      Fail(job, job.action, "询价超时");
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

function BatchFlipDealSession.IsBusy()
  return m_Job ~= nil;
end

function BatchFlipDealSession.ForceAbort(reason)
  if m_Job == nil then
    pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
    return;
  end
  NoteSkip(m_Job, reason or "中止");
  FinishJob();
end

-- planner = { Next(job) → action|nil, OnQuote(job, a, q) → bool,
--             OnTraded(job, a, r), OnFailed(job, a, reason) }
-- job.state is free for the planner (opts.state).
function BatchFlipDealSession.Start(planner, opts, onDone)
  if m_Job ~= nil then return; end
  EnsureHandlers();
  opts = opts or {};
  local cfg = BatchFlipConfig.Get();
  m_Job = {
    cfg = cfg,
    log = opts.log or BatchFlipDealUtil.NewLog(),
    onDone = onDone,
    tag = opts.tag or "Session",
    planner = planner,
    state = opts.state or {},
    step = "start",
    sessions = 0,
    maxSessions = opts.maxSessions or cfg.MaxSessions or 200,
    skipReasons = {},
    touched = {},
  };
  print(string.format("BatchFlip %s start maxSessions=%d", m_Job.tag, m_Job.maxSessions));
  Advance();
end
