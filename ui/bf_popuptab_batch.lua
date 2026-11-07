include("qd_utils");
include("BatchFlipConfig");
include("BatchFlipDealUtil");
include("BatchFlipDealSession");
include("BatchFlipStrategic");
include("BatchFlipFavor");
include("BatchFlipRunner");

print("BatchFlip: module favor=" .. tostring(BatchFlipFavor ~= nil)
    .. " ver=" .. tostring(BatchFlipFavor and BatchFlipFavor.GetVersion and BatchFlipFavor.GetVersion())
    .. " runner=" .. tostring(BatchFlipRunner ~= nil));

local REQUIRED_AUTO_VER = "v38";

local function FlipVersion()
    if BatchFlipFavor ~= nil and BatchFlipFavor.GetVersion ~= nil then
        return tostring(BatchFlipFavor.GetVersion());
    end
    return "?";
end

local function HasSafeAutoEngine()
    return FlipVersion() == REQUIRED_AUTO_VER;
end

local BF_TAB_BATCH = "TAB_BF_BATCH";

local FALLBACK_ZH = {
    LOC_BF_BATCH_TAB = "批量倒卖",
    LOC_BF_AI_GOLD = "AI留金 ≥",
    LOC_BF_MY_GOLD = "自己留金 ≥",
    LOC_BF_MAX_DEALS = "成交上限",
    LOC_BF_COL_ACTION = "批量倒卖",
    LOC_BF_BTN_FAVOR = "开始倒卖",
    LOC_BF_BTN_AUTO_START = "启动自动执行",
    LOC_BF_BTN_AUTO_STOP = "停止自动执行",
    LOC_BF_ACTION_DESC = "勾选后点开始倒卖；自动执行每回合跑同样的勾选项。战略套利：买空持有≥40的AI，再一次卖40个给它（持有0时双倍价），再买回，循环榨干其金币/回合金。",
    LOC_BF_LAST_RESULT = "执行结果",
    LOC_BF_HINT_LIVE = "勾选品类后点开始倒卖，或启动自动执行。",
    LOC_BF_BTN_EXPAND = "展开明细",
    LOC_BF_BTN_COLLAPSE = "收起明细",
    LOC_BF_MANUAL_CATS = "品类",
    LOC_BF_CHK_FAVOR = "外交支持套利",
    LOC_BF_CHK_STRATEGIC_ARB = "战略资源套利",
};

local m_LastLog = nil;
local m_ShowDetail = false;
local m_AutoLastTurn = -1;
local m_AutoPendingTurn = nil;
local m_AutoDeferTicks = 0;
local AUTO_DEFER_TICKS = 60;
local LOG_VIEW_W = 1100;
local LOG_VIEW_H = 240; -- minimum
local LOG_VIEW_TOP = 340; -- sum of the fixed rows (size + offset) above LogFrame in the XML

-- ver bump resets enabled so hot-reload / new session never inherits "on".
if BatchFlipAutoState == nil or BatchFlipAutoState.ver ~= 38 then
    BatchFlipAutoState = { enabled = false, bound = false, ver = 38 };
end

local function L(tag)
    local text = Locale.Lookup(tag);
    if text == nil or text == tag or string.find(text, "^LOC_") then
        return FALLBACK_ZH[tag] or tag;
    end
    return text;
end

local function SafeSetText(control, text)
    if control == nil then return; end
    pcall(function() control:SetText(tostring(text)); end);
end

local function ReadEditNumber(control, fallback)
    if control == nil then return fallback; end
    local ok, text = pcall(function() return control:GetText(); end);
    if not ok then return fallback; end
    return tonumber(text) or fallback;
end

local function WriteEditNumber(control, value)
    if control == nil then return; end
    pcall(function() control:SetText(tostring(value)); end);
end

