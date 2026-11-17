local ADDON, ns = ...
local L = ns.L

ns.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "dev"
ns.state = {
    plan = nil,      -- last built plan
    pinned = nil,    -- questID the player clicked to visit first
    lastAlert = -1e9,
    lastAnnounce = -1e9,
    announcedQuest = nil,
    hadTarget = false,
}

local DEFAULTS = {
    alert = true,     -- chat hint when bags are nearly full and turn-ins would free slots
    alertFree = 4,    -- "nearly full" = this many free slots or fewer
}

local LOG_MAX = 200
local ALERT_EVERY = 300     -- seconds between bag hints
local ANNOUNCE_EVERY = 5    -- seconds between "next turn-in" lines
local TICK = 1.5            -- distance refresh while the window is open

---------------------------------------------------------------------------
-- Small helpers shared by every module
---------------------------------------------------------------------------

-- Forever runs on the Midnight engine: some API returns are "secret" and
-- cannot be compared or used in arithmetic by addons.
function ns.Secret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) or false
end

local function Results(ok, ...)
    if ok then return ... end
    return nil
end

-- Calls fn and returns its results, or nil when fn is missing or throws.
function ns.Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Results(pcall(fn, ...))
end

function ns.Print(text)
    local line = L.MSG_PREFIX .. tostring(text)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    else
        print(line)
    end
end

