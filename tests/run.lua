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
local MAPS = {
    [1411] = { name = "Durotar", ox = 0, oy = 0, size = 1000, instance = 1 },
    [1413] = { name = "The Barrens", ox = 2000, oy = 0, size = 1000, instance = 1 },
    [1429] = { name = "Elwynn Forest", ox = 0, oy = 0, size = 1000, instance = 0 },
}
local AREA_TO_MAP = { [14] = 1411, [17] = 1413, [12] = 1429 }

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
    issecretvalue = function(value) return value == SECRET end
    NUM_BAG_SLOTS = 4
    UIParent = Widget()
    GameTooltip = Widget()
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) world.chat[#world.chat + 1] = text end }
    SlashCmdList = {}
    DropOffDB, DropOffCharDB = nil, nil
    DropOffFrame = nil

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
            GetNumQuestLogEntries = function() return #world.quests + 1, #world.quests end,
            GetInfo = function(index)
                if index == 1 then return { isHeader = true, title = "Zone" } end
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
            return map.instance, { x = map.ox + position.x * map.size, y = map.oy + position.y * map.size }
        end,
        CanSetUserWaypointOnMap = function(mapId) return MAPS[mapId] ~= nil end,
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
        LibStub = setmetatable({}, { __call = function(_, name)
            if name == "HereBeDragons-2.0" then return hbd end
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

---------------------------------------------------------------------------

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