-- Same CheckBox API as QD NotificationToggle (IsChecked / SetCheck).
local function ReadCheck(control, fallback)
    if control == nil then return fallback; end
    local ok, v = pcall(function() return control:IsChecked(); end);
    if ok and v ~= nil then return v == true; end
    return fallback == true;
end

local function WriteCheck(control, on)
    if control == nil then return; end
    pcall(function() control:SetCheck(on == true); end);
end

local ApplyUiToConfig; -- forward decl (used by checkbox click)

-- Native CheckBox already toggles on click; only persist settings.
local function BindCategoryToggle(control)
    if control == nil then return; end
    control:RegisterCallback(Mouse.eLClick, function()
        if ApplyUiToConfig ~= nil then ApplyUiToConfig(); end
    end);
end

local function IsAutoRun()
    return BatchFlipAutoState ~= nil and BatchFlipAutoState.enabled == true;
end

-- AutoRun is session memory only — never restored from save / GameConfiguration.
local function SyncAutoFromConfig()
    if BatchFlipAutoState == nil then
        BatchFlipAutoState = { enabled = false, bound = false, ver = 38 };
    end
    pcall(function()
        if BatchFlipConfig ~= nil and BatchFlipConfig.Get ~= nil then
            local cfg = BatchFlipConfig.Get();
            if cfg ~= nil then
                cfg.AutoRun = BatchFlipAutoState.enabled == true;
            end
        end
    end);
end

local function SetAutoRun(on)
    on = on == true;
    if BatchFlipAutoState == nil then
        BatchFlipAutoState = { enabled = false, bound = false, ver = 38 };
    end
    BatchFlipAutoState.enabled = on;
    pcall(function()
        if BatchFlipConfig ~= nil and BatchFlipConfig.Get ~= nil then
            local cfg = BatchFlipConfig.Get();
            if cfg ~= nil then
                cfg.AutoRun = on;
                -- Save() always writes BF_AutoRun=0; only flush other settings.
                BatchFlipConfig.Save();
            end
        end
    end);
end

local function EstimateLogHeight(text)
    local s = tostring(text or "");
    s = string.gsub(s, "%[NEWLINE%]", "\n");
    local rows = 0;
    for line in string.gmatch(s .. "\n", "(.-)\n") do
        local chars = string.len(line);
        rows = rows + math.max(1, math.ceil(chars / 90));
    end
    if rows < 1 then rows = 1; end
    return math.max(48, rows * 22);
end

-- Log view fills whatever height the QD popup leaves below the fixed rows.
local function LogViewHeight()
    local h = LOG_VIEW_H;
    pcall(function()
        local free = Controls.BatchRoot:GetSizeY() - LOG_VIEW_TOP - 12;
        if free > h then h = free; end
    end);
    return h;
end

local function RefreshLogScroll(text)
    pcall(function()
        local h = LogViewHeight();
        if Controls.LogFrame ~= nil then
            Controls.LogFrame:SetSizeVal(LOG_VIEW_W, h);
        end
        if Controls.LogScroll ~= nil then
            Controls.LogScroll:SetSizeVal(LOG_VIEW_W, h);
        end
        if Controls.LogLabel ~= nil then
            Controls.LogLabel:SetWrapWidth(1020);
            Controls.LogLabel:SetSizeVal(1020, EstimateLogHeight(text));
            if Controls.LogLabel.CalculateSize ~= nil then
                Controls.LogLabel:CalculateSize();
            end
            Controls.LogLabel:ReprocessAnchoring();
        end
        if Controls.LogStack ~= nil then
            Controls.LogStack:CalculateSize();
            Controls.LogStack:ReprocessAnchoring();
        end
        if Controls.LogScroll ~= nil then
            if Controls.LogScroll.CalculateInternalSize ~= nil then
                Controls.LogScroll:CalculateInternalSize();
            end
            Controls.LogScroll:ReprocessAnchoring();
            if Controls.LogScroll.SetScrollValue ~= nil then
                Controls.LogScroll:SetScrollValue(0);
            end
        end
    end);
end

