-- Offline tests for DropOff: loads the real addon files against a mocked WoW
-- API (bags, quest log, QuestieDB, Questie zones, HereBeDragons, TomTom).
-- Run: luajit tests/run.lua   (from the repo root)

local ROOT = ""
local passed, failed = 0, 0

---------------------------------------------------------------------------
-- Tiny test kit
---------------------------------------------------------------------------

local current = "?"

local function check(condition, message)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL [%s] %s"):format(current, message or "assertion"))
    end
end

local function eq(actual, expected, message)
    check(actual == expected,
        ("%s: expected %s, got %s"):format(message or "value", tostring(expected), tostring(actual)))
end

local function test(name, fn)
    current = name
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        failed = failed + 1
        print(("FAIL [%s] threw: %s"):format(name, err))
    end
end

---------------------------------------------------------------------------
-- Mock clock and timers
---------------------------------------------------------------------------

local now, timers

local function Advance(dt)
    local target = now + dt
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local timer = timers[1]
        if not timer or timer.at > target then break end
        now = timer.at
        if timer.cancelled then
            table.remove(timers, 1)
        elseif timer.every then
            timer.at = timer.at + timer.every
            timer.fn()
        else
            table.remove(timers, 1)
            timer.fn()
        end
    end
    now = target
end

---------------------------------------------------------------------------
-- Mock frames
---------------------------------------------------------------------------

local function Widget()
    local widget = { scripts = {}, shown = true }
    function widget:SetScript(name, fn) self.scripts[name] = fn end
    function widget:GetScript(name) return self.scripts[name] end
    function widget:RegisterEvent(name) self.events = self.events or {}; self.events[name] = true end
    function widget:Show()
        if not self.shown then
            self.shown = true
            if self.scripts.OnShow then self.scripts.OnShow(self) end
        end
    end
    function widget:Hide()
        if self.shown then
            self.shown = false
            if self.scripts.OnHide then self.scripts.OnHide(self) end
        end
    end
    function widget:IsShown() return self.shown end
    -- The whole UI hiding (Alt+Z): OnHide fires but the frame stays "shown".
    function widget:ParentHidden() if self.scripts.OnHide then self.scripts.OnHide(self) end end
    function widget:ParentShown() if self.scripts.OnShow then self.scripts.OnShow(self) end end
    function widget:SetShown(value) if value then self:Show() else self:Hide() end end
    function widget:SetText(text) self.text = text end
    function widget:GetText() return self.text end
    function widget:SetHeight(height) self.height = height end
    function widget:SetTexture(texture) self.texture = texture end
    function widget:GetPoint() return "RIGHT", nil, "RIGHT", -140, 60 end
    function widget:CreateTexture() return Widget() end
    function widget:CreateFontString() return Widget() end
    function widget:Click() if self.scripts.OnClick then self.scripts.OnClick(self) end end
    -- Anything else (SetPoint, SetSize, SetBackdrop...) is accepted and ignored.
    return setmetatable(widget, { __index = function() return function() end end })
end

---------------------------------------------------------------------------
-- Mock world
---------------------------------------------------------------------------

-- UI maps: world origin of the map, yards per unit, and continent.
-- ox is the game's y (west) at the left edge, oy the game's x (north) at the
-- top edge: a point is at game x = oy + y * size, game y = ox + x * size.
local MAPS = {
    [1411] = { name = "Durotar", ox = 0, oy = 0, size = 1000, instance = 1 },
    [1413] = { name = "The Barrens", ox = 2000, oy = 0, size = 1000, instance = 1 },
    [1429] = { name = "Elwynn Forest", ox = 0, oy = 0, size = 1000, instance = 0 },
    -- For the travel tests: the two continents and two zones, laid out over
    -- the real world coordinates of the travel data.
    [1415] = { name = "Eastern Kingdoms", ox = 20000, oy = 10000, size = -40000, instance = 0, continent = true },
    [1414] = { name = "Kalimdor", ox = 20000, oy = 15000, size = -40000, instance = 1, continent = true },
    [1417] = { name = "Arathi Highlands", ox = -800, oy = 0, size = -3600, instance = 0, real = true },
    [1440] = { name = "Ashenvale", ox = 1800, oy = 4700, size = -5800, instance = 1, real = true },
}
local AREA_TO_MAP = { [14] = 1411, [17] = 1413, [12] = 1429, [45] = 1417, [331] = 1440 }

-- Map coordinates (0..1) of a point given in the game's world yards.
local function OnMap(mapId, gx, gy)
    local map = MAPS[mapId]
    return (gy - map.ox) / map.size, (gx - map.oy) / map.size
end

local world

local function NewWorld()
    world = {
        locale = "enUS",
        faction = "Horde",
        bags = { [0] = { size = 16, slots = {} } },   -- slots[n] = { id, count }
        quests = {},        -- { id, title, complete, failed, objectives = { { text, type, finished } } }
        completed = {},     -- questID -> true
        items = {},         -- itemID -> { name, class, icon }
        db = { quests = {}, npcs = {}, objects = {}, items = {} },
        dungeons = {},      -- areaId -> { { areaId, x, y } }
        player = { map = 1411, x = 0.40, y = 0.50 },
        tomtom = true,
        questie = true,
        questieDB = true,
        hbd = true,
        secretPosition = false,
        nextWaypoint = {},  -- questID -> { map, x, y }
        chat = {},
        waypoints = {},     -- live TomTom waypoints
        waypointAdds = 0,
        userWaypoint = nil,
        superTracked = false,
        clearedUserWaypoint = 0,
        travel = false,     -- true: plan with the real travel data
        onTaxi = false,
        taxiNodes = nil,    -- what the open flight map lists: { { nodeID, state } }
        mapPins = {},       -- icon -> where the trail put it on the world map
        minimapPins = {},
    }
    return world
end

local function PlayerWorld()
    local map = MAPS[world.player.map]
    return map.ox + world.player.x * map.size, map.oy + world.player.y * map.size, map.instance
end

local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

