include("InstanceManager");
include("ModalScreen_PlayerYieldsHelper");
include("TabSupport");
include("qd_utils");

-- ===========================================================================
-- Quick Deals popup override: keep Sale/Purchase/Exchange + BQD Cycle + BatchFlip
-- LoadOrder must be higher than Better Quick Deal (100000).
-- ===========================================================================
local TAB_SIZE:number = 150;
local TAB_PADDING:number = 8;

local m_TabButtonIM:table = InstanceManager:new("TabButtonInstance", "Button", Controls.TabContainer);
local m_OpenPopupActionId:number = Input.GetActionId("OpenQDPopup");

local m_TopPanelConsideredHeight:number = 0;
local m_Tabs;
local m_NumOfTabs = 0;
local m_SaleTabInstance:table = nil;
local m_PurchaseTabInstance:table = nil;
local m_ExchangeTabInstance:table = nil;
local m_CycleTabInstance:table = nil;
local m_BatchTabInstance:table = nil;

local BQD_TAB_CYCLE = "TAB_BQD_CYCLE";
local BF_TAB_BATCH = "TAB_BF_BATCH";

local function HasBetterQuickDeal()
    if Modding == nil or Modding.GetActiveMods == nil then
        return false;
    end
    for _, mod in ipairs(Modding.GetActiveMods()) do
        if tostring(mod.Id or "") == "f11a6a0d-2f36-4cf0-9f61-9d8a9d2d2a11" then
            return true;
        end
    end
    return false;
end

function Open()
    local localPlayer = Game.GetLocalPlayer();
    if localPlayer == -1 or not Players[localPlayer]:IsTurnActive() then return; end

    CloseOtherPanels();
    if not UIManager:IsInPopupQueue(ContextPtr) then
        local kParameters = {};
        kParameters.RenderAtCurrentParent = true;
        kParameters.InputAtCurrentParent = true;
        kParameters.AlwaysVisibleInQueue = true;
        UIManager:QueuePopup(ContextPtr, PopupPriority.Low, kParameters);
        ContextPtr:ChangeParent(ContextPtr:LookUpControl("/InGame/Screens"));
        UI.PlaySound("UI_Screen_Open");
        LuaEvents.QDDealPopup_Opened();
    end
    m_Tabs.SelectTab(m_SaleTabInstance.Button);
    if not RefreshYields() then
        Controls.Vignette:SetSizeY(m_TopPanelConsideredHeight);
    end
    Controls.ScreenAnimIn:SetToBeginning();
    Controls.ScreenAnimIn:Play();
end

function Close()
    if UIManager:DequeuePopup(ContextPtr) then
        LuaEvents.QDDealPopup_CloseRequest();
        UI.PlaySound("UI_Screen_Close");
    end
end

function CloseSilently()
    UIManager:DequeuePopup(ContextPtr);
end

function OnSaleTabClick(uiSelectedButton:table)
    ResetTabButtons();
    SetTabButtonsSelected(uiSelectedButton);
    LuaEvents.QD_PopupShowTab(TAB_TYPE.SALE);
end

function OnPurchaseTabClick(uiSelectedButton:table)
    ResetTabButtons();
    SetTabButtonsSelected(uiSelectedButton);
    LuaEvents.QD_PopupShowTab(TAB_TYPE.PURCHASE);
end

function OnExchangeTabClick(uiSelectedButton:table)
    ResetTabButtons();
    SetTabButtonsSelected(uiSelectedButton);
    LuaEvents.QD_PopupShowTab(TAB_TYPE.EXCHANGE);
end

function OnCycleTabClick(uiSelectedButton:table)
    ResetTabButtons();
    SetTabButtonsSelected(uiSelectedButton);
    LuaEvents.QD_PopupShowTab(BQD_TAB_CYCLE);
end

function OnBatchTabClick(uiSelectedButton:table)
    ResetTabButtons();
    SetTabButtonsSelected(uiSelectedButton);
    LuaEvents.QD_PopupShowTab(BF_TAB_BATCH);
end

function CloseOtherPanels()
    LuaEvents.LaunchBar_CloseTechTree();
    LuaEvents.LaunchBar_CloseCivicsTree();
    LuaEvents.LaunchBar_CloseGovernmentPanel();
    LuaEvents.LaunchBar_CloseReligionPanel();
    LuaEvents.LaunchBar_CloseGreatPeoplePopup();
    LuaEvents.LaunchBar_CloseGreatWorksOverview();
    if g_IsXP1Active then
        LuaEvents.GovernorPanel_Close();
        LuaEvents.HistoricMoments_Close();
    end
    if g_IsXP2Active then
        LuaEvents.Launchbar_Expansion2_ClimateScreen_Close();
    end
end

function SetupTabs()
    m_NumOfTabs = 0;
    m_Tabs = CreateTabs(Controls.TabContainer, 42, 34, UI.GetColorValueFromHexLiteral(0xFF331D05));

    m_SaleTabInstance = AddTabInstance("LOC_QD_SALE", OnSaleTabClick);
    m_PurchaseTabInstance = AddTabInstance("LOC_HUD_PURCHASE", OnPurchaseTabClick);
    m_ExchangeTabInstance = AddTabInstance("LOC_QD_EXCHANGE", OnExchangeTabClick);
    if HasBetterQuickDeal() then
        m_CycleTabInstance = AddTabInstance("LOC_BQD_CYCLE_TAB", OnCycleTabClick);
    end
    m_BatchTabInstance = AddTabInstance("LOC_BF_BATCH_TAB", OnBatchTabClick);

    local desiredSize = (TAB_SIZE * m_NumOfTabs) + (TAB_PADDING * (m_NumOfTabs - 1));
    Controls.TabContainer:SetSizeX(desiredSize);
    m_Tabs.CenterAlignTabs(-10);
    m_Tabs.SelectTab(m_SaleTabInstance.Button);