local function SetLog(text)
    SafeSetText(Controls.LogLabel, text);
    RefreshLogScroll(text);
    print("BatchFlip: " .. tostring(text));
end

local function UpdateDetailButton()
    local hasLog = m_LastLog ~= nil and m_LastLog.trades ~= nil and #(m_LastLog.trades) > 0;
    if Controls.BtnToggleDetail ~= nil then
        pcall(function()
            Controls.BtnToggleDetail:SetDisabled(not hasLog);
            Controls.BtnToggleDetail:SetText(m_ShowDetail and L("LOC_BF_BTN_COLLAPSE") or L("LOC_BF_BTN_EXPAND"));
        end);
    end
end

local function UpdateAutoButton()
    if Controls.BtnAutoRun == nil then return; end
    local on = IsAutoRun();
    local label = on and L("LOC_BF_BTN_AUTO_STOP") or L("LOC_BF_BTN_AUTO_START");
    SafeSetText(Controls.BtnAutoRun, label);
    print("BatchFlip: auto button sync enabled=" .. tostring(on) .. " label=" .. tostring(label));
end

local function ShowResultLog(log, detailed)
    if log == nil then
        SetLog(L("LOC_BF_HINT_LIVE"));
        UpdateDetailButton();
        return;
    end
    local text;
    if BatchFlipDealUtil ~= nil and BatchFlipDealUtil.SummaryText ~= nil then
        text = BatchFlipDealUtil.SummaryText(log, detailed == true);
        text = string.gsub(text, "%[NEWLINE%]", "[NEWLINE]");
    else
        text = tostring(log.note or "");
    end
    SetLog(text);
    UpdateDetailButton();
end

local function OnToggleDetail()
    if m_LastLog == nil or m_LastLog.trades == nil or #(m_LastLog.trades) == 0 then
        return;
    end
    m_ShowDetail = not m_ShowDetail;
    ShowResultLog(m_LastLog, m_ShowDetail);
end

ApplyUiToConfig = function()
    local cfg = BatchFlipConfig.Get();
    cfg.ReserveAiGold = ReadEditNumber(Controls.EditAiGold, cfg.ReserveAiGold);
    cfg.ReserveMyGold = ReadEditNumber(Controls.EditMyGold, cfg.ReserveMyGold);
    cfg.MaxDealsPerClick = ReadEditNumber(Controls.EditMaxDeals, cfg.MaxDealsPerClick);
    cfg.DryRun = false;
    cfg.AutoRun = IsAutoRun();
    cfg.RunFavor = ReadCheck(Controls.ChkFavor, cfg.RunFavor);
    cfg.RunStrategicArb = ReadCheck(Controls.ChkStrategicArb, cfg.RunStrategicArb);
    BatchFlipConfig.Save();
end

local function ApplyConfigToUi()
    local cfg = BatchFlipConfig.Get();
    WriteEditNumber(Controls.EditAiGold, cfg.ReserveAiGold);
    WriteEditNumber(Controls.EditMyGold, cfg.ReserveMyGold);
    WriteEditNumber(Controls.EditMaxDeals, cfg.MaxDealsPerClick);
    WriteCheck(Controls.ChkFavor, cfg.RunFavor ~= false);
    WriteCheck(Controls.ChkStrategicArb, cfg.RunStrategicArb == true);
    SyncAutoFromConfig();
    UpdateAutoButton();
end