local function InstallGlobals()
    now, timers = 1000, {}

    GetLocale = function() return world.locale end
    GetTime = function() return now end
    date = function() return "00:00:00" end
    GetBuildInfo = function() return "1.60.1", "70938", "Nov 1 2026", 16001 end
    UnitFactionGroup = function() return world.faction end
    InCombatLockdown = function() return false end
    UnitOnTaxi = function() return world.onTaxi end
    Enum = { FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 } }
    GetTaxiMapID = function() return 1415 end
    C_TaxiMap = {
        GetAllTaxiNodes = function() return world.taxiNodes or {} end,
        GetTaxiNodesForMap = function() return world.localNames or {} end,
    }
    issecretvalue = function(value) return value == SECRET end
    NUM_BAG_SLOTS = 4
    UIParent = Widget()
    GameTooltip = Widget()
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) world.chat[#world.chat + 1] = text end }
    SlashCmdList = {}
    DropOffDB, DropOffCharDB = nil, nil
    DropOffFrame = nil
    OpenMapAPI = nil

    C_Timer = {
        After = function(delay, fn) timers[#timers + 1] = { at = now + delay, fn = fn } end,
        NewTicker = function(every, fn)
            local timer = { at = now + every, every = every, fn = fn }
            function timer:Cancel() self.cancelled = true end
            timers[#timers + 1] = timer
            return timer
        end,
    }

    CreateFrame = function(_, name)
        local frame = Widget()
        if name then _G[name] = frame end
        return frame
    end

    CreateVector2D = function(x, y) return { x = x, y = y } end
    UiMapPoint = { CreateFromCoordinates = function(mapId, x, y)
        return { uiMapID = mapId, position = { x = x, y = y } }
    end }

    C_Container = {
        GetContainerNumSlots = function(bag) return world.bags[bag] and world.bags[bag].size or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local entry = world.bags[bag] and world.bags[bag].slots[slot]
            if not entry then return nil end
            local item = world.items[entry.id] or {}
            return { itemID = entry.id, stackCount = entry.count or 1, iconFileID = item.icon or entry.id }
        end,
        GetContainerNumFreeSlots = function(bag)
            local data = world.bags[bag]
            if not data then return 0, 0 end
            local used = 0
            for _ in pairs(data.slots) do used = used + 1 end
            return data.size - used, data.family or 0
        end,
    }

    C_Item = {
        GetItemNameByID = function(id) return world.items[id] and world.items[id].name end,
        GetItemInfoInstant = function(id)
            local item = world.items[id]
            if not item then return nil end
            return id, "type", "subtype", "", item.icon or id, item.class or 0, 0
        end,
    }

    if world.legacyQuestLog then
        C_QuestLog = nil
        GetNumQuestLogEntries = function() return #world.quests end
        GetQuestLogTitle = function(index)
            local quest = world.quests[index]
            if not quest then return nil end
            local state = quest.failed and -1 or quest.complete and 1 or nil
            return quest.title, 10, nil, false, false, state, 0, quest.id
        end
        GetNumQuestLeaderBoards = function(index) return #(world.quests[index].objectives or {}) end
        GetQuestLogLeaderBoard = function(line, index)
            local objective = world.quests[index].objectives[line]
            return objective[1], objective[2], objective[3]
        end
    else
        GetNumQuestLogEntries, GetQuestLogTitle, GetNumQuestLeaderBoards, GetQuestLogLeaderBoard = nil, nil, nil, nil
        local function byId(id)
            for _, quest in ipairs(world.quests) do
                if quest.id == id then return quest end
            end
        end
        C_QuestLog = {
            GetNumQuestLogEntries = function()
                -- Like the game: a collapsed header takes its quests out of the
                -- visible lines but not out of the quest count.
                if world.collapsed then return 1, #world.quests end
                return #world.quests + 1, #world.quests
            end,
            GetInfo = function(index)
                if index == 1 then return { isHeader = true, isCollapsed = world.collapsed, title = "Zone" } end
                if world.collapsed then return nil end
                local quest = world.quests[index - 1]
                if not quest then return nil end
                return { questID = quest.id, title = quest.title, level = 10, isHeader = false, isHidden = quest.hidden }
            end,
            IsComplete = function(id) local q = byId(id); return q and q.complete or false end,
            IsFailed = function(id) local q = byId(id); return q and q.failed or false end,
            GetQuestObjectives = function(id)
                local out = {}
                for _, objective in ipairs((byId(id) or {}).objectives or {}) do
                    out[#out + 1] = { text = objective[1], type = objective[2], finished = objective[3] }
                end
                return out
            end,
            IsQuestFlaggedCompleted = function(id) return world.completed[id] or false end,
            GetNextWaypoint = function(id)
                local point = world.nextWaypoint[id]
                if point then return point[1], point[2], point[3] end
            end,
        }
    end

    C_Map = {
        GetBestMapForUnit = function() return world.player.map end,
        GetMapInfo = function(mapId)
            local map = MAPS[mapId]
            return map and { name = map.name, mapID = mapId, parentMapID = 0, mapType = 3 } or nil
        end,
        GetMapChildrenInfo = function()
            local out = {}
            for mapId, map in pairs(MAPS) do out[#out + 1] = { name = map.name, mapID = mapId, mapType = 3 } end
            return out
        end,
        GetAreaInfo = function(areaId)
            world.areaLookups = (world.areaLookups or 0) + 1
            local mapId = AREA_TO_MAP[areaId]
            return mapId and MAPS[mapId].name or nil
        end,
        GetPlayerMapPosition = function()
            if world.secretPosition then return nil end
            return { x = world.player.x, y = world.player.y }
        end,
        GetWorldPosFromMapPos = function(mapId, position)
            local map = MAPS[mapId]
            if not map then return nil end
            return map.instance, { x = map.oy + position.y * map.size, y = map.ox + position.x * map.size }
        end,
        GetMapPosFromWorldPos = function(_, position, mapId)
            local map = MAPS[mapId]
            if not map then return nil end
            local x, y = OnMap(mapId, position.x, position.y)
            return mapId, { x = x, y = y }
        end,
        -- The zone under a point of a continent map.
        GetMapInfoAtPosition = function(mapId, x, y)
            local parent = MAPS[mapId]
            if not parent or not parent.continent then return nil end
            local gx, gy = parent.oy + y * parent.size, parent.ox + x * parent.size
            for id, map in pairs(MAPS) do
                if map.real and map.instance == parent.instance then
                    local zx, zy = OnMap(id, gx, gy)
                    if zx >= 0 and zx <= 1 and zy >= 0 and zy <= 1 then return { mapID = id, name = map.name } end
                end
            end
            return { mapID = mapId, name = parent.name }
        end,
        CanSetUserWaypointOnMap = function(mapId) return MAPS[mapId] ~= nil end,
        OpenWorldMap = function(mapId) world.openedMap = mapId end,
        SetUserWaypoint = function(point) world.userWaypoint = point end,
        GetUserWaypoint = function() return world.userWaypoint end,
        ClearUserWaypoint = function()
            world.userWaypoint = nil
            world.clearedUserWaypoint = world.clearedUserWaypoint + 1
        end,
    }
    C_SuperTrack = { SetSuperTrackedUserWaypoint = function(value) world.superTracked = value end }

    -- HereBeDragons, as TomTom or Questie would have registered it.
    LibStub = nil
    if world.hbd then
        local hbd = {}
        function hbd:GetPlayerWorldPosition()
            if world.secretPosition then return SECRET, SECRET, 1 end
            return PlayerWorld()
        end
        function hbd:GetWorldCoordinatesFromZone(x, y, mapId)
            local map = MAPS[mapId]
            if not map then return nil end
            return map.ox + x * map.size, map.oy + y * map.size, map.instance
        end
        function hbd:GetZoneCoordinatesFromWorld(x, y, mapId)
            if not MAPS[mapId] then return nil end
            return OnMap(mapId, y, x)
        end
        -- The pin library, recording what is on the maps.
        local pins = {}
        function pins:AddWorldMapIconWorld(ref, icon, instance, x, y, flag)
            world.mapPins[icon] = { ref = ref, instance = instance, x = x, y = y, flag = flag }
            return true
        end
        function pins:AddMinimapIconWorld(ref, icon, instance, x, y, floatOnEdge)
            world.minimapPins[icon] = { ref = ref, instance = instance, x = x, y = y, edge = floatOnEdge }
            return true
        end
        function pins:RemoveAllWorldMapIcons() world.mapPins = {} end
        function pins:RemoveAllMinimapIcons() world.minimapPins = {} end
        LibStub = setmetatable({}, { __call = function(_, name)
            if name == "HereBeDragons-2.0" then return hbd end
            if name == "HereBeDragons-Pins-2.0" and world.pins ~= false then return pins end
            return nil
        end })
    end

    -- Questie's zone module.
    QuestieLoader = nil
    if world.questie then
        local zoneDB = {}
        function zoneDB:GetUiMapIdByAreaId(areaId) return AREA_TO_MAP[areaId] end
        function zoneDB:GetDungeonLocation(areaId) return world.dungeons[areaId] end
        QuestieLoader = { ImportModule = function(_, name) return name == "ZoneDB" and zoneDB or {} end }
    end

    -- QuestieDB public library.
    LibQuestieDB = nil
    if world.questieDB then
        local db = world.db
        local function reader(kind, field)
            return function(id)
                if world.dbThrows then error("database exploded") end
                local row = db[kind][id]
                return row and row[field] or nil
            end
        end
        LibQuestieDB = {
            contractVersion = world.contract or 4,
            RequireContract = function(required) return required == (world.contract or 4) end,
            Quest = {
                Exists = function(id) return db.quests[id] ~= nil end,
                objectives = reader("quests", "objectives"),
                sourceItemId = reader("quests", "sourceItemId"),
                requiredSourceItems = reader("quests", "requiredSourceItems"),
                triggerEnd = reader("quests", "triggerEnd"),
                finishedBy = reader("quests", "finishedBy"),
            },
            Npc = {
                name = reader("npcs", "name"),
                spawns = reader("npcs", "spawns"),
                friendlyToFaction = reader("npcs", "friendlyToFaction"),
            },
            Object = { name = reader("objects", "name"), spawns = reader("objects", "spawns") },
            Item = { name = reader("items", "name"), startQuest = reader("items", "startQuest") },
        }
    end

    TomTom = nil
    if world.tomtom then
        TomTom = {}
        function TomTom:AddWaypoint(mapId, x, y, opts)
            local uid = { mapId, x, y, title = opts.title, from = opts.from, opts = opts }
            world.waypoints[uid] = true
            world.waypointAdds = world.waypointAdds + 1
            world.lastWaypoint = uid
            return uid
        end
        function TomTom:RemoveWaypoint(uid) world.waypoints[uid] = nil end
        function TomTom:IsValidWaypoint(uid) return world.waypoints[uid] == true end
    end
end

-- Loads the addon files in TOC order against the current world.
local function Load()
    InstallGlobals()
    local ns = {}
    for line in io.lines(ROOT .. "DropOff.toc") do
        local file = line:match("^([%w_]+%.lua)%s*$")
        if file then
            local chunk = assert(loadfile(ROOT .. file))
            chunk("DropOff", ns)
        end
    end
    -- Most tests are about the list, not about travel: no flights or boats.
    if not world.travel then
        ns.TravelData = { nodes = {}, flights = {}, transports = {} }
        ns.Route.Reset()
    end
    ns.eventFrame.scripts.OnEvent(ns.eventFrame, "ADDON_LOADED", "DropOff")
    return ns
end

local function Fire(ns, event, ...)
    ns.eventFrame.scripts.OnEvent(ns.eventFrame, event, ...)
end

local function Put(id, count, bag, slot)
    bag = bag or 0
    local slots = world.bags[bag].slots
    slots[slot or (#slots + 1)] = { id = id, count = count or 1 }
end

local function LiveWaypoints()
    local list = {}
    for uid in pairs(world.waypoints) do list[#list + 1] = uid end
    return list
end

local function ChatHas(text)
    for _, line in ipairs(world.chat) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

-- The standard scene: Horde player in Durotar at 40,50.
--   Q1  finished, 2 slots of item 100, handed in 100 yd away (Durotar 50,50)
--   Q2  all objectives done but not flagged complete, item 200, Barrens (far)
--   Q3  finished, no items, 10 yd away
--   Q4  in progress, holds item 300
--   Q5  failed
--   Q6  delivery (no objectives), source item 400, 300 yd away
--   Q7  no objective lines loaded yet, database says it has objectives
local function Scene()
    NewWorld()
    world.items = {
        [100] = { name = "Wolf Pelt", class = 12 },
        [200] = { name = "Boar Tusk", class = 12 },
        [300] = { name = "Scorpid Tail", class = 12 },
        [400] = { name = "Sealed Letter", class = 12 },
        [900] = { name = "Linen Cloth", class = 7 },
    }
    Put(100, 5); Put(100, 3); Put(200, 4); Put(300, 1); Put(400, 1); Put(900, 20)

    world.quests = {
        { id = 1, title = "Pelts", complete = true, objectives = { { "Wolf Pelt: 8/8", "item", true } } },
        { id = 2, title = "Tusks", complete = false, objectives = { { "Boar Tusk: 4/4", "item", true } } },
        { id = 3, title = "Report", complete = true, objectives = { { "Speak to the scout", "event", true } } },
        { id = 4, title = "Tails", complete = false, objectives = { { "Scorpid Tail: 1/6", "item", false } } },
        { id = 5, title = "Escort", complete = true, failed = true, objectives = {} },
        { id = 6, title = "Letter", complete = false, objectives = {} },
        { id = 7, title = "Unloaded", complete = false, objectives = {} },
    }
    world.db.quests = {
        [1] = { objectives = { nil, nil, { { 100 } } }, finishedBy = { { 10 } } },
        [2] = { objectives = { nil, nil, { { 200 } } }, finishedBy = { { 20 } } },
        [3] = { objectives = {}, finishedBy = { { 30 } } },
        [4] = { objectives = { nil, nil, { { 300 } } }, finishedBy = { { 10 } } },
        [5] = { objectives = {}, finishedBy = { { 10 } } },
        [6] = { objectives = {}, sourceItemId = 400, finishedBy = { { 60 } } },
        [7] = { objectives = { { { 55, nil, 1 } } }, finishedBy = { { 10 } } },
    }
    world.db.npcs = {
        [10] = { name = "Tanner", spawns = { [14] = { { 50, 50 } } }, friendlyToFaction = "H" },
        [20] = { name = "Hunter", spawns = { [17] = { { 50, 50 } } }, friendlyToFaction = "AH" },
        [30] = { name = "Scout", spawns = { [14] = { { 41, 50 } } }, friendlyToFaction = "H" },
        [60] = { name = "Courier", spawns = { [14] = { { 70, 50 } } } },
    }
    return world
end

local function Titles(list)
    local out = {}
    for _, quest in ipairs(list) do out[#out + 1] = quest.title end
    return table.concat(out, ",")
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

test("bag scan counts slots, stacks and free space", function()
    Scene()
    local ns = Load()
    local items, free = ns.Data.ScanBags()
    eq(items[100].slots, 2, "wolf pelt slots")
    eq(items[100].count, 8, "wolf pelt count")
    eq(items[200].slots, 1, "boar tusk slots")
    eq(free, 10, "free slots")
end)

test("special bags do not count as free space", function()
    Scene()
    world.bags[1] = { size = 10, slots = {}, family = 1 }
    local ns = Load()
    local _, free = ns.Data.ScanBags()
    eq(free, 10, "quiver ignored")
end)

test("finished quests: items first, nearest first", function()
    Scene()
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Pelts,Letter,Tusks,Report", "route order")
    eq(math.floor(plan.ready[1].target.dist + 0.5), 100, "nearest distance")
    eq(plan.ready[1].target.name, "Tanner", "finisher name")
    eq(plan.ready[1].target.zone, "Durotar", "zone name")
    eq(plan.ready[1].slots, 2, "slots freed by Pelts")
    eq(plan.readySlots, 4, "slots freed in total")
    eq(plan.readyWithItems, 3, "finished quests holding items")
    eq(Titles(plan.progress), "Tails", "in progress with items")
    eq(#plan.orphans, 0, "no leftovers")
end)

test("readiness rules", function()
    Scene()
    local ns = Load()
    local plan = ns.Plan.Build()
    local byTitle = {}
    for _, quest in ipairs(plan.all) do byTitle[quest.title] = quest end
    check(byTitle.Tusks.ready, "all objectives done counts as ready")
    check(byTitle.Letter.ready, "delivery without objectives is ready")
    check(not byTitle.Escort.ready, "failed quest is not ready")
    check(not byTitle.Unloaded.ready, "objectives not loaded yet is not ready")
    check(not byTitle.Tails.ready, "unfinished objective is not ready")
end)

test("hidden trigger quests are not treated as deliveries", function()
    Scene()
    world.db.quests[6].triggerEnd = { "Reach the tower", { [14] = { { 10, 10 } } } }
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Pelts,Tusks,Report", "Letter waits for its trigger")
end)

test("finisher of the other faction is skipped", function()
    Scene()
    world.db.quests[1].finishedBy = { { 11, 12 } }
    world.db.npcs[11] = { name = "Alliance Tanner", spawns = { [14] = { { 41, 50 } } }, friendlyToFaction = "A" }
    world.db.npcs[12] = { name = "Horde Tanner", spawns = { [14] = { { 60, 50 } } }, friendlyToFaction = "H" }
    local ns = Load()
    local plan = ns.Plan.Build()
    local pelts
    for _, quest in ipairs(plan.ready) do if quest.title == "Pelts" then pelts = quest end end
    eq(pelts.target.name, "Horde Tanner", "friendly finisher wins over a closer hostile one")
end)

test("object finisher inside a dungeon points at the entrance", function()
    Scene()
    world.db.quests[1].finishedBy = { nil, { 70 } }
    world.db.objects[70] = { name = "Altar", spawns = { [209] = { { -1, -1 } } } }
    world.dungeons[209] = { { 17, 30, 30 } }
    local ns = Load()
    local plan = ns.Plan.Build()
    local pelts
    for _, quest in ipairs(plan.ready) do if quest.title == "Pelts" then pelts = quest end end
    eq(pelts.target.name, "Altar", "object name")
    eq(pelts.target.mapId, 1413, "entrance map")
    check(pelts.target.dungeon, "flagged as dungeon")
end)

test("another continent sorts after known distances", function()
    Scene()
    world.db.npcs[10].spawns = { [12] = { { 50, 50 } } }
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Letter,Tusks,Pelts,Report", "far quest last among item quests")
    local pelts = plan.ready[3]
    eq(pelts.target.dist, nil, "no distance across continents")
    check(pelts.target.far, "flagged far")
end)

test("nearest of several spawns is used", function()
    Scene()
    world.db.npcs[10].spawns = { [17] = { { 50, 50 } }, [14] = { { 90, 50 }, { 45, 50 } } }
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(math.floor(plan.ready[1].target.dist + 0.5), 50, "closest spawn")
end)

test("without QuestieDB: items matched by objective text, no directions", function()
    Scene()
    world.questieDB, world.questie = false, false
    local ns = Load()
    local plan = ns.Plan.Build()
    check(not plan.hasDB, "no database")
    local pelts
    for _, quest in ipairs(plan.ready) do if quest.title == "Pelts" then pelts = quest end end
    eq(pelts.slots, 2, "items tied through the objective text")
    eq(pelts.target, nil, "no target without a database")
    ns.UI.Show()
    local found = false
    for _, line in ipairs(ns.UI.Lines(ns.state.plan)) do
        if line.text == ns.L.NEED_QUESTIE then found = true end
    end
    check(found, "window asks for Questie")
    eq(#LiveWaypoints(), 0, "nothing to point at")
end)

test("game waypoint is used when the database has no finisher", function()
    Scene()
    world.db.quests[1] = nil
    world.nextWaypoint[1] = { 1411, 0.45, 0.50 }
    local ns = Load()
    local plan = ns.Plan.Build()
    local pelts
    for _, quest in ipairs(plan.ready) do if quest.title == "Pelts" then pelts = quest end end
    check(pelts.target and pelts.target.native, "native waypoint target")
    eq(math.floor(pelts.target.dist + 0.5), 50, "distance to the native waypoint")
    eq(pelts.slots, 2, "items still tied by text")
end)

test("leftover quest items are listed, ordinary items are not", function()
    Scene()
    world.items[600] = { name = "Strange Map", class = 12 }
    world.items[601] = { name = "Old Token", class = 12 }
    world.db.items[600] = { startQuest = 77 }
    Put(600, 1); Put(601, 2)
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(#plan.orphans, 2, "two leftovers")
    local byName = {}
    for _, item in ipairs(plan.orphans) do byName[item.name] = item end
    check(byName["Strange Map"].starts, "item starts a quest")
    check(not byName["Old Token"].starts, "plain leftover")
    check(byName["Linen Cloth"] == nil, "trade goods ignored")
end)

test("an item that starts an already completed quest is a plain leftover", function()
    Scene()
    world.items[600] = { name = "Strange Map", class = 12 }
    world.db.items[600] = { startQuest = 77 }
    world.completed[77] = true
    Put(600, 1)
    local ns = Load()
    check(not ns.Plan.Build().orphans[1].starts, "not flagged as a quest starter")
end)

test("an item shared by two finished quests frees its slots once", function()
    Scene()
    world.db.quests[3].objectives = { nil, nil, { { 100 } } }
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(plan.readySlots, 4, "shared item counted once")
end)

test("opening the window points TomTom at the nearest turn-in", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    check(ns.IsOpen(), "window open")
    local live = LiveWaypoints()
    eq(#live, 1, "one waypoint")
    eq(live[1][1], 1411, "map")
    eq(live[1][2], 0.5, "x")
    eq(live[1].from, "DropOff", "owner tag")
    eq(live[1].opts.cleardistance, 0, "arrow stays until the hand-in")
    eq(live[1].opts.persistent, false, "not saved by TomTom")
    check(ChatHas("Pelts (Tanner)"), "announced in chat")
    eq(DropOffFrame.summary.text, "4 to turn in · frees 4 slots · 10 free", "summary line")

    Advance(10)
    eq(world.waypointAdds, 1, "ticks do not re-add the same waypoint")
end)

test("handing in a quest moves the arrow to the next one", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    table.remove(world.quests, 1)
    world.bags[0].slots[1], world.bags[0].slots[2] = nil, nil
    Fire(ns, "QUEST_REMOVED", 1)
    Advance(1)
    local live = LiveWaypoints()
    eq(#live, 1, "still one waypoint")
    eq(live[1].title, "Letter (Courier)", "next target")
    eq(math.floor(live[1][2] * 100 + 0.5), 70, "next x")
end)

test("closing removes only DropOff's waypoint", function()
    Scene()
    local ns = Load()
    local foreign = TomTom:AddWaypoint(1411, 0.1, 0.1, { title = "Mine", from = "Player" })
    ns.Toggle()
    eq(#LiveWaypoints(), 2, "ours plus the player's")
    ns.Toggle()
    check(not ns.IsOpen(), "window closed")
    local live = LiveWaypoints()
    eq(#live, 1, "one left")
    eq(live[1], foreign, "the player's waypoint survives")
    eq(DropOffCharDB.open, false, "closed state saved")
end)

test("the close button stops the guidance too", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    DropOffFrame.close:Click()
    check(not ns.IsOpen(), "closed")
    eq(#LiveWaypoints(), 0, "waypoint removed")
end)

test("hiding the whole UI keeps turn-in mode", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    DropOffFrame:ParentHidden()
    eq(#LiveWaypoints(), 1, "waypoint kept")
    eq(DropOffCharDB.open, true, "still open")
    DropOffFrame:ParentShown()
    Advance(10)
    eq(world.waypointAdds, 1, "no duplicate waypoint")
end)

test("a waypoint removed by hand is not forced back", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    TomTom:RemoveWaypoint(world.lastWaypoint)
    Advance(10)
    eq(#LiveWaypoints(), 0, "stays removed")
end)

test("clicking a row pins that quest", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    ns.Pin(2)
    eq(LiveWaypoints()[1].title, "Tusks (Hunter)", "pinned quest is the target")
    ns.Pin(2)
    eq(LiveWaypoints()[1].title, "Pelts (Tanner)", "unpinned goes back to the nearest")
end)

test("the map button heads to that quest and opens the map on it", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    local row
    for _, candidate in ipairs(ns.UI.Rows()) do
        if candidate.data.questID == 2 then row = candidate end
    end
    check(row and row.map:IsShown(), "button shown on a quest with a known place")
    row.map:Click()
    eq(LiveWaypoints()[1].title, "Tusks (Hunter)", "that quest is the target")
    eq(world.openedMap, 1413, "world map opened on the hand-in zone")
    row.map:Click()
    eq(LiveWaypoints()[1].title, "Tusks (Hunter)", "a second click keeps it")

    for _, candidate in ipairs(ns.UI.Rows()) do
        if candidate.data.title == "Tails" then check(not candidate.map:IsShown(), "no button on a quest in progress") end
    end
end)

test("the map button falls back to the map panel, and says so when it cannot", function()
    Scene()
    local ns = Load()
    C_Map.OpenWorldMap = function() end   -- does not throw, opens nothing
    WorldMapFrame = { shown = false }
    function WorldMapFrame:IsShown() return self.shown end
    function WorldMapFrame:Show() self.shown = true end
    function WorldMapFrame:SetMapID(mapId) self.mapId = mapId end
    ns.Toggle()
    ns.ShowOnMap(1)
    check(WorldMapFrame.shown, "panel shown by hand when the call opened nothing")
    eq(WorldMapFrame.mapId, 1411, "panel set to the zone")

    WorldMapFrame.shown = false
    function WorldMapFrame:SetMapID() error("bad map") end
    world.chat = {}
    ns.ShowOnMap(1)
    check(WorldMapFrame.shown and not ChatHas(ns.L.MSG_NO_MAP), "an open map on the wrong zone is not reported as a failure")

    C_Map.OpenWorldMap = nil
    WorldMapFrame = nil
    world.chat = {}
    ns.ShowOnMap(1)
    check(ChatHas(ns.L.MSG_NO_MAP), "says the map cannot be opened")
end)

test("with OpenMap the map view is moved onto the hand-in", function()
    Scene()
    local ns = Load()
    local stitched, moves = false, {}
    OpenMapAPI = {
        major = 1,
        IsStitched = function() return stitched end,
        WorldFromMap = function(mapId, x, y) return mapId + x, mapId + y end,
        ShowWorld = function(u, v) moves[#moves + 1] = { u, v } return true end,
    }
    ns.Toggle()
    ns.ShowOnMap(2)
    eq(#moves, 0, "nothing moves before the map has settled")
    Advance(0.3)
    eq(#moves, 0, "a map that is not stitched yet is left alone")
    stitched = true
    Advance(1)
    eq(#moves, 1, "the second try moves the view once")
    eq(moves[1][1], 1413 + 0.5, "to the hand-in's place on the map")

    moves = {}
    ns.ShowOnMap(2)
    Advance(2)
    eq(#moves, 1, "an open stitched map is moved on the first try only")

    OpenMapAPI.major = 2
    moves = {}
    ns.ShowOnMap(2)
    Advance(2)
    eq(#moves, 0, "an API version this was not written for is not called")

    OpenMapAPI = { major = 1, IsStitched = function() return true end,
        WorldFromMap = function() error("boom") end, ShowWorld = function() end }
    world.chat = {}
    ns.ShowOnMap(2)
    Advance(2)
    check(not ChatHas("error"), "a throwing OpenMap is ignored")
    OpenMapAPI = nil
end)

test("without TomTom the game's map pin is used", function()
    Scene()
    world.tomtom = false
    local ns = Load()
    ns.Toggle()
    eq(world.userWaypoint.uiMapID, 1411, "pin map")
    eq(world.userWaypoint.position.x, 0.5, "pin x")
    eq(world.superTracked, true, "pin is tracked")
    ns.Toggle()
    eq(world.userWaypoint, nil, "pin cleared on close")
end)

test("a map pin the player replaced is left alone", function()
    Scene()
    world.tomtom = false
    local ns = Load()
    ns.Toggle()
    world.userWaypoint = { uiMapID = 1413, position = { x = 0.2, y = 0.2 } }
    ns.Toggle()
    eq(world.clearedUserWaypoint, 0, "player's pin not cleared")
end)

test("bag hint when nearly full, throttled", function()
    Scene()
    for _ = 1, 7 do Put(900, 20) end
    local ns = Load()
    Fire(ns, "BAG_UPDATE_DELAYED")
    Advance(3)
    check(ChatHas("3 free slots left. 3 finished quests hold 4 slots"), "hint printed")
    local count = #world.chat
    Fire(ns, "BAG_UPDATE_DELAYED")
    Advance(3)
    eq(#world.chat, count, "no repeat inside five minutes")
    Advance(300)
    Fire(ns, "BAG_UPDATE_DELAYED")
    Advance(3)
    eq(#world.chat, count + 1, "repeats after five minutes")
end)

test("no bag hint with room to spare, or when switched off", function()
    Scene()
    local ns = Load()
    Fire(ns, "BAG_UPDATE_DELAYED")
    Advance(3)
    eq(#world.chat, 0, "plenty of room")

    Scene()
    for _ = 1, 7 do Put(900, 20) end
    ns = Load()
    SlashCmdList.DROPOFF("alert")
    world.chat = {}
    Fire(ns, "BAG_UPDATE_DELAYED")
    Advance(3)
    eq(#world.chat, 0, "alert off")
end)

test("slash commands", function()
    Scene()
    local ns = Load()
    SlashCmdList.DROPOFF("")
    check(ns.IsOpen(), "/dropoff opens")
    SlashCmdList.DROPOFF("")
    check(not ns.IsOpen(), "/dropoff closes")

    world.chat = {}
    SlashCmdList.DROPOFF("list")
    check(ChatHas("1. Pelts · Tanner · 100 yd · +2"), "list line")

    SlashCmdList.DROPOFF("debug")
    eq(type(DropOffDB.snapshot), "table", "snapshot stored")
    eq(#DropOffDB.snapshot.quests, 7, "snapshot covers the whole log")
    eq(DropOffDB.snapshot.api.questieDB, true, "snapshot records the database")
    check(DropOffDB.snapshot.error == nil, "snapshot built without error")
    eq(DropOffDB.snapshot.nav.mode, "tomtom", "snapshot records the navigation mode")
    eq(DropOffDB.snapshot.player.via, "hbd", "snapshot records the position source")

    world.chat = {}
    SlashCmdList.DROPOFF("nonsense")
    check(ChatHas("/dropoff"), "help printed")
end)

test("the window lists every section", function()
    Scene()
    world.items[601] = { name = "Old Token", class = 12 }
    Put(601, 2)
    local ns = Load()
    ns.Toggle()
    local labels, titles = {}, {}
    for _, line in ipairs(ns.UI.Lines(ns.state.plan)) do
        if line.kind == "label" then labels[line.text] = true else titles[#titles + 1] = line.title end
    end
    check(labels[ns.L.SECTION_READY], "ready header")
    check(labels[ns.L.SECTION_READY_NOITEMS], "ready without items header")
    check(labels[ns.L.SECTION_PROGRESS], "progress header")
    check(labels[ns.L.SECTION_ORPHANS], "leftovers header")
    check(labels[ns.L.NAV_TOMTOM], "navigation footer")
    eq(table.concat(titles, ","), "Pelts,Letter,Tusks,Report,Tails,Old Token", "row order")
    check(DropOffFrame.height and DropOffFrame.height > 200, "window grows with its content")
end)

test("nothing to turn in", function()
    NewWorld()
    local ns = Load()
    ns.Toggle()
    eq(DropOffFrame.summary.text, "Nothing to turn in · 16 free slots", "empty summary")
    eq(#LiveWaypoints(), 0, "no waypoint")
end)

test("French client", function()
    Scene()
    world.locale = "frFR"
    local ns = Load()
    ns.Toggle()
    eq(DropOffFrame.summary.text, "4 à rendre · libère 4 emplacements · 10 libres", "summary in French")
    check(ChatHas("prochaine quête à rendre : Pelts (Tanner) (100 m)"), "announcement in French")
end)

test("unsupported QuestieDB contract degrades to no database", function()
    Scene()
    world.contract = 9
    local ns = Load()
    local plan = ns.Plan.Build()
    check(not plan.hasDB, "database ignored")
    check(#plan.ready > 0, "list still built")
end)

test("a throwing database never breaks the list", function()
    Scene()
    world.dbThrows = true
    local ns = Load()
    local plan = ns.Plan.Build()
    check(#plan.ready > 0, "list still built")
    ns.Toggle()
    check(not ChatHas("error"), "no error surfaced")
end)

test("legacy quest log API", function()
    Scene()
    world.legacyQuestLog = true
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Pelts,Letter,Tusks,Report", "same route through the old API")
end)

test("secret player position: no distances, still a target", function()
    Scene()
    world.secretPosition = true
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(plan.ready[1].target.dist, nil, "no distance")
    check(plan.ready[1].target.mapId ~= nil, "place still known")
    ns.Toggle()
    eq(#LiveWaypoints(), 1, "arrow still set")
end)

test("no HereBeDragons: distances from the game's own map API", function()
    Scene()
    world.hbd, world.tomtom = false, false
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Pelts,Letter,Tusks,Report", "same route")
    eq(math.floor(plan.ready[1].target.dist + 0.5), 100, "same distance")
end)

test("no Questie zone module: areas resolved by map name", function()
    Scene()
    world.questie = false
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(plan.ready[1].target.mapId, 1411, "map found by name")
end)

test("window reopens after a reload when it was open", function()
    Scene()
    local ns = Load()
    DropOffCharDB.open = true
    Fire(ns, "PLAYER_ENTERING_WORLD")
    check(not ns.IsOpen(), "waits for other addons")
    Advance(4)
    check(ns.IsOpen(), "reopened")
end)

test("quests under a collapsed header are reported, not silently dropped", function()
    Scene()
    world.collapsed = true
    local ns = Load()
    local plan = ns.Plan.Build()
    eq(#plan.ready, 0, "nothing readable")
    eq(plan.hidden, 7, "hidden quests counted")
    local found = false
    for _, line in ipairs(ns.UI.Lines(plan)) do
        if line.kind == "label" and line.text == ns.L.HIDDEN_QUESTS:format(7) then found = true end
    end
    check(found, "window says so")
    world.chat = {}
    SlashCmdList.DROPOFF("list")
    check(ChatHas(ns.L.HIDDEN_QUESTS:format(7)), "list says so")

    world.collapsed = false
    eq(ns.Plan.Build().hidden, 0, "nothing hidden once expanded")
end)

test("a database that was still loading is asked again", function()
    Scene()
    local rows = world.db.quests
    world.db.quests = {}
    local ns = Load()
    eq(ns.Plan.Build().ready[1].target, nil, "no place while the database is empty")
    world.db.quests = rows
    local plan = ns.Plan.Build()
    eq(Titles(plan.ready), "Pelts,Letter,Tusks,Report", "route once it has loaded")
    eq(plan.ready[1].target.name, "Tanner", "place once it has loaded")
end)

test("an area nothing can place is not looked up again on every pass", function()
    Scene()
    world.questie = false
    world.db.npcs[10].spawns = { [9999] = { { 50, 50 } } }
    local ns = Load()
    ns.Plan.Build()
    local first = world.areaLookups
    ns.Plan.Build()
    eq(world.areaLookups, first, "miss remembered")
    Advance(11)
    ns.Plan.Build()
    check(world.areaLookups > first, "asked again after a while")
end)

test("the snapshot records the quest the arrow points at", function()
    Scene()
    local ns = Load()
    SlashCmdList.DROPOFF("debug")
    eq(DropOffDB.snapshot.current, nil, "nothing while the window is closed")
    ns.Toggle()
    SlashCmdList.DROPOFF("debug")
    eq(DropOffDB.snapshot.current, 1, "current quest while guiding")
    eq(DropOffDB.snapshot.hiddenQuests, 0, "hidden count recorded")
end)

---------------------------------------------------------------------------
-- Travel: the real flight masters, zeppelins and boats
---------------------------------------------------------------------------

-- Horde character standing at the Hammerfall flight master (Arathi), with one
-- finished quest to hand in to Karang Amakkar at Zoram'gar Outpost (Ashenvale).
local HAMMERFALL = { -916.3, -3496.9 }

local function TravelScene(gx, gy)
    NewWorld()
    world.travel = true
    local x, y = OnMap(1417, gx or HAMMERFALL[1], gy or HAMMERFALL[2])
    world.player = { map = 1417, x = x, y = y }
    world.items = { [100] = { name = "Vile Familiar Head", class = 12 } }
    Put(100, 1)
    world.quests = {
        { id = 1, title = "King of the Foulweald", complete = true, objectives = { { "Head: 1/1", "item", true } } },
    }
    world.db.quests = { [1] = { objectives = { nil, nil, { { 100 } } }, finishedBy = { { 10 } } } }
    local nx, ny = OnMap(1440, 3340, 1010)
    world.db.npcs = {
        [10] = { name = "Karang Amakkar", spawns = { [331] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" },
    }
    return world
end

local function Kinds(legs)
    local out = {}
    for _, leg in ipairs(legs) do out[#out + 1] = leg.kind end
    return table.concat(out, ",")
end

local function LabelTexts(ns)
    local out = {}
    for _, line in ipairs(ns.UI.Lines(ns.state.plan)) do
        if line.kind == "label" then out[#out + 1] = line.text end
    end
    return out
end

local function Count(tbl)
    local n = 0
    for _ in pairs(tbl) do n = n + 1 end
    return n
end

local function HasText(list, text)
    for _, line in ipairs(list) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

test("a hand-in on the other continent gets the whole trip", function()
    TravelScene()
    local ns = Load()
    ns.Toggle()
    local target = ns.state.plan.ready[1].target
    eq(Kinds(target.legs), "fly,walk,zeppelin,walk,fly,walk", "flight, zeppelin, flight, then on foot")
    check(target.eta > 8 * 60 and target.eta < 25 * 60, "a plausible travel time, got " .. tostring(target.eta))
    check(target.legs[#target.legs].final, "the last leg is the walk to the hand-in")

    local labels = LabelTexts(ns)
    check(HasText(labels, "Route · about"), "route header with the time")
    check(HasText(labels, "1. Fly to Undercity"), "step 1: the flight")
    check(HasText(labels, "2. Go to the zeppelin: Undercity"), "step 2: to the zeppelin tower")
    check(HasText(labels, "3. Take the zeppelin to Orgrimmar"), "step 3: the zeppelin")
    check(HasText(labels, "4. Go to the flight master: Orgrimmar"), "step 4: to the flight master")
    check(HasText(labels, "5. Fly to Zoram'gar Outpost"), "step 5: the second flight")
    check(HasText(labels, "6. Go to Karang Amakkar"), "step 6: the hand-in")
    check(HasText(labels, ns.L.ROUTE_ASSUMED), "says the flights are assumed")

    local waypoint = LiveWaypoints()[1]
    eq(waypoint.title, "Fly to Undercity", "the arrow says what to do now")
    eq(waypoint[1], 1417, "and points at the flight master here, not at the far hand-in")

    local row = ns.UI.Rows()[1]
    check(row.right:GetText():find("~%d+ min"), "the row shows a travel time instead of 'far'")
end)

test("the first step is the walk to the flight master", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local legs = ns.state.plan.ready[1].target.legs
    eq(legs[1].kind, "walk", "on foot first")
    eq(legs[1].to.node, 17, "to Hammerfall's flight master")
    check(HasText(LabelTexts(ns), "1. Go to the flight master: Hammerfall · 200 yd"), "with the distance")
    eq(LiveWaypoints()[1].title, "Go to the flight master: Hammerfall", "arrow text without the distance")

    local adds = world.waypointAdds
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 120, HAMMERFALL[2])
    Advance(2)
    eq(world.waypointAdds, adds, "walking toward it does not replace the waypoint")
    check(HasText(LabelTexts(ns), "Hammerfall · 120 yd"), "the distance follows the player")

    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 10, HAMMERFALL[2])
    Advance(2)
    eq(ns.state.plan.ready[1].target.legs[1].kind, "fly", "arrived: the next step is the flight")
end)

test("a hand-in close by is a plain walk, with no route block", function()
    TravelScene()
    local nx, ny = OnMap(1417, HAMMERFALL[1] - 150, HAMMERFALL[2])
    world.db.npcs[10].spawns = { [45] = { { nx * 100, ny * 100 } } }
    local ns = Load()
    ns.Toggle()
    local target = ns.state.plan.ready[1].target
    eq(Kinds(target.legs), "walk", "one walk")
    check(not HasText(LabelTexts(ns), "Route ·"), "no steps listed for a walk")
    eq(LiveWaypoints()[1].title, "King of the Foulweald (Karang Amakkar)", "the arrow points at the hand-in")
end)

test("the quickest hand-in comes first, whatever the continent", function()
    TravelScene()
    world.items[200] = { name = "Crate", class = 12 }
    Put(200, 1)
    world.quests[2] = { id = 2, title = "Crates", complete = true, objectives = { { "Crate: 1/1", "item", true } } }
    world.db.quests[2] = { objectives = { nil, nil, { { 200 } } }, finishedBy = { { 20 } } }
    local nx, ny = OnMap(1417, HAMMERFALL[1] - 300, HAMMERFALL[2])
    world.db.npcs[20] = { name = "Quartermaster", spawns = { [45] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    local ns = Load()
    ns.Toggle()
    eq(Titles(ns.state.plan.ready), "Crates,King of the Foulweald", "300 yd away before a 16 minute trip")
end)

test("the flight map tells which flight masters are known", function()
    TravelScene()
    local ns = Load()
    ns.Toggle()
    -- Hammerfall (here) and Tarren Mill are learned, Undercity is not.
    world.taxiNodes = {
        { nodeID = 17, state = 0 }, { nodeID = 13, state = 1 }, { nodeID = 11, state = 2 },
    }
    Fire(ns, "TAXIMAP_OPENED")
    Advance(1)
    check(DropOffCharDB.flights[17] and DropOffCharDB.flights[13], "learned ones recorded")
    check(not DropOffCharDB.flights[11], "one the map shows as not learned is not")
    check(DropOffCharDB.flightsSeen[0], "the continent counts as read")
    local legs = ns.state.plan.ready[1].target.legs
    for _, leg in ipairs(legs) do
        check(not (leg.kind == "fly" and leg.to.node == 11), "no flight to an unknown flight master")
    end
    eq(legs[1].kind, "fly", "still flies as far as it can")
    eq(legs[1].to.node, 13, "to Tarren Mill")
    check(not legs[1].assumed, "a flight on a read continent is not a guess")

    -- A later visit replaces what was known on that continent.
    world.taxiNodes = { { nodeID = 17, state = 0 }, { nodeID = 11, state = 1 } }
    Fire(ns, "TAXIMAP_OPENED")
    check(DropOffCharDB.flights[11] and not DropOffCharDB.flights[13], "the list is replaced, not added to")

    world.taxiNodes = {}
    Fire(ns, "TAXIMAP_OPENED")
    check(DropOffCharDB.flights[11], "an empty flight map changes nothing")
end)

test("an Alliance character takes boats, never a zeppelin", function()
    TravelScene(-1240.5, -2515.1)   -- Refuge Pointe
    world.faction = "Alliance"
    world.db.npcs[10].friendlyToFaction = "A"
    local ns = Load()
    ns.Toggle()
    local legs = ns.state.plan.ready[1].target.legs
    local kinds = Kinds(legs)
    check(kinds:find("boat", 1, true), "takes a boat: " .. kinds)
    check(not kinds:find("zeppelin", 1, true), "no zeppelin")
    for _, leg in ipairs(legs) do
        if leg.to.node then eq(ns.TravelData.nodes[leg.to.node][5] ~= "H", true, "no Horde flight master") end
    end
end)

test("the plan is kept as it was while on a flight path", function()
    TravelScene()
    local ns = Load()
    ns.Toggle()
    local before = ns.state.plan
    eq(LiveWaypoints()[1][1], 1417, "before take-off the arrow is on the flight master")
    world.onTaxi = true
    world.player.x, world.player.y = OnMap(1417, 0, -2000)
    Advance(5)
    check(ns.state.plan == before, "no new plan in mid-air")
    eq(LiveWaypoints()[1][1], 1415, "in the air the arrow is on where the flight lands")
    eq(LiveWaypoints()[1].title, "Fly to Undercity", "same step")
    world.onTaxi = false
    Advance(2)
    check(ns.state.plan ~= before, "planning resumes on landing")
end)

test("the route is drawn on the map and cleared with the window", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local onMap = Count(world.mapPins)
    check(onMap > 20, "dots and markers on the world map, got " .. onMap)
    check(onMap <= 320, "within the dot budget")
    check(Count(world.minimapPins) >= 3, "the walk to the flight master is on the minimap")
    for _, pin in pairs(world.mapPins) do
        eq(pin.flag, 3, "shown on zone, continent and world maps")
        check(pin.instance == 0 or pin.instance == 1, "on a continent")
    end
    check(ns.Trail.State().drawn, "state says drawn")

    local pinsBefore = world.mapPins
    Advance(2)
    check(world.mapPins == pinsBefore, "nothing is laid again while the player stands still")

    ns.Toggle()
    eq(Count(world.mapPins), 0, "closing the window clears the map")
    eq(Count(world.minimapPins), 0, "and the minimap")
end)

test("without TomTom the next stop is marked on the minimap rim", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    world.tomtom = false
    local ns = Load()
    ns.Toggle()
    local rim = 0
    for _, pin in pairs(world.minimapPins) do
        if pin.edge then rim = rim + 1 end
    end
    eq(rim, 1, "one marker that stays on the rim")
    eq(world.userWaypoint.uiMapID, 1417, "and the game's map pin is on the flight master")
end)

test("no pin library: the steps still show, nothing is drawn", function()
    TravelScene()
    world.pins = false
    local ns = Load()
    ns.Toggle()
    check(HasText(LabelTexts(ns), "1. Fly to Undercity"), "steps listed")
    check(not ns.Trail.State().drawn, "nothing drawn")
    check(not ChatHas("error"), "and no error")
end)

test("French steps", function()
    TravelScene()
    world.locale = "frFR"
    world.localNames = { { nodeID = 11, name = "Fossoyeuse, Tirisfal" }, { nodeID = 23, name = "Orgrimmar, Durotar" } }
    local ns = Load()
    ns.Toggle()
    local labels = LabelTexts(ns)
    check(HasText(labels, "Itinéraire · environ"), "header")
    check(HasText(labels, "1. Prends le vol pour Fossoyeuse"), "flight, with the game's own name")
    check(HasText(labels, "3. Prends le zeppelin pour Orgrimmar"), "zeppelin")
    check(HasText(labels, "6. Va voir Karang Amakkar"), "hand-in")
end)

test("route planner on a small network", function()
    NewWorld()
    local ns = Load()
    ns.TravelData = {
        nodes = {
            [1] = { "North Camp, Zone", 1, 0, 0, "H" },
            [2] = { "South Camp, Zone", 1, -6000, 0, "H" },
            [3] = { "Enemy Camp, Zone", 1, -3000, 0, "A" },
            [4] = { "Far Port, Zone", 0, 0, 0, "B" },
        },
        flights = { { 1, 3, 3000 }, { 3, 2, 3000 }, { 1, 2, 9000 } },
        transports = {
            { "boat", "South - Far", "B", 1, -6100, 0, 2, 0, 100, 0, 4 },
            { "zeppelin", "North - Far", "A", 1, 50, 0, 1, 0, 100, 0, 4 },
        },
    }
    ns.Route.Reset()

    check(ns.Route.To(0, 0, 1) == nil, "no route before a pass")
    check(not ns.Route.Begin(nil, nil, nil), "unknown player position")
    check(ns.Route.To(0, 0, 1) == nil, "still no route")

    check(ns.Route.Begin(10, 0, 1), "pass from next to North Camp")
    local seconds, legs = ns.Route.To(-6000, 100, 1)
    eq(Kinds(legs), "fly,walk", "flies, then walks")
    eq(legs[1].to.node, 2, "straight to South Camp")
    eq(legs[1].stops, 0, "not through the enemy camp")
    eq(math.floor(seconds), math.floor((10 * 1.3 / 7) + 9000 / 30 + 100 * 1.3 / 7), "walk + flight + walk")

    seconds, legs = ns.Route.To(-20, 0, 1)
    eq(Kinds(legs), "walk", "a short hop is walked")
    eq(math.floor(legs[1].yards), 30, "straight there")

    seconds, legs = ns.Route.To(150, 0, 0)
    eq(Kinds(legs), "fly,walk,boat,walk", "other continent: flight, to the dock, boat, walk")
    eq(legs[3].route, "South - Far", "the neutral boat, not the other faction's zeppelin")

    check(ns.Route.To(0, 0, 7) == nil, "a continent nothing goes to")

    check(ns.Route.Begin(0, 0, 7), "a pass from a place with no travel hub")
    check(ns.Route.To(0, 0, 1) == nil, "no way out")
    seconds, legs = ns.Route.To(30, 40, 7)
    eq(Kinds(legs), "walk", "but a walk on the spot works")
    eq(math.floor(legs[1].yards), 50, "by the straight line")
end)

test("the snapshot records the route", function()
    TravelScene()
    local ns = Load()
    ns.Toggle()
    SlashCmdList.DROPOFF("debug")
    local quest = DropOffDB.snapshot.quests[1]
    check(quest.target.eta and #quest.target.legs == 6, "legs and time saved")
    check(DropOffDB.snapshot.trail.drawn, "trail state saved")
    check(DropOffDB.snapshot.flights.allTaxiNodes, "flight map API noted")
end)

---------------------------------------------------------------------------

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
