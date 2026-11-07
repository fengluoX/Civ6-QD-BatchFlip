-- ===========================================================================
-- Runs strategic arbitrage → favor arbitrage sequentially.
-- Manual and auto both use the persisted checkbox selection.
-- ===========================================================================

include("BatchFlipConfig");
include("BatchFlipDealUtil");
include("BatchFlipDealSession");
include("BatchFlipStrategic");
include("BatchFlipFavor");

BatchFlipRunner = BatchFlipRunner or {}

local m_Running = false;

function BatchFlipRunner.IsBusy()
  if m_Running then return true; end
  if BatchFlipDealSession ~= nil and BatchFlipDealSession.IsBusy and BatchFlipDealSession.IsBusy() then
    return true;
  end
  if BatchFlipFavor ~= nil and BatchFlipFavor.IsBusy and BatchFlipFavor.IsBusy() then
    return true;
  end
  return false;
end

function BatchFlipRunner.ForceAbort(reason)
  m_Running = false;
  if BatchFlipDealSession ~= nil and BatchFlipDealSession.ForceAbort then
    pcall(function() BatchFlipDealSession.ForceAbort(reason); end);
  end
  if BatchFlipFavor ~= nil and BatchFlipFavor.ForceAbort then
    pcall(function() BatchFlipFavor.ForceAbort(reason); end);
  end
  pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
end

function BatchFlipRunner.GetVersion()
  local bits = {};
  if BatchFlipFavor ~= nil and BatchFlipFavor.GetVersion then
    table.insert(bits, "favor=" .. tostring(BatchFlipFavor.GetVersion()));
  end
  if BatchFlipStrategic ~= nil and BatchFlipStrategic.GetVersion then
    table.insert(bits, "str=" .. tostring(BatchFlipStrategic.GetVersion()));
  end
  return table.concat(bits, ",");
end

-- opts: favor, strategicArb (booleans)
function BatchFlipRunner.Start(opts, onDone)
  if BatchFlipRunner.IsBusy() then
    return false;
  end
  opts = opts or {};
  local merged = BatchFlipDealUtil.NewLog();
  m_Running = true;

  local function finish()
    m_Running = false;
    pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
    if onDone then onDone(merged); end
  end

  local function runFavor()
    if not opts.favor then
      finish();
      return;
    end
    if BatchFlipFavor == nil or BatchFlipFavor.Start == nil then
      merged.note = (merged.note and (merged.note .. "；") or "") .. "外交支持模块未加载";
      finish();
      return;
    end
    BatchFlipFavor.Start(function(log)
      BatchFlipDealUtil.MergeLogs(merged, log);
      finish();
    end);
  end

  print("BatchFlip Runner start " .. BatchFlipRunner.GetVersion()
    .. " strArb=" .. tostring(opts.strategicArb) .. " favor=" .. tostring(opts.favor));
  if opts.strategicArb then
    BatchFlipStrategic.Start(function(log)
      BatchFlipDealUtil.MergeLogs(merged, log);
      runFavor();
    end);
  else
    runFavor();
  end
  return true;
end

function BatchFlipRunner.StartAuto(onDone)
  local cfg = BatchFlipConfig.Get();
  return BatchFlipRunner.Start({
    favor = cfg.RunFavor ~= false,
    strategicArb = cfg.RunStrategicArb == true,
  }, onDone);
end