local function BindStaticTexts()
    SafeSetText(Controls.LblAiGold, L("LOC_BF_AI_GOLD"));
    SafeSetText(Controls.LblMyGold, L("LOC_BF_MY_GOLD"));
    SafeSetText(Controls.LblMaxDeals, L("LOC_BF_MAX_DEALS"));
    SafeSetText(Controls.ColHeader, L("LOC_BF_COL_ACTION"));
    SafeSetText(Controls.BtnFavor, L("LOC_BF_BTN_FAVOR"));
    SafeSetText(Controls.ActionDesc, L("LOC_BF_ACTION_DESC"));
    SafeSetText(Controls.ResultHeader, L("LOC_BF_LAST_RESULT"));
    if Controls.LblManualCats ~= nil then SafeSetText(Controls.LblManualCats, L("LOC_BF_MANUAL_CATS")); end
    if Controls.LblFavor ~= nil then SafeSetText(Controls.LblFavor, L("LOC_BF_CHK_FAVOR")); end
    if Controls.LblStrategicArb ~= nil then SafeSetText(Controls.LblStrategicArb, L("LOC_BF_CHK_STRATEGIC_ARB")); end
    UpdateDetailButton();
    SyncAutoFromConfig();
    UpdateAutoButton();
end

local function SetBusyUi(busy)
    if Controls.BtnFavor ~= nil then
        pcall(function() Controls.BtnFavor:SetDisabled(busy); end);
    end
    if Controls.BtnToggleDetail ~= nil and busy then
        pcall(function() Controls.BtnToggleDetail:SetDisabled(true); end);
    end
end

local function ReadRunOpts()
    ApplyUiToConfig();
    local cfg = BatchFlipConfig.Get();
    return {
        favor = cfg.RunFavor ~= false,
        strategicArb = cfg.RunStrategicArb == true,
    };
end

local function StartBatchFlip(fromAuto)
    if BatchFlipRunner == nil or BatchFlipRunner.Start == nil then
        m_LastLog = nil;
        m_ShowDetail = false;
        SetLog("倒卖编排未加载。请完全退出游戏后再开。");
        UpdateDetailButton();
        return false;
    end
    if fromAuto and not HasSafeAutoEngine() then
        SetAutoRun(false);
        m_AutoPendingTurn = nil;
        SetLog("当前仍是 " .. FlipVersion() .. "，自动执行已禁用。请结束 CivilizationVI_DX12 后重开加载 "
            .. REQUIRED_AUTO_VER .. "。");
        UpdateAutoButton();
        return false;
    end
    if BatchFlipRunner.IsBusy and BatchFlipRunner.IsBusy() then
        if not fromAuto then
            SetLog("正在询价/成交中，请稍候…");
        end
        return false;
    end

    if fromAuto then
        pcall(function() LuaEvents.QD_OpenBatchTab(); end);
    end

    local opts = ReadRunOpts();
    if not opts.favor and not opts.strategicArb then
        if not fromAuto then SetLog("请至少勾选一种品类。"); end
        return false;
    end

    local ver = (BatchFlipRunner.GetVersion and BatchFlipRunner.GetVersion()) or FlipVersion();
    m_LastLog = nil;
    m_ShowDetail = false;
    UpdateDetailButton();
    local prefix = fromAuto and "自动执行 " or "正在倒卖 ";
    SetLog(prefix .. ver .. "，请稍候…");
    SetBusyUi(true);
    UpdateAutoButton();

    local goldBefore = BatchFlipDealUtil.GetTreasuryGold(BatchFlipDealUtil.GetLocalPlayerID());
    local favorBefore = BatchFlipDealUtil.GetFavorBalance(BatchFlipDealUtil.GetLocalPlayerID());

    local started = BatchFlipRunner.Start(opts, function(log)
        pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
        local goldAfter = BatchFlipDealUtil.GetTreasuryGold(BatchFlipDealUtil.GetLocalPlayerID());
        local favorAfter = BatchFlipDealUtil.GetFavorBalance(BatchFlipDealUtil.GetLocalPlayerID());
        local autoTag = fromAuto and "自动；" or "";
        log.note = (log.note and (log.note .. "；") or "")
            .. autoTag
            .. string.format("结算后变化：金%+d / 支持%+d", goldAfter - goldBefore, favorAfter - favorBefore);
        m_LastLog = log;
        m_ShowDetail = false;
        ShowResultLog(m_LastLog, false);
        SetBusyUi(false);
        UpdateAutoButton();
        if fromAuto then
            pcall(function() LuaEvents.QD_CloseBatchPopup(); end);
        end
    end);

    if not started then
        SetBusyUi(false);
        SetLog("启动失败（可能已在执行中）。");
        return false;
    end
    return true;
