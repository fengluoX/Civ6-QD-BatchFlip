-- ===========================================================================
-- Gameplay-context test helpers exposed to the UI (single player only).
-- UI scripts cannot change game state; they call ExposedMembers.BatchFlipDebug.
-- ===========================================================================

-- Stockpile queries take the ResourceType string (index returns 0 for the cap).
local function StockInfo(res, resourceIndex)
  local resourceType = GameInfo.Resources[resourceIndex].ResourceType;
  local have = math.floor(res:GetResourceAmount(resourceType) or 0);
  local cap = 0;
  pcall(function() cap = math.floor(res:GetResourceStockpileCap(resourceType) or 0); end);
  return have, cap;
end

-- Adds up to `amount` of a resource, clamped to the stockpile cap.
-- Returns ok, amountNow, cap, message.
local function AddResource(playerID, resourceIndex, amount)
  local p = Players[playerID];
  if p == nil then return false, 0, 0, "玩家不存在"; end
  local res = p:GetResources();
  local have, cap = StockInfo(res, resourceIndex);
  local add = amount;
  if cap > 0 then add = math.min(amount, cap - have); end
  if add <= 0 then return true, have, cap, "已到上限"; end
  local ok, err = pcall(function() res:ChangeResourceAmount(resourceIndex, add); end);
  if not ok then return false, have, cap, tostring(err); end
  have, cap = StockInfo(res, resourceIndex);
  print(string.format("BatchFlip Debug: player %d resource %d +%d → %d/%d", playerID, resourceIndex, add, have, cap));
  return true, have, cap, "";
end

ExposedMembers.BatchFlipDebug = ExposedMembers.BatchFlipDebug or {};
ExposedMembers.BatchFlipDebug.AddResource = AddResource;
print("BatchFlip Debug: gameplay helpers ready");
