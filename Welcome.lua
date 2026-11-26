local _, ns = ...
local L = ns.L

-- The welcome window: four short steps, shown once on the first login, and
-- again with /dropoff welcome. It looks like the turn-in window (UI.lua).
-- Closing it in any way, or finishing it, sets DropOffDB.welcomed.
local Welcome = {}
ns.Welcome = Welcome

local WIDTH, HEIGHT, PAD = 360, 300, 14
local INNER = WIDTH - 2 * PAD
local STEPS = 4
local DELAY = 3                  -- seconds after login: let the other addons settle
local ROW_HEIGHT, BODY_TOP = 32, 84
local BUTTON_W, BUTTON_H = 96, 22
local READY = "Interface\\RaidFrame\\ReadyCheck-Ready"
local NOT_READY = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local GREEN = { 0.35, 0.9, 0.45 }
local RED = { 0.95, 0.4, 0.35 }
local GREY = { 0.6, 0.6, 0.6 }

-- The map addons, with the name each is told by.
local MAPS = {
    { addon = "DropOff_Paths_EasternKingdoms", name = "WELCOME_MAP_EK" },
    { addon = "DropOff_Paths_Kalimdor", name = "WELCOME_MAP_KAL" },
    { addon = "DropOff_Paths_Zephras", name = "WELCOME_MAP_ZEP" },
}

local frame
local step = 1
local scheduled, waitingForCombat = false, false
local rows = {}          -- step 2: one per thing looked for
local shownRows = {}     -- what step 2 last found, for the tests

---------------------------------------------------------------------------
-- What is installed
---------------------------------------------------------------------------

local function Try(fn, ...)
    local ok, a, b, c, d, e = pcall(fn, ...)
    if ok then return a, b, c, d, e end
    return nil
end

local function HasQuestie()
    local db = ns.Data and ns.Data.DB and Try(ns.Data.DB)
    return db ~= nil
end

local function HasTomTom()
    return type(rawget(_G, "TomTom")) == "table"
end

-- A load-on-demand addon is "enabled" when the game would load it when asked:
-- it is installed and not switched off. Not "loaded": these load on demand.
local OFF = { MISSING = true, DISABLED = true, DEP_DISABLED = true, DEP_MISSING = true, CORRUPT = true, INCOMPATIBLE = true }

local function AddonEnabled(name)
    local api = type(C_AddOns) == "table" and C_AddOns or nil
    local info = api and api.GetAddOnInfo or rawget(_G, "GetAddOnInfo")
    local first, _, _, loadable, reason = nil, nil, nil, nil, nil
    if type(info) == "function" then
        local a, _, _, c, d = Try(info, name)
        if type(a) == "table" then
            first, loadable, reason = a.name, a.loadable, a.reason
        else
            first, loadable, reason = a, c, d
        end
        if first == nil or reason == "MISSING" then return false end
    end
    local state = api and api.GetAddOnEnableState
    if type(state) == "function" then
        local value = Try(state, name)
        if type(value) == "number" then return value > 0 end
    end
    if type(info) ~= "function" then return false end
    if OFF[reason] then return false end
    return loadable == true or reason == nil or reason == "DEMAND_LOADED"
end

-- What step 2 lists, read from the game each time it is shown.
local function Needs()
    local list = {}
    local questie = HasQuestie()
    list[#list + 1] = {
        key = "questie", found = questie, optional = false,
        name = L.WELCOME_QUESTIE, text = questie and L.WELCOME_QUESTIE_OK or L.WELCOME_QUESTIE_NO,
    }
    local tomtom = HasTomTom()
    list[#list + 1] = {
        key = "tomtom", found = tomtom, optional = true,
        name = L.WELCOME_TOMTOM, text = tomtom and L.WELCOME_TOMTOM_OK or L.WELCOME_TOMTOM_NO,
    }
    for _, map in ipairs(MAPS) do
        local on = AddonEnabled(map.addon)
        list[#list + 1] = {
            key = map.addon, found = on, optional = false,
            name = L.WELCOME_MAP:format(L[map.name]), text = on and L.WELCOME_MAP_OK or L.WELCOME_MAP_NO,
        }
    end
    return list
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function Button(label)
    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(BUTTON_W, BUTTON_H)
    button:SetText(label)
    return button
end

local function NewRow(index)
    local row = {}
    local y = -(BODY_TOP + (index - 1) * ROW_HEIGHT)
    row.mark = frame:CreateTexture(nil, "ARTWORK")
    row.mark:SetSize(16, 16)
    row.mark:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
    row.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 24, y)
    row.name:SetJustifyH("LEFT")
    row.text = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.text:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
    row.text:SetJustifyH("LEFT")
    return row
end

local function NewCheck(label, y, onClick)
    local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD - 4, y)
    check.label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.label:SetWidth(INNER - 32)
    check.label:SetJustifyH("LEFT")
    check.label:SetText(label)
    check:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    return check
end