end

local function OnFavor()
    StartBatchFlip(false);
end

local function OnToggleAuto()
    local nextOn = not IsAutoRun();
    if nextOn and not HasSafeAutoEngine() then
        SetLog("自动执行需要 " .. REQUIRED_AUTO_VER .. "（当前 " .. FlipVersion()
            .. "）。请先结束 CivilizationVI_DX12 再重开。");
        UpdateAutoButton();
        return;
    end
    SetAutoRun(nextOn);
    UpdateAutoButton();
    if nextOn then
        local turn = Game.GetCurrentGameTurn() or 0;
        SetLog(string.format("已启动自动（仅本次游戏，不写入存档）：每回合按勾选项执行；当前回合%d。", turn));
        if turn > m_AutoLastTurn then
            m_AutoPendingTurn = turn;
            m_AutoDeferTicks = 0;
        end
    else
        m_AutoPendingTurn = nil;
        SetLog("已停止自动执行。");
    end
    print("BatchFlip: AutoRun=" .. tostring(IsAutoRun()));
end

local function TryConsumeAutoPending()
    if not IsAutoRun() then
        m_AutoPendingTurn = nil;
        return;
    end
    if not HasSafeAutoEngine() then
        SetAutoRun(false);
        m_AutoPendingTurn = nil;
        UpdateAutoButton();
        return;
    end
    if m_AutoPendingTurn == nil then return; end
    if BatchFlipRunner ~= nil and BatchFlipRunner.IsBusy and BatchFlipRunner.IsBusy() then
        return;
    end

    m_AutoDeferTicks = (m_AutoDeferTicks or 0) + 1;
    if m_AutoDeferTicks < AUTO_DEFER_TICKS then
        return;
    end

    local turn = m_AutoPendingTurn;
    m_AutoPendingTurn = nil;
    m_AutoDeferTicks = 0;
    if turn <= m_AutoLastTurn then return; end
    m_AutoLastTurn = turn;
    print(string.format("BatchFlip: auto-run at turn %d", turn));
    StartBatchFlip(true);
end

BatchFlip_OnLocalPlayerTurnBegin = function()
    if not IsAutoRun() then return; end
    local turn = Game.GetCurrentGameTurn() or 0;
    if turn <= m_AutoLastTurn then return; end
    m_AutoPendingTurn = turn;
    m_AutoDeferTicks = 0;
    print(string.format("BatchFlip: auto pending turn %d", turn));
end

BatchFlip_OnLocalPlayerTurnEnd = function()
    m_AutoPendingTurn = nil;
    m_AutoDeferTicks = 0;
    if BatchFlipRunner ~= nil and BatchFlipRunner.ForceAbort ~= nil then
        pcall(function() BatchFlipRunner.ForceAbort("回合结束中止"); end);
    elseif BatchFlipFavor ~= nil and BatchFlipFavor.ForceAbort ~= nil then
        pcall(function() BatchFlipFavor.ForceAbort("回合结束中止"); end);
    else
        pcall(function() BatchFlipDealUtil.DismissDiplomacyUi(); end);
    end
end

BatchFlip_OnAutoTick = function()
    TryConsumeAutoPending();
end