function ns.Log(fmt, ...)
    local db = DropOffDB
    if type(db) ~= "table" then return end
    db.log = db.log or {}
    local ok, text = pcall(string.format, fmt, ...)
    local stamp = type(date) == "function" and date("%H:%M:%S") or ""
    db.log[#db.log + 1] = stamp .. " " .. (ok and text or tostring(fmt))
    while #db.log > LOG_MAX do table.remove(db.log, 1) end
end

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function InitDB()
    if type(DropOffDB) ~= "table" then DropOffDB = {} end
    if type(DropOffCharDB) ~= "table" then DropOffCharDB = {} end
    for key, value in pairs(DEFAULTS) do
        if DropOffDB[key] == nil then DropOffDB[key] = value end
    end
    DropOffDB.log = type(DropOffDB.log) == "table" and DropOffDB.log or {}
end

---------------------------------------------------------------------------
-- Refresh loop
---------------------------------------------------------------------------

local reportedError = false
local pending = false
local ticker

function ns.IsOpen()
    return ns.UI.IsShown()
end

-- First finished quest we can point at: the pinned one, else the top of the list.
local function PickTarget(plan)
    local pinned, first = ns.state.pinned, nil
    for _, quest in ipairs(plan.ready) do
        if quest.target then
            if pinned and quest.id == pinned then return quest end
            first = first or quest
        end
    end
    ns.state.pinned = nil
    return first
end

local function DistanceText(target)
    if target.dist then return L.DIST_YARDS:format(math.floor(target.dist + 0.5)) end
    return target.zone or L.DIST_FAR
end

local function UpdateGuidance(plan)
    local quest = PickTarget(plan)
    plan.current = quest and quest.id or nil
    if quest then
        local label = quest.target.name and (quest.title .. " (" .. quest.target.name .. ")") or quest.title
        ns.Nav.Set(quest.target, label)
        local now = Now()
        if ns.state.announcedQuest ~= quest.id and now - ns.state.lastAnnounce >= ANNOUNCE_EVERY then
            ns.state.announcedQuest = quest.id
            ns.state.lastAnnounce = now
            ns.Print(L.MSG_NEXT:format(label, DistanceText(quest.target)))
        end
    else
        ns.Nav.Clear()
        if ns.state.hadTarget and #plan.ready == 0 then ns.Print(L.MSG_DONE) end
        ns.state.announcedQuest = nil
    end
    ns.state.hadTarget = quest ~= nil
end

local function MaybeAlert(plan)
    if not DropOffDB.alert or plan.readySlots <= 0 or plan.free > DropOffDB.alertFree then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    local now = Now()
    if now - ns.state.lastAlert < ALERT_EVERY then return end
    ns.state.lastAlert = now
    ns.Print(L.MSG_BAGS:format(plan.free, plan.readyWithItems, plan.readySlots))
end

function ns.Refresh()
    local ok, plan = pcall(ns.Plan.Build)
    if not ok then
        ns.Log("plan error: %s", tostring(plan))
        if not reportedError then
            reportedError = true
            ns.Print("error: " .. tostring(plan))
        end
        return nil
    end
    ns.state.plan = plan
    if ns.IsOpen() then
        local ok2, err = pcall(function()
            UpdateGuidance(plan)
            ns.UI.Render(plan)
        end)
        if not ok2 then
            ns.Log("render error: %s", tostring(err))
            if not reportedError then
                reportedError = true
                ns.Print("error: " .. tostring(err))
            end
        end
    else
        MaybeAlert(plan)
    end
    return plan
end

function ns.RequestRefresh(delay)
    if pending then return end
    pending = true
    C_Timer.After(delay or 0.3, function()
        pending = false
        ns.Refresh()
    end)
end

---------------------------------------------------------------------------
-- Turn-in mode: window open = guiding
---------------------------------------------------------------------------

-- Called by the window's OnShow / OnHide, so the X button and /dropoff agree.
function ns.OnShown()
    DropOffCharDB.open = true
    if not ticker and C_Timer.NewTicker then ticker = C_Timer.NewTicker(TICK, ns.Refresh) end
    ns.Refresh()
end

function ns.OnHidden()
    DropOffCharDB.open = false
    if ticker then ticker:Cancel(); ticker = nil end
    ns.Nav.Clear()
    ns.state.pinned = nil
    ns.state.announcedQuest = nil
    ns.state.hadTarget = false
end

function ns.Toggle()
    if ns.IsOpen() then ns.UI.Hide() else ns.UI.Show() end
end

function ns.Pin(questID)
    ns.state.pinned = ns.state.pinned ~= questID and questID or nil
    ns.Refresh()
end

-- The map button on a row: head there first and open the world map on it.
function ns.ShowOnMap(questID)
    ns.state.pinned = questID
    local plan = ns.Refresh()
    for _, quest in ipairs(plan and plan.ready or {}) do
        if quest.id == questID and quest.target then
            if not ns.Nav.OpenMap(quest.target.mapId) then ns.Print(L.MSG_NO_MAP) end
            return
        end
    end
end

---------------------------------------------------------------------------
-- Chat commands
---------------------------------------------------------------------------

local function PrintList()
    local plan = ns.Refresh()
    if plan and plan.hidden > 0 then ns.Print(L.HIDDEN_QUESTS:format(plan.hidden)) end
    if not plan or #plan.ready == 0 then
        ns.Print(L.MSG_LIST_EMPTY)
        return
    end
    for index, quest in ipairs(plan.ready) do
        local where = quest.target and DistanceText(quest.target) or L.UNKNOWN_PLACE
        local who = quest.target and quest.target.name or "?"
        ns.Print(("%d. %s · %s · %s · %s"):format(index, quest.title, who, where, L.SLOTS:format(quest.slots)))
    end
end

local function Snapshot()
    local ok, dump = pcall(ns.Data.DebugDump)
    DropOffDB.snapshot = ok and dump or { error = tostring(dump) }
    ns.Log("snapshot taken")
    ns.Print(L.MSG_SNAPSHOT)
end

local function Slash(message)
    local command = (message or ""):lower():match("^%s*(%S*)")
    if command == "" then
        ns.Toggle()
    elseif command == "list" then
        PrintList()
    elseif command == "alert" then
        DropOffDB.alert = not DropOffDB.alert
        ns.Print(DropOffDB.alert and L.MSG_ALERT_ON or L.MSG_ALERT_OFF)
    elseif command == "debug" then
        Snapshot()
    else
        ns.Print(L.MSG_HELP)
    end
end

SLASH_DROPOFF1 = "/dropoff"
SLASH_DROPOFF2 = "/dof"
SlashCmdList = SlashCmdList or {}
SlashCmdList.DROPOFF = Slash

-- Addon compartment (minimap dropdown) entry, declared in the TOC.
function DropOff_OnAddonCompartmentClick()
    ns.Toggle()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
ns.eventFrame = frame

local EVENTS = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_DELAYED",
    "QUEST_LOG_UPDATE",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "QUEST_TURNED_IN",
    "ZONE_CHANGED_NEW_AREA",
}
for _, event in ipairs(EVENTS) do
    -- RegisterEvent throws for events a client does not know.
    pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then InitDB() end
        return
    end
    if type(DropOffDB) ~= "table" then InitDB() end

    if event == "PLAYER_ENTERING_WORLD" then
        if DropOffCharDB.open and not ns.IsOpen() then
            -- Give Questie and TomTom a moment to finish their own start-up.
            C_Timer.After(3, function()
                if DropOffCharDB.open and not ns.IsOpen() then ns.UI.Show() end
            end)
        end
        return
    end

    if ns.IsOpen() then
        ns.RequestRefresh(0.3)
    elseif event == "BAG_UPDATE_DELAYED" and DropOffDB.alert then
        ns.RequestRefresh(2)
    end
end)