local function Build()
    frame = CreateFrame("Frame", "DropOffWelcome", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0.04, 0.04, 0.05, 0.92)
        frame:SetBackdropBorderColor(0.4, 0.4, 0.42, 1)
    end
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    frame.title:SetText(L.WELCOME_TITLE)

    frame.counter = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.counter:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -4)

    frame.head = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.head:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -62)
    frame.head:SetJustifyH("LEFT")

    frame.body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.body:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BODY_TOP)
    frame.body:SetWidth(INNER)
    frame.body:SetJustifyH("LEFT")
    frame.body:SetJustifyV("TOP")

    for index = 1, #MAPS + 2 do rows[index] = NewRow(index) end

    frame.minimap = NewCheck(L.WELCOME_OPT_MINIMAP, -(BODY_TOP + 44), function(checked)
        if type(DropOffDB) ~= "table" then return end
        DropOffDB.minimap = type(DropOffDB.minimap) == "table" and DropOffDB.minimap or {}
        DropOffDB.minimap.hide = (not checked) and true or nil
        if ns.MinimapButton then ns.MinimapButton.Refresh() end
    end)
    frame.alert = NewCheck(L.WELCOME_OPT_ALERT, -(BODY_TOP + 76), function(checked)
        if type(DropOffDB) == "table" then DropOffDB.alert = checked end
    end)

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.close:SetScript("OnClick", function() frame:Hide() end)

    frame.back = Button(L.WELCOME_BACK)
    frame.back:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
    frame.back:SetScript("OnClick", function() Welcome.Back() end)

    frame.skip = Button(L.WELCOME_SKIP)
    frame.skip:SetPoint("BOTTOM", frame, "BOTTOM", 0, PAD)
    frame.skip:SetScript("OnClick", function() Welcome.Skip() end)

    frame.next = Button(L.WELCOME_NEXT)
    frame.next:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
    frame.next:SetScript("OnClick", function() Welcome.Next() end)

    -- Hide before wiring the scripts: frames are born shown.
    frame:Hide()
    frame:SetScript("OnHide", function(self)
        -- Also fires when the whole UI hides (Alt+Z): the window is still shown then.
        if self:IsShown() then return end
        if type(DropOffDB) == "table" then DropOffDB.welcomed = true end
    end)
    -- Esc closes it.
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "DropOffWelcome") end
end

---------------------------------------------------------------------------
-- Showing a step
---------------------------------------------------------------------------

local function Paint()
    local last = step == STEPS
    frame.counter:SetText(L.WELCOME_STEP:format(step, STEPS))
    frame.head:SetText(L["WELCOME_" .. step .. "_HEAD"])

    -- Step 2: one row each, read from the game now.
    shownRows = step == 2 and Needs() or {}
    for index, row in ipairs(rows) do
        local need = shownRows[index]
        if need then
            row.name:SetText(need.name)
            row.text:SetText(need.text)
            row.mark:SetTexture(need.found and READY or NOT_READY)
            -- An optional thing that is missing is grey, not red.
            local colour = need.found and GREEN or (need.optional and GREY or RED)
            row.mark:SetVertexColor(colour[1], colour[2], colour[3])
            row.text:SetTextColor(colour[1], colour[2], colour[3])
            row.mark:Show(); row.name:Show(); row.text:Show()
        else
            row.mark:Hide(); row.name:Hide(); row.text:Hide()
        end
    end

    -- Steps 1, 3 and 4 are text. Step 3 has its two boxes under a line.
    if step == 2 then
        frame.body:SetText("")
    else
        frame.body:SetText(L["WELCOME_" .. step .. "_BODY"])
    end

    local settings = step == 3
    frame.minimap:SetShown(settings)
    frame.minimap.label:SetShown(settings)
    frame.alert:SetShown(settings)
    frame.alert.label:SetShown(settings)
    if settings then
        local db = type(DropOffDB) == "table" and DropOffDB or {}
        frame.minimap:SetChecked(not (type(db.minimap) == "table" and db.minimap.hide))
        frame.alert:SetChecked(db.alert and true or false)
    end

    frame.back:SetShown(step > 1)
    frame.skip:SetText(last and L.WELCOME_CLOSE or L.WELCOME_SKIP)
    frame.next:SetText(last and L.WELCOME_OPEN or L.WELCOME_NEXT)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function Welcome.Show(at)
    if not frame then Build() end
    step = math.max(1, math.min(STEPS, tonumber(at) or 1))
    Paint()
    frame:Show()
end

function Welcome.Hide()
    if frame then frame:Hide() end
end

function Welcome.IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

function Welcome.Next()
    if not frame then return end
    if step >= STEPS then
        -- The last step's button: the main window, and this one done.
        frame:Hide()
        ns.UI.Show()
        return
    end
    step = step + 1
    Paint()
end

function Welcome.Back()
    if not frame or step <= 1 then return end
    step = step - 1
    Paint()
end

-- Skip on steps 1 to 3, Close on the last: the window goes, the flag is set.
function Welcome.Skip()
    if frame then frame:Hide() end
end

-- For the tests and /dropoff debug: where the window is and what step 2 found.
function Welcome.State()
    return {
        shown = Welcome.IsShown(),
        step = step,
        rows = shownRows,
        waiting = waitingForCombat,
    }
end

---------------------------------------------------------------------------
-- First run
---------------------------------------------------------------------------

local function TryShow()
    if type(DropOffDB) ~= "table" or DropOffDB.welcomed or Welcome.IsShown() then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        waitingForCombat = true
        return
    end
    waitingForCombat = false
    Welcome.Show(1)
end

-- PLAYER_ENTERING_WORLD (every loading screen): only the first one counts.
function Welcome.OnWorld()
    if scheduled or type(DropOffDB) ~= "table" or DropOffDB.welcomed then return end
    scheduled = true
    C_Timer.After(DELAY, TryShow)
end

-- PLAYER_REGEN_ENABLED: the fight is over.
function Welcome.OnCombatEnd()
    if waitingForCombat then TryShow() end
end