local function EnsureAutoHandlers()
    if BatchFlipAutoState.bound then
        print("BatchFlip: auto-run handlers already bound");
        return;
    end
    BatchFlipAutoState.bound = true;
    pcall(function()
        Events.LocalPlayerTurnBegin.Add(function()
            if BatchFlip_OnLocalPlayerTurnBegin ~= nil then
                BatchFlip_OnLocalPlayerTurnBegin();
            end
        end);
    end);
    pcall(function()
        Events.LocalPlayerTurnEnd.Add(function()
            if BatchFlip_OnLocalPlayerTurnEnd ~= nil then
                BatchFlip_OnLocalPlayerTurnEnd();
            end
        end);
    end);
    pcall(function()
        Events.GameCoreEventPublishComplete.Add(function()
            if BatchFlip_OnAutoTick ~= nil then
                BatchFlip_OnAutoTick();
            end
        end);
    end);
    print("BatchFlip: auto-run handlers registered once");
end

local DEBUG_ADD_AMOUNT = 40;
local DEBUG_RESOURCES = {
    { btn = "BtnAddHorses", type = "RESOURCE_HORSES" },
    { btn = "BtnAddIron", type = "RESOURCE_IRON" },
    { btn = "BtnAddNiter", type = "RESOURCE_NITER" },
    { btn = "BtnAddCoal", type = "RESOURCE_COAL" },
    { btn = "BtnAddOil", type = "RESOURCE_OIL" },
    { btn = "BtnAddAluminum", type = "RESOURCE_ALUMINUM" },
    { btn = "BtnAddUranium", type = "RESOURCE_URANIUM" },
};

local function OnDebugAddResource(resourceType)
    local row = GameInfo.Resources[resourceType];
    local dbg = ExposedMembers ~= nil and ExposedMembers.BatchFlipDebug or nil;
    if row == nil then return; end
    if dbg == nil or dbg.AddResource == nil then
        SetLog("测试脚本未加载：请完全退出游戏后重开（需要 Gameplay 脚本）。");
        return;
    end
    local name = BatchFlipDealUtil.GetResourceName(row.Index);
    local ok, now, cap, msg = dbg.AddResource(Game.GetLocalPlayer(), row.Index, DEBUG_ADD_AMOUNT);
    if (cap or 0) <= 0 then cap = BatchFlipDealUtil.GetStockpileCap(Game.GetLocalPlayer(), row.Index); end
    if ok then
        SetLog(string.format("%s +%d → 现有 %d / 上限 %d %s", name, DEBUG_ADD_AMOUNT, now or 0, cap or 0, msg or ""));
    else
        SetLog(string.format("%s 添加失败：%s", name, tostring(msg)));
    end
end

-- Per-AI strategic stock: amount/cap and how much it could sell us right now.
local function OnDebugAiStock()
    local localID = Game.GetLocalPlayer();
    local lines = {};
    local mine = {};
    for _, r in ipairs(DEBUG_RESOURCES) do
        local row = GameInfo.Resources[r.type];
        if row ~= nil then
            table.insert(mine, string.format("%s %d/%d", BatchFlipDealUtil.GetResourceName(row.Index),
                BatchFlipDealUtil.GetResourceAmount(localID, row.Index),
                BatchFlipDealUtil.GetStockpileCap(localID, row.Index)));
        end
    end
    table.insert(lines, "我方：" .. table.concat(mine, "  "));
    BatchFlipDealUtil.ForEachMetAi(function(aiID)
        local parts = {};
        for _, r in ipairs(DEBUG_RESOURCES) do
            local row = GameInfo.Resources[r.type];
            if row ~= nil then
                local amt = BatchFlipDealUtil.GetResourceAmount(aiID, row.Index);
                local cap = BatchFlipDealUtil.GetStockpileCap(aiID, row.Index);
                local sell = BatchFlipDealUtil.MaxResourceTradable(aiID, localID, row.Index);
                table.insert(parts, string.format("%s %d/%d(可卖%d)", BatchFlipDealUtil.GetResourceName(row.Index), amt, cap, sell));
            end
        end
        local p = Players[aiID];
        local gold, gpt = 0, 0;
        pcall(function()
            gold = math.floor(p:GetTreasury():GetGoldBalance());
            gpt = math.floor(p:GetTreasury():GetGoldYield() - p:GetTreasury():GetTotalMaintenance());
        end);
        table.insert(lines, string.format("%s 金%d 回合金%+d：%s", BatchFlipDealUtil.GetAiName(aiID), gold, gpt,
            table.concat(parts, "  ")));
    end);
    SetLog(table.concat(lines, "[NEWLINE]"));