end

function AddTabInstance(buttonText:string, callbackFunc:ifunction)
    local kInstance:object = m_TabButtonIM:GetInstance();
    local label = Locale.Lookup(buttonText);
    if label == nil or label == buttonText or string.find(label, "^LOC_") then
        if buttonText == "LOC_BF_BATCH_TAB" then
            label = "批量倒卖";
        end
    end
    kInstance.Button:SetText(label);
    kInstance.Button:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    m_Tabs.AddTab(kInstance.Button, callbackFunc);
    m_NumOfTabs = m_NumOfTabs + 1;
    return kInstance;
end


function SetTabButtonsSelected(buttonControl:table)
    for i=1, m_TabButtonIM.m_iCount, 1 do
        local buttonInstance:table = m_TabButtonIM:GetAllocatedInstance(i);
        if buttonInstance and buttonInstance.Button == buttonControl then
            buttonInstance.Button:SetSelected(true);
            buttonInstance.SelectButton:SetHide(false);
        end
    end
end

function ResetTabButtons()
    for i=1, m_TabButtonIM.m_iCount, 1 do
        local buttonInstance:table = m_TabButtonIM:GetAllocatedInstance(i);
        if buttonInstance then
            buttonInstance.Button:SetSelected(false);
            buttonInstance.SelectButton:SetHide(true);
        end
    end
end

function OnInit(isReload)
    SetupTabs();
    if isReload and not ContextPtr:IsHidden() then
        Open();
    end
end

function OnInputHandler(pInputStruct:table)
    if ContextPtr:IsHidden() then return false; end
    if pInputStruct:GetMessageType() == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
        Close();
    end
    return true;
end

function OnInputActionTriggered(actionId:number)
    if actionId == m_OpenPopupActionId and ContextPtr:IsHidden() then
        Open();
    end
end

function OnShutdown()
    m_TabButtonIM:ResetInstances();
    LuaEvents.QD_RequestDealScreen.Remove(OnRequestDealScreen);
    LuaEvents.QD_ToggleDealPopup.Remove(ToggleDealPopup);
    LuaEvents.QD_OpenBatchTab.Remove(OpenBatchTab);
    LuaEvents.QD_CloseDealPopupSilently.Remove(CloseSilently);
    LuaEvents.QD_CloseBatchPopup.Remove(CloseBatchPopup);
end

function OnProcessNotification(playerId:number, notificationId:number, activatedByUser:boolean)
    if playerId == Game.GetLocalPlayer() then
        local notification = NotificationManager.Find(playerId, notificationId);
        if notification and notification:GetType() == QD_NOTIFICATION_HASH and ContextPtr:IsHidden() then
            Open();
        end
    end
end

function ToggleDealPopup()
    if ContextPtr:IsHidden() then
        Open();
    else
        Close();
    end
end

-- Open QD and jump to BatchFlip tab (used by auto-run so context matches manual).
function OpenBatchTab()
    if ContextPtr:IsHidden() then
        Open();
    end
    if m_BatchTabInstance ~= nil and m_Tabs ~= nil then
        ResetTabButtons();
        SetTabButtonsSelected(m_BatchTabInstance.Button);
        m_Tabs.SelectTab(m_BatchTabInstance.Button);
        LuaEvents.QD_PopupShowTab(BF_TAB_BATCH);
    end
end

-- Auto-run finished: close the popup it opened.
function CloseBatchPopup()
    if not ContextPtr:IsHidden() then
        Close();
    end
end

function OnRequestDealScreen(otherPlayerId)
    Close();
    DiplomacyManager.RequestSession(Game.GetLocalPlayer(), otherPlayerId, "MAKE_DEAL");
end

function QD_Initialize()
    ContextPtr:SetInitHandler(OnInit);
    ContextPtr:SetInputHandler(OnInputHandler, true);
    ContextPtr:SetShutdown(OnShutdown);

    Events.InputActionTriggered.Add(OnInputActionTriggered);
    Events.NotificationActivated.Add(OnProcessNotification);

    LuaEvents.QD_RequestDealScreen.Add(OnRequestDealScreen);
    LuaEvents.QD_ToggleDealPopup.Add(ToggleDealPopup);
    LuaEvents.QD_OpenBatchTab.Add(OpenBatchTab);
    LuaEvents.QD_CloseDealPopupSilently.Add(CloseSilently);
    LuaEvents.QD_CloseBatchPopup.Add(CloseBatchPopup);

    Controls.ModalScreenClose:RegisterCallback(Mouse.eLClick, Close);
    Controls.ModalScreenTitle:SetText(Locale.ToUpper(Locale.Lookup("LOC_QD_NAME")));

    if GameConfiguration.IsAnyMultiplayer() then
        Controls.NotificationToggle:LocalizeAndSetToolTip("LOC_QD_NOT_SUPPORTED_IN_MULTIPLAYER");
        Controls.NotificationToggle:SetDisabled(true);
        Controls.NotificationToggle:SetCheck(false);
    else
        Controls.NotificationToggle:LocalizeAndSetToolTip("LOC_OPTIONS_NOTIFICATIONS");
        Controls.NotificationToggle:RegisterCallback(Mouse.eLClick, ToggleNotificationOptedOut);
        Controls.NotificationToggle:SetDisabled(false);
        Controls.NotificationToggle:SetCheck(not IsNotificationOptedOut());
    end

    m_TopPanelConsideredHeight = Controls.Vignette:GetSizeY() - TOP_PANEL_OFFSET;
end

QD_Initialize();