end

local function BindDebugButtons()
    for _, r in ipairs(DEBUG_RESOURCES) do
        local btn = Controls[r.btn];
        local row = GameInfo.Resources[r.type];
        if btn ~= nil then
            if row ~= nil then
                btn:SetText(BatchFlipDealUtil.GetResourceName(row.Index) .. "+" .. DEBUG_ADD_AMOUNT);
            end
            btn:RegisterCallback(Mouse.eLClick, function() OnDebugAddResource(r.type); end);
        end
    end
    if Controls.BtnAiStock ~= nil then
        Controls.BtnAiStock:RegisterCallback(Mouse.eLClick, OnDebugAiStock);
    end
end

function OnShowTab(tabType)
    if tabType == BF_TAB_BATCH then
        ContextPtr:SetHide(false);
        ContextPtr:ChangeParent(ContextPtr:LookUpControl(TAB_CONTENT_CONTAINER_PATH));
        BindStaticTexts();
        ApplyConfigToUi();
        if m_LastLog ~= nil then
            ShowResultLog(m_LastLog, m_ShowDetail);
        else
            SetLog(L("LOC_BF_HINT_LIVE"));
            UpdateDetailButton();
        end
        SyncAutoFromConfig();
        UpdateAutoButton();
    else
        ContextPtr:SetHide(true);
    end
end

function OnInit(isReload)
    if Game.GetLocalPlayer() == -1 then return; end
    BatchFlipConfig.Load();
    BatchFlipConfig.Get().DryRun = false;
    -- Always require a fresh manual click after load / enter game.
    if BatchFlipAutoState == nil then
        BatchFlipAutoState = { enabled = false, bound = false, ver = 38 };
    end
    BatchFlipAutoState.enabled = false;
    m_AutoPendingTurn = nil;
    m_AutoDeferTicks = 0;
    m_AutoLastTurn = -1;
    SyncAutoFromConfig();
    EnsureAutoHandlers();
    BindStaticTexts();
    ApplyConfigToUi();
    if HasSafeAutoEngine() then
        SetLog(L("LOC_BF_HINT_LIVE"));
    else
        SetLog("引擎 " .. FlipVersion() .. "（需要 " .. REQUIRED_AUTO_VER
            .. "）。请结束 CivilizationVI_DX12 后重开；自动暂不可用。");
    end
    UpdateDetailButton();
    UpdateAutoButton();

    if Controls.BtnFavor ~= nil then
        Controls.BtnFavor:RegisterCallback(Mouse.eLClick, OnFavor);
        Controls.BtnFavor:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    end
    if Controls.BtnAutoRun ~= nil then
        Controls.BtnAutoRun:RegisterCallback(Mouse.eLClick, OnToggleAuto);
        Controls.BtnAutoRun:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    end
    if Controls.BtnToggleDetail ~= nil then
        Controls.BtnToggleDetail:RegisterCallback(Mouse.eLClick, OnToggleDetail);
        Controls.BtnToggleDetail:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    end
    BindCategoryToggle(Controls.ChkFavor);
    BindCategoryToggle(Controls.ChkStrategicArb);
    BindDebugButtons();
    if isReload and not ContextPtr:IsHidden() then
        OnShowTab(BF_TAB_BATCH);
    end
end

function BF_Initialize()
    ContextPtr:SetInitHandler(OnInit);
    ContextPtr:SetAutoSize(true);
    ContextPtr:SetHide(true);
    LuaEvents.QD_PopupShowTab.Add(OnShowTab);
    print("BatchFlip: QD tab registered (favor + strategic arb, " .. REQUIRED_AUTO_VER .. ")");
end

BF_Initialize();
