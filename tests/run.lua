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
-- Lua 5.1's coroutines
---------------------------------------------------------------------------

-- The game runs Lua 5.1, which cannot yield across a pcall; LuaJIT, which
-- runs these tests, can. The embedded router slices its searches with
-- coroutines and calls DropOff back inside one: a yield under a pcall of the
-- same coroutine is made the error it would be in the game.
do
    local depth = setmetatable({}, { __mode = "k" })
    local realPcall, realXpcall, realYield = pcall, xpcall, coroutine.yield
    local function enter()
        local co = coroutine.running() or "main"
        depth[co] = (depth[co] or 0) + 1
        return co
    end
    local function leave(co, ...)
        depth[co] = depth[co] - 1
        return ...
    end
    pcall = function(fn, ...)
        local co = enter()
        return leave(co, realPcall(fn, ...))
    end
    xpcall = function(fn, handler, ...)
        local co = enter()
        return leave(co, realXpcall(fn, handler, ...))
    end
    coroutine.yield = function(...)
        local co = coroutine.running()
        if co and (depth[co] or 0) > 0 then error("attempt to yield across a pcall: the game's Lua 5.1 cannot", 2) end
        return realYield(...)
    end
end

---------------------------------------------------------------------------
-- The game's zlib and base64
---------------------------------------------------------------------------

-- For the tests that walk the real maps (DropOff_Paths_*): LuaJIT's ffi and
-- the system's zlib stand in for C_EncodingUtil. Without them those tests
-- are skipped, and say so.
local Inflate
do
    local ok, ffi = pcall(require, "ffi")
    local z
    if ok then
        ok = pcall(function()
            ffi.cdef([[
            typedef struct { const unsigned char *next_in; unsigned avail_in; unsigned long total_in;
              unsigned char *next_out; unsigned avail_out; unsigned long total_out; const char *msg; void *state;
              void *zalloc; void *zfree; void *opaque; int data_type; unsigned long adler; unsigned long reserved; } z_stream;
            int inflateInit_(z_stream *strm, const char *version, int stream_size);
            int inflate(z_stream *strm, int flush);
            int inflateEnd(z_stream *strm);
            const char *zlibVersion(void);
            ]])
            z = ffi.load("z")
        end)
    end
    if ok and z then
        Inflate = function(data)
            local strm = ffi.new("z_stream")
            if z.inflateInit_(strm, z.zlibVersion(), ffi.sizeof("z_stream")) ~= 0 then return nil end
            strm.next_in, strm.avail_in = data, #data
            local size = 1024 * 1024
            local buffer = ffi.new("unsigned char[?]", size)
            local out = {}
            while true do
                strm.next_out, strm.avail_out = buffer, size
                local code = z.inflate(strm, 0)
                out[#out + 1] = ffi.string(buffer, size - strm.avail_out)
                if code == 1 then break end
                if code ~= 0 then
                    z.inflateEnd(strm)
                    return nil
                end
            end
            z.inflateEnd(strm)
            return table.concat(out)
        end
    end
end

local BASE64 = {}
do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for index = 1, 64 do BASE64[alphabet:byte(index)] = index - 1 end
end

local function DecodeBase64(text)
    local out, acc, bits = {}, 0, 0
    for index = 1, #text do
        local value = BASE64[text:byte(index)]
        if value then
            acc, bits = acc * 64 + value, bits + 6
            if bits >= 8 then
                bits = bits - 8
                local char = math.floor(acc / 2 ^ bits)
                out[#out + 1] = string.char(char)
                acc = acc - char * 2 ^ bits
            end
        end
    end
    return table.concat(out)
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

local lines = {}   -- the lines the trail made on the world map, reset with the world

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
    function widget:SetAlpha(alpha) self.alpha = alpha end
    function widget:EnableMouseWheel(on) self.wheel = on and true or false end
    function widget:SetTexture(texture) self.texture = texture end
    function widget:GetPoint() return "RIGHT", nil, "RIGHT", -140, 60 end
    function widget:CreateTexture() return Widget() end
    function widget:CreateFontString() return Widget() end
    function widget:CreateLine()
        local line = Widget()
        function line:SetStartPoint(_, _, x, y) self.from = { x, y } end
        function line:SetEndPoint(_, _, x, y) self.to = { x, y } end
        function line:SetThickness(thickness) self.thickness = thickness end
        function line:SetColorTexture(r, g, b, a) self.colour = { r, g, b, a } end
        line.owner = self
        lines[#lines + 1] = line
        return line
    end
    function widget:Click(button) if self.scripts.OnClick then self.scripts.OnClick(self, button) end end
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
    -- `fake`: coordinates made up for the list tests. In the travel tests,
    -- laid out over the real world, these three sit on a continent of their own.
    [1411] = { name = "Durotar", ox = 0, oy = 0, size = 1000, instance = 1, fake = true },
    [1413] = { name = "The Barrens", ox = 2000, oy = 0, size = 1000, instance = 1, fake = true },
    [1429] = { name = "Elwynn Forest", ox = 0, oy = 0, size = 1000, instance = 0, fake = true },
    -- For the travel tests: the two continents and two zones, laid out over
    -- the real world coordinates of the travel data.
    [1415] = { name = "Eastern Kingdoms", ox = 20000, oy = 10000, size = -40000, instance = 0, continent = true },
    [1414] = { name = "Kalimdor", ox = 20000, oy = 15000, size = -40000, instance = 1, continent = true },
    [1417] = { name = "Arathi Highlands", ox = -800, oy = 0, size = -3600, instance = 0, real = true },
    [1440] = { name = "Ashenvale", ox = 1800, oy = 4700, size = -5800, instance = 1, real = true },
    [1412] = { name = "Mulgore", ox = 2048, oy = -273, size = -5140, instance = 1, real = true },
    [1442] = { name = "Stonetalon Mountains", ox = 3246, oy = 2917, size = -4883, instance = 1, real = true },
    [1443] = { name = "Desolace", ox = 4233, oy = 452, size = -4500, instance = 1, real = true },
    -- Rough ones, only there so the passes given on them can be placed: the
    -- walk from Tarren Mill to the zeppelins of Tirisfal goes through both.
    [1421] = { name = "Silverpine Forest", ox = 3400, oy = 1700, size = -4200, instance = 0 },
    [1424] = { name = "Hillsbrad Foothills", ox = 1000, oy = 400, size = -3200, instance = 0 },
    -- The city under the Ruins of Lordaeron: its own map, in Tirisfal.
    [1458] = { name = "Undercity", ox = 740, oy = 1926, size = -1000, instance = 0 },
}
local AREA_TO_MAP = { [14] = 1411, [17] = 1413, [12] = 1429, [45] = 1417, [331] = 1440, [405] = 1443 }

-- Map coordinates (0..1) of a point given in the game's world yards.
local function OnMap(mapId, gx, gy)
    local map = MAPS[mapId]
    return (gy - map.ox) / map.size, (gx - map.oy) / map.size
end

local world

-- The continent a map is on.
local function Instance(map)
    if world.travel and map.fake then return 9 end
    return map.instance
end

local function NewWorld()
    lines = {}
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
        engine = nil,       -- a router put in place of the embedded one (Router below)
        mapAddons = {},     -- the map addons the game knows: name -> true, "DISABLED", or "real" (reads the real files)
        loadCalls = {},     -- the addons asked for with LoadAddOn, in order
        lifts = false,      -- true: with the real lift table
        errors = {},        -- what reached the game's error handler
        combat = false,
        unread = nil,       -- files of the TOC the game did not read: { ["Walk.lua"] = true }
        onTaxi = false,
        taxiNodes = nil,    -- what the open flight map lists: { { nodeID, state } }
        unplaced = {},      -- mapId -> true: the game cannot turn its points into world yards yet
        minimap = true,     -- the game has a minimap to put the icon on
        minimapSize = nil,  -- its width and height; nil: it has no size yet
        viewRadius = nil,   -- yards it shows round the player, from C_Minimap; nil: the client has no such call
        zoom = 0,
        indoors = false,
        cvars = {},
        facing = nil,       -- the player's facing, radians from north, counter-clockwise
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

-- The addons holding the walking maps, and the continent of each.
local MAP_ADDONS = { DropOff_Paths_EasternKingdoms = 0, DropOff_Paths_Kalimdor = 1, DropOff_Paths_Zephras = 2991 }

local function InstallGlobals()
    now, timers = 1000, {}

    GetLocale = function() return world.locale end
    GetTime = function() return now end
    date = function() return "00:00:00" end
    GetBuildInfo = function() return "1.60.1", "70938", "Nov 1 2026", 16001 end
    UnitFactionGroup = function() return world.faction end
    InCombatLockdown = function() return world.combat or false end
    DropOffPathData = nil
    geterrorhandler = function() return function(err) world.errors[#world.errors + 1] = tostring(err) end end
    GetSubZoneText = function() return world.subzone or "" end
    C_EncodingUtil = Inflate and { DecodeBase64 = DecodeBase64, DecompressString = Inflate } or nil
    C_AddOns = {
        GetAddOnInfo = function(name)
            local how = world.mapAddons[name]
            if how == nil then return name, nil, nil, false, "MISSING" end
            return name, name, "", how ~= "DISABLED", how == "DISABLED" and "DISABLED" or nil
        end,
        LoadAddOn = function(name)
            world.loadCalls[#world.loadCalls + 1] = name
            local how = world.mapAddons[name]
            if how == nil then return false, "MISSING" end
            if how == "DISABLED" then return false, "DISABLED" end
            if how == "real" then
                -- As the game does: every file of the addon's TOC, in order.
                for line in io.lines(ROOT .. name .. "/" .. name .. ".toc") do
                    local file = line:match("^([%w_]+%.lua)%s*$")
                    if file then assert(loadfile(ROOT .. name .. "/" .. file))(name, {}) end
                end
            elseif world.engine and world.engine.maps then
                world.engine.maps[MAP_ADDONS[name]] = true
            end
            return true
        end,
    }
    UnitOnTaxi = function() return world.onTaxi end
    Enum = { FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }, CompressionMethod = { Zlib = 1 } }
    GetTaxiMapID = function() return 1415 end
    C_TaxiMap = {
        GetAllTaxiNodes = function() return world.taxiNodes or {} end,
        GetTaxiNodesForMap = function() return world.localNames or {} end,
    }
    issecretvalue = function(value) return value == SECRET end
    NUM_BAG_SLOTS = 4
    UIParent = Widget()
    Minimap = world.minimap and Widget() or nil
    if Minimap and world.minimapSize then
        function Minimap:GetWidth() return world.minimapSize end
        function Minimap:GetHeight() return world.minimapSize end
        function Minimap:GetZoom() return world.zoom or 0 end
    end
    C_Minimap = world.viewRadius and { GetViewRadius = function() return world.viewRadius end } or nil
    GetCVar = function(name) return world.cvars[name] end
    GetPlayerFacing = function() return world.facing end
    IsIndoors = function() return world.indoors or false end
    DropOffMinimapButton = nil
    GameTooltip = Widget()
    DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) world.chat[#world.chat + 1] = text end }
    SlashCmdList = {}
    DropOffDB, DropOffCharDB = nil, nil
    DropOffFrame = nil
    ChatFrame1 = nil
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

    CreateFrame = function(_, name, parent)
        local frame = Widget()
        frame.parent = parent
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
            if not map or world.unplaced[mapId] then return nil end
            return Instance(map), { x = map.oy + position.y * map.size, y = map.ox + position.x * map.size }
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
            if not map or world.unplaced[mapId] then return nil end
            return map.ox + x * map.size, map.oy + y * map.size, Instance(map)
        end
        function hbd:GetZoneCoordinatesFromWorld(x, y, mapId, anywhere)
            if not MAPS[mapId] then return nil end
            local zx, zy = OnMap(mapId, y, x)
            -- As the library does: nothing outside the map unless asked for.
            if not anywhere and (zx < 0 or zx > 1 or zy < 0 or zy > 1) then return nil end
            return zx, zy
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
            if opts.crazy then world.arrow = uid end
            return uid
        end
        function TomTom:RemoveWaypoint(uid) world.waypoints[uid] = nil end
        function TomTom:IsValidWaypoint(uid) return world.waypoints[uid] == true end
    end
end

-- Loads the addon files in TOC order against the current world. `saved`:
-- the account's saved variables, as a reload would hand them back.
local function Load(saved)
    InstallGlobals()
    DropOffDB = saved
    local ns = {}
    for line in io.lines(ROOT .. "DropOff.toc") do
        -- "Walk.lua", or "Router\Path.lua" for a file in a folder.
        local file = line:match("^([%w_\\]+%.lua)%s*$")
        file = file and file:gsub("\\", "/")
        local folder = file and file:match("^(.-)/")
        if file and not (world.unread and (world.unread[file] or world.unread[folder])) then
            local chunk = assert(loadfile(ROOT .. file))
            chunk("DropOff", ns)
        end
    end
    -- A test's own router stands in for the embedded one. Most tests are not
    -- about lifts: none.
    if world.engine ~= nil then ns.Path = world.engine end
    if not world.lifts then ns.TravelLifts = {} end
    -- Most tests are about the list, not about travel: no flights or boats.
    if not world.travel then
        ns.TravelData = { nodes = {}, flights = {}, transports = {} }
        ns.TravelPasses = nil
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

-- Is this text one of the lines the window shows, in the size it is in?
local function HasLabel(ns, text)
    for _, line in ipairs(ns.UI.Lines(ns.state.plan, ns.UI.IsCompact())) do
        if line.kind == "label" and line.text == text then return true end
    end
    return false
end

local function Titles(list)
    local out = {}
    for _, quest in ipairs(list) do out[#out + 1] = quest.title end
    return table.concat(out, ",")
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

test("the test kit makes a yield across a pcall the error it is in the game", function()
    local resumed = coroutine.wrap(function()
        local plain = coroutine.yield("plain")
        local ok, err = pcall(function() coroutine.yield("under a pcall") end)
        return plain, ok, err
    end)
    eq(resumed(), "plain", "a plain yield goes through")
    local plain, ok, err = resumed("back")
    eq(plain, "back", "and comes back")
    eq(ok, false, "a yield under a pcall of the same coroutine is an error")
    check(tostring(err):find("yield across a pcall", 1, true) ~= nil, "that says so: " .. tostring(err))
end)

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

test("a quest QuestieDB gives a finisher of another game goes to the Forever one", function()
    Scene()
    -- Elemental Aid: Bath'rah stands right here, Rau Cliffrunner far away.
    world.db.quests[79360] = { objectives = { nil, nil, { { 100 } } }, finishedBy = { { 6176, 4722 } } }
    world.quests[1].id = 79360
    world.db.npcs[6176] = { name = "Bath'rah the Windwatcher", spawns = { [14] = { { 41, 50 } } } }
    world.db.npcs[4722] = { name = "Rau Cliffrunner", spawns = { [14] = { { 90, 90 } } } }
    local ns = Load()
    local target
    for _, quest in ipairs(ns.Plan.Build().ready) do if quest.id == 79360 then target = quest.target end end
    eq(target.name, "Rau Cliffrunner", "the Forever finisher, though the other one is nearer")
    check(target.corrected, "and the snapshot can say why")

    -- A Forever finisher who will not talk to this character: the database's own list.
    world.db.npcs[4722].friendlyToFaction = "A"
    ns = Load()
    for _, quest in ipairs(ns.Plan.Build().ready) do if quest.id == 79360 then target = quest.target end end
    eq(target.name, "Bath'rah the Windwatcher", "the nearest friendly one, as for any quest")
    check(not target.corrected, "not corrected")

    -- Nor one the database has no place for.
    world.db.npcs[4722] = { name = "Rau Cliffrunner" }
    ns = Load()
    for _, quest in ipairs(ns.Plan.Build().ready) do if quest.id == 79360 then target = quest.target end end
    eq(target.name, "Bath'rah the Windwatcher", "a finisher with no place is no correction")
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

test("the minimap icon opens and closes the window", function()
    Scene()
    local ns = Load()
    check(DropOffMinimapButton ~= nil and DropOffMinimapButton:IsShown(), "the icon is there from the start, window closed")
    check(not ns.IsOpen(), "and the window is not opened by it")
    DropOffMinimapButton:Click("LeftButton")
    check(ns.IsOpen(), "a click opens")
    eq(#LiveWaypoints(), 1, "and the guidance starts")
    DropOffMinimapButton:Click("LeftButton")
    check(not ns.IsOpen(), "a second click closes")
    eq(#LiveWaypoints(), 0, "and stops it")

    DropOffFrame.close:Click()
    DropOffMinimapButton:Click("LeftButton")
    check(ns.IsOpen(), "after the cross, the icon is the way back in")

    world.chat = {}
    SlashCmdList.DROPOFF("minimap")
    check(not DropOffMinimapButton:IsShown(), "/dropoff minimap hides the icon")
    eq(DropOffDB.minimap.hide, true, "and that is remembered")
    check(ChatHas("/dropoff minimap"), "saying how to bring it back")
    SlashCmdList.DROPOFF("minimap")
    check(DropOffMinimapButton:IsShown(), "and shows it again")

    SlashCmdList.DROPOFF("debug")
    local window = DropOffDB.snapshot.window
    check(window.minimapIcon.made and window.minimapIcon.shown, "the snapshot says the icon is up")
    eq(window.compact, false, "and which size the window has")
end)

test("a hidden minimap icon stays hidden after a reload, and no minimap is no error", function()
    Scene()
    local ns = Load({ minimap = { hide = true, angle = 45 } })
    check(DropOffMinimapButton == nil, "not even made")
    eq(DropOffDB.minimap.angle, 45, "its place is kept")
    SlashCmdList.DROPOFF("minimap")
    check(DropOffMinimapButton ~= nil and DropOffMinimapButton:IsShown(), "/dropoff minimap brings it back")

    Scene()
    world.minimap = false
    ns = Load()
    check(DropOffMinimapButton == nil, "no minimap: no icon")
    ns.Toggle()
    check(ns.IsOpen() and not ChatHas("error"), "and the window works all the same")
end)

test("the small window shows only the next hand-in, and keeps guiding", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    local full = DropOffFrame.height
    eq(#ns.UI.Rows(), 5, "the whole list first")
    check(DropOffFrame.summary:IsShown(), "with its summary")

    DropOffFrame.size:Click()
    check(ns.IsOpen(), "the size button does not close the window")
    eq(DropOffCharDB.compact, true, "the size is remembered for this character")
    local rows = ns.UI.Rows()
    eq(#rows, 1, "one row")
    eq(rows[1].data.title, "Pelts", "the hand-in the arrow points at")
    check(rows[1].data.current, "marked as the current one")
    check(not DropOffFrame.summary:IsShown(), "no summary line")
    check(DropOffFrame.height < full / 2, "much smaller: " .. DropOffFrame.height .. " against " .. full)
    eq(#LiveWaypoints(), 1, "the arrow is still there")
    check(HasLabel(ns, ns.L.MORE:format(3)), "and it says how many more are waiting")

    Advance(10)
    eq(#ns.UI.Rows(), 1, "still one row after the refreshes")

    DropOffFrame.size:Click()
    eq(DropOffCharDB.compact, false, "the same button brings the list back")
    eq(#ns.UI.Rows(), 5, "every row again")
    check(DropOffFrame.summary:IsShown(), "and the summary")
    eq(DropOffFrame.height, full, "at its full height")
end)

-- Places the window and the chat box on a screen the mock has no layout for.
local function Place(top, chatTop, chatRight)
    function DropOffFrame:GetTop() return top end
    function DropOffFrame:GetLeft() return 900 end
    function DropOffFrame:GetRight() return 1230 end
    ChatFrame1 = Widget()
    function ChatFrame1:GetTop() return chatTop end
    function ChatFrame1:GetLeft() return 20 end
    function ChatFrame1:GetRight() return chatRight end
end

-- The count in a "+N below" or "N above" hint, nil when it is not that one.
local function HintCount(format, text, most)
    for count = 1, most do
        if format:format(count) == text then return count end
    end
end

local function DrawnTitles(ns)
    local out = {}
    for _, row in ipairs(ns.UI.Rows()) do out[#out + 1] = row.data.title end
    return table.concat(out, ",")
end

test("a long list stops above the chat box and scrolls with the wheel", function()
    Scene()
    local ns = Load()
    ns.Toggle()
    local full = DropOffFrame.height
    check(not DropOffFrame.more:IsShown(), "no hint while the game cannot place the window")
    check(not DropOffFrame.wheel, "and the wheel is left to the camera")

    Place(400, 150, 1000)
    ns.UI.Render(ns.state.plan)
    local cap = 400 - (150 + 28)
    check(full > cap, "the list is taller than the room: " .. full)
    eq(DropOffFrame.height, cap, "the window stops above the chat")
    check(DropOffFrame.wheel, "the wheel scrolls it")
    local total = #ns.UI.Lines(ns.state.plan, false)
    check(HintCount(ns.L.SCROLL_BELOW, DropOffFrame.more:GetText(), total),
        "it says how many lines are below: " .. tostring(DropOffFrame.more:GetText()))
    check(DropOffFrame.more:IsShown(), "shown")
    check(DropOffFrame.thumb:IsShown() and DropOffFrame.track:IsShown(), "a scroll bar shows where the view is")
    eq(DropOffFrame.thumb.down, 0, "at the top of its track")
    check(DropOffFrame.thumb.height < DropOffFrame.track.height, "shorter than its track")
    local first = DrawnTitles(ns)

    DropOffFrame.scripts.OnMouseWheel(DropOffFrame, -1)
    local scrolled = DrawnTitles(ns)
    check(scrolled ~= first, "a tick down shows other rows: " .. first .. " / " .. scrolled)
    eq(DropOffFrame.height, cap, "at the same height")
    check(DropOffFrame.thumb.down > 0, "the thumb moved down")
    local idle = DropOffFrame.thumb.alpha
    check(idle > 0, "the thumb lights up while the wheel turns")
    Advance(2)
    check(DropOffFrame.thumb.alpha < idle, "and fades back after")
    Advance(10)
    eq(DrawnTitles(ns), scrolled, "the refreshes keep the place")

    for _ = 1, 20 do DropOffFrame.scripts.OnMouseWheel(DropOffFrame, -1) end
    check(HintCount(ns.L.SCROLL_ABOVE, DropOffFrame.more:GetText(), total),
        "at the bottom it says what is above: " .. DropOffFrame.more:GetText())
    check(#ns.UI.Rows() > 0, "the last page is not empty")
    eq(DropOffFrame.thumb.down + DropOffFrame.thumb.height, DropOffFrame.track.height, "the thumb at the bottom")
    for _ = 1, 20 do DropOffFrame.scripts.OnMouseWheel(DropOffFrame, 1) end
    eq(DrawnTitles(ns), first, "back up to the top")

    DropOffFrame.size:Click()
    check(not DropOffFrame.wheel, "the small window leaves the wheel to the camera")
    check(not DropOffFrame.more:IsShown(), "and has no hint")
    check(not DropOffFrame.thumb:IsShown() and not DropOffFrame.track:IsShown(), "nor scroll bar")
    DropOffFrame.size:Click()
    eq(DrawnTitles(ns), first, "the whole list comes back from the top")

    Place(400, 150, 800)
    ns.UI.Render(ns.state.plan)
    check(not DropOffFrame.more:IsShown(), "a chat box beside the window leaves it whole")
    eq(DropOffFrame.height, full, "at its full height")
    check(not DropOffFrame.wheel, "and the wheel to the camera")
end)

test("the small window comes back small after a reload", function()
    Scene()
    local ns = Load()
    DropOffCharDB.open, DropOffCharDB.compact = true, true
    Fire(ns, "PLAYER_ENTERING_WORLD")
    Advance(4)
    check(ns.IsOpen(), "reopened")
    eq(#ns.UI.Rows(), 1, "small")
end)

test("a right-click on the minimap icon switches the size, opening the window", function()
    Scene()
    local ns = Load()
    DropOffMinimapButton:Click("RightButton")
    check(ns.IsOpen(), "opened")
    eq(#ns.UI.Rows(), 1, "small")
    DropOffMinimapButton:Click("RightButton")
    check(ns.IsOpen(), "still open")
    eq(#ns.UI.Rows(), 5, "the whole list")
    SlashCmdList.DROPOFF("mini")
    eq(#ns.UI.Rows(), 1, "/dropoff mini does the same")
end)

test("the small window says so when the quest log hides quests", function()
    Scene()
    world.collapsed = true
    local ns = Load()
    DropOffCharDB.compact = true
    ns.Toggle()
    eq(#ns.UI.Rows(), 0, "no row: nothing readable")
    check(HasLabel(ns, ns.L.HIDDEN_QUESTS:format(7)), "the warning of the whole list is there too")
end)

test("the small window with nothing to turn in", function()
    NewWorld()
    local ns = Load()
    DropOffCharDB.compact = true
    ns.Toggle()
    eq(#ns.UI.Rows(), 0, "no row")
    check(HasLabel(ns, ns.L.SUMMARY_NONE:format(16)), "one line saying so")
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

    local waypoint = world.arrow
    eq(waypoint.title, "Fly to Undercity", "the arrow says what to do now")
    eq(waypoint[1], 1417, "and points at the flight master here, not at the far hand-in")
    eq(#LiveWaypoints(), 2, "two waypoints: the stop and the hand-in")
    local handIn
    for _, uid in ipairs(LiveWaypoints()) do
        if uid ~= waypoint then handIn = uid end
    end
    eq(handIn.title, "King of the Foulweald (Karang Amakkar)", "the hand-in keeps its own pin")
    eq(handIn[1], 1440, "on its own map")
    check(handIn.opts.world and not handIn.opts.crazy and not handIn.opts.minimap, "on the world map only, without the arrow")

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
    eq(world.arrow.title, "Go to the flight master: Hammerfall", "arrow text without the distance")

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

test("a faction not known at login does not leave the network empty", function()
    TravelScene()
    world.faction = nil
    local ns = Load()
    ns.Toggle()
    local legs = ns.state.plan.ready[1].target.legs
    check(not legs or not Kinds(legs):find("zeppelin", 1, true), "no faction yet: no zeppelin")
    world.faction = "Horde"
    Advance(2)
    eq(Kinds(ns.state.plan.ready[1].target.legs), "fly,walk,zeppelin,walk,fly,walk", "the network is rebuilt once it is known")
end)

test("order stays consistent when only some hand-ins have a travel time", function()
    TravelScene()
    world.items[200] = { name = "Crate", class = 12 }
    world.items[300] = { name = "Barrel", class = 12 }
    Put(200, 1); Put(300, 1)
    world.quests[2] = { id = 2, title = "Crates", complete = true, objectives = { { "Crate: 1/1", "item", true } } }
    world.quests[3] = { id = 3, title = "Barrels", complete = true, objectives = { { "Barrel: 1/1", "item", true } } }
    world.db.quests[2] = { objectives = { nil, nil, { { 200 } } }, finishedBy = { { 20 } } }
    world.db.quests[3] = { objectives = { nil, nil, { { 300 } } }, finishedBy = { { 30 } } }
    local nx, ny = OnMap(1417, HAMMERFALL[1] - 300, HAMMERFALL[2])
    world.db.npcs[20] = { name = "Quartermaster", spawns = { [45] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    -- Elwynn in the mock sits on a continent nothing reaches from its fake coordinates.
    world.db.npcs[30] = { name = "Cooper", spawns = { [12] = { { 50, 50 } } }, friendlyToFaction = "H" }
    local ns = Load()
    ns.Toggle()
    eq(Titles(ns.state.plan.ready), "Crates,King of the Foulweald,Barrels", "timed trips first, the unreachable one last")
    check(not ChatHas("error"), "and the sort does not throw")
end)

test("a hand-in with a flight shows minutes even on the same continent", function()
    TravelScene()
    local nx, ny = OnMap(1415, 1568.6, 300)   -- next to Undercity's flight master
    AREA_TO_MAP[85] = 1415
    world.db.npcs[10].spawns = { [85] = { { nx * 100, ny * 100 } } }
    local ns = Load()
    ns.Toggle()
    AREA_TO_MAP[85] = nil
    local target = ns.state.plan.ready[1].target
    eq(Kinds(target.legs), "fly,walk", "a flight then a walk")
    check(target.dist ~= nil, "the straight distance is known")
    check(ns.UI.Rows()[1].right:GetText():find("~%d+ min"), "but the row tells the trip in minutes")
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

    -- A list without the master the player stands at is not a full read.
    world.taxiNodes = { { nodeID = 13, state = 1 } }
    Fire(ns, "TAXIMAP_OPENED")
    check(DropOffCharDB.flights[13] and DropOffCharDB.flights[11] and DropOffCharDB.flights[17],
        "a partial list adds, it does not remove")
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
    eq(world.arrow[1], 1417, "before take-off the arrow is on the flight master")
    world.onTaxi = true
    world.player.x, world.player.y = OnMap(1417, 0, -2000)
    Advance(5)
    check(ns.state.plan == before, "no new plan in mid-air")
    eq(world.arrow[1], 1415, "in the air the arrow is on where the flight lands")
    eq(world.arrow.title, "Fly to Undercity", "same step")
    world.onTaxi = false
    Advance(2)
    check(ns.state.plan ~= before, "planning resumes on landing")

    local stale = { { kind = "walk", from = {}, to = { node = 17 } }, { kind = "fly", from = {}, to = { node = 11 } } }
    eq(ns.Route.NextPlace(stale, "fly").node, 11, "in the air, a plan that still began with the walk points at the landing")
    eq(ns.Route.NextPlace(stale, nil).node, 17, "on the ground, at the flight master")
    eq(ns.Route.FirstLeg(stale, "ride"), nil, "no crossing in that plan")
end)

test("on a zeppelin the plan made before boarding is kept", function()
    -- On the Undercity platform of the Orgrimmar zeppelin.
    TravelScene()
    world.player = { map = 1415 }
    world.player.x, world.player.y = OnMap(1415, 2062.4, 293.0)
    local ns = Load()
    ns.Toggle()
    eq(ns.state.plan.ready[1].target.legs[1].kind, "zeppelin", "on the platform: the crossing is the first step")
    check(HasText(LabelTexts(ns), "1. Take the zeppelin to Orgrimmar"), "step 1 says so")

    -- The zeppelin leaves: 60 yards in a tick and a half.
    local before = ns.state.plan
    world.player.x, world.player.y = OnMap(1415, 2062.4 + 60, 293.0)
    Advance(1.5)
    world.player.x, world.player.y = OnMap(1415, 2062.4 + 120, 293.0)
    Advance(1.5)
    check(ns.state.plan == before, "no new plan on board")
    check(HasText(LabelTexts(ns), "1. Take the zeppelin to Orgrimmar"), "the step does not turn into 'go back to the zeppelin'")
    check(not HasText(LabelTexts(ns), "Go to the zeppelin"), "no walk back")
    eq(world.arrow[1], 1414, "the arrow is on where it lands, in Kalimdor")

    -- Walking away from the platform is not a crossing.
    TravelScene()
    world.player = { map = 1415 }
    world.player.x, world.player.y = OnMap(1415, 2062.4, 293.0)
    ns = Load()
    ns.Toggle()
    world.player.x, world.player.y = OnMap(1415, 2062.4 + 60, 293.0)
    Advance(9)
    eq(ns.state.plan.ready[1].target.legs[1].kind, "walk", "on foot the plan follows the player")
end)

test("the hand-in stays marked when nothing can draw the trail", function()
    TravelScene()
    world.pins = false
    local ns = Load()
    ns.Toggle()
    ns.ShowOnMap(1)
    eq(world.openedMap, 1440, "the map opens on the hand-in's zone")
    local found = false
    for _, uid in ipairs(LiveWaypoints()) do
        if uid[1] == 1440 then found = true end
    end
    check(found, "a TomTom pin is on the hand-in's map")
    ns.Toggle()
    eq(#LiveWaypoints(), 0, "closing removes both waypoints")
end)

test("the route is drawn on the map and cleared with the window", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local onMap = Count(world.mapPins)
    check(onMap > 20, "no world map to draw a line on: dots and markers, got " .. onMap)
    check(onMap <= 320, "within the dot budget")
    check(ns.Trail.State().dotted, "the state says the trip is laid as dots")
    for _, pin in pairs(world.minimapPins) do check(pin.edge, "no dot on the minimap") end
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

-- A world map with a canvas 1000 by 600, zoomed to twice the UI's scale.
local function OpenWorldMap(mapId)
    local canvas = Widget()
    function canvas:GetWidth() return 1000 end
    function canvas:GetHeight() return 600 end
    function canvas:GetEffectiveScale() return 2 end
    function canvas:GetFrameLevel() return 10 end
    WorldMapFrame = { mapId = mapId }
    function WorldMapFrame:GetCanvas() return canvas end
    function WorldMapFrame:GetMapID() return self.mapId end
    function UIParent:GetEffectiveScale() return 1 end
    return canvas
end

local function ShownLines()
    local out = {}
    for _, line in ipairs(lines) do
        if line.shown then out[#out + 1] = line end
    end
    return out
end

test("the trip is a line on the world map, on the map it shows", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    OpenWorldMap(1417)
    ns.Toggle()
    local legs = ns.state.plan.ready[1].target.legs
    local sameContinent = 0
    for _, leg in ipairs(legs) do
        if leg.from.continent == leg.to.continent then sameContinent = sameContinent + 1 end
    end
    eq(ns.Trail.State().lines, sameContinent, "one line per stretch on one continent, none for the crossing")

    -- The map shows Arathi: the stretches in the Eastern Kingdoms are on it.
    local shown = ShownLines()
    eq(#shown, 3, "the walk, the flight and the walk to the zeppelin")
    local px, py = OnMap(1417, HAMMERFALL[1] - 200, HAMMERFALL[2])
    local fx, fy = OnMap(1417, HAMMERFALL[1], HAMMERFALL[2])
    local walk = shown[1]
    check(math.abs(walk.from[1] - px * 1000) < 0.01 and math.abs(walk.from[2] + py * 600) < 0.01, "from the player")
    check(math.abs(walk.to[1] - fx * 1000) < 0.01 and math.abs(walk.to[2] + fy * 600) < 0.01, "to the flight master")
    eq(walk.thickness, 2, "four pixels on screen whatever the zoom")
    eq(walk.colour[1], 1, "in the walk's colour")
    local flight = shown[2]
    check(flight.to[1] < 0 or flight.to[1] > 1000 or flight.to[2] > 0 or flight.to[2] < -600,
        "a flight that leaves the zone runs off the map")
    eq(Count(world.mapPins), #legs, "the line is the trail: one marker where each leg ends, and no dot")
    check(not ns.Trail.State().dotted, "the state says so")

    -- The map moves to Ashenvale: the other continent's stretches show instead.
    WorldMapFrame.mapId = 1440
    ns.Trail.Layout()
    eq(#ShownLines(), sameContinent - 3, "the stretches in Kalimdor")
    eq(ns.Trail.State().line.shown, sameContinent - 3, "the state says how many")

    ns.Toggle()
    eq(#ShownLines(), 0, "closing the window takes the lines off")
    WorldMapFrame = nil
end)

test("on OpenMap's stitched map the line uses its coordinates and sits over its art", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    OpenWorldMap(1417)
    OpenMapAPI = {
        major = 1,
        IsStitched = function() return true end,
        ArtTopLevel = function() return 2400 end,
        -- Both continents on one canvas, as the stitched map has them.
        CanvasFromWorldPos = function(continent, x, y) return continent + x / 100000, y / 100000 end,
    }
    ns.Toggle()
    local lines = ShownLines()
    eq(#lines, ns.Trail.State().lines, "every stretch is placed, on either continent")
    check(math.abs(lines[1].to[1] - (HAMMERFALL[1] / 100000) * 1000) < 0.01, "by OpenMap's coordinates")
    eq(ns.Trail.State().line.level, 2401, "just over the stitched art")
    ns.Toggle()
    OpenMapAPI, WorldMapFrame = nil, nil
end)

test("on the stitched map a point OpenMap cannot place is not drawn", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    OpenWorldMap(1440)   -- the map underneath shows Kalimdor
    OpenMapAPI = {
        major = 1,
        IsStitched = function() return true end,
        CanvasFromWorldPos = function(continent, x, y)
            if continent == 0 then return x / 100000, y / 100000 end
        end,
    }
    ns.Toggle()
    eq(#ShownLines(), 3, "the Eastern Kingdoms' stretches only: the others are not placed by the map underneath")
    ns.Toggle()
    OpenMapAPI, WorldMapFrame = nil, nil
end)

test("the line is made once the world map exists, and follows the player", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    eq(ns.Trail.State().lines, 0, "no world map yet: no line")
    check(ns.Trail.State().drawn, "the dots are down")
    check(Count(world.mapPins) > 20, "dots meanwhile")

    OpenWorldMap(1417)
    Advance(2)
    check(ns.Trail.State().lines > 0, "the map is there now: the same route gets its lines")
    eq(Count(world.mapPins), #ns.state.plan.ready[1].target.legs, "and the dots are gone: the markers only")
    local walk = ShownLines()[1]
    local px = OnMap(1417, HAMMERFALL[1] - 200, HAMMERFALL[2])
    check(math.abs(walk.from[1] - px * 1000) < 0.01, "from the player")

    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 180, HAMMERFALL[2])
    Advance(2)
    ns.Trail.Layout()
    px = OnMap(1417, HAMMERFALL[1] - 180, HAMMERFALL[2])
    check(math.abs(ShownLines()[1].from[1] - px * 1000) < 0.01, "twenty yards on, the line starts at the player again")
    ns.Toggle()
    WorldMapFrame = nil
end)

test("a world map that cannot take a line gets the trip as dots", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    local canvas = OpenWorldMap(1417)
    function canvas:GetWidth() error("no canvas yet") end
    ns.Toggle()
    eq(#ShownLines(), 0, "no line")
    check(ns.Trail.State().line.error ~= nil, "the reason is kept for the snapshot")
    check(Count(world.mapPins) > 20, "the dots are there")
    check(ns.Trail.State().drawn, "and the trail counts as drawn")
    ns.Toggle()
    WorldMapFrame = nil
end)

test("a line that fails once the trip is drawn gives way to dots", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    local canvas = OpenWorldMap(1417)
    ns.Toggle()
    local legs = #ns.state.plan.ready[1].target.legs
    eq(Count(world.mapPins), legs, "a line, the markers, no dot")
    -- The map changes under the line and can no longer take it.
    function canvas:GetWidth() error("canvas gone") end
    WorldMapFrame.mapId = 1440
    ns.Trail.Layout()
    check(ns.Trail.State().line.error ~= nil, "the reason is kept")
    Advance(2)
    eq(#ShownLines(), 0, "no line any more")
    check(Count(world.mapPins) > 20, "the same trip is laid again, as dots")
    local pins = Count(world.mapPins)
    Advance(4)
    eq(Count(world.mapPins), pins, "once: not laid again at every refresh")
    -- Further along the same trip, the line is not tried a second time.
    local asked = 0
    function canvas:GetWidth() asked = asked + 1; error("canvas gone") end
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 100, HAMMERFALL[2])
    Advance(4)
    eq(asked, 0, "a hundred yards on, the failed line is left alone")
    check(Count(world.mapPins) > 20, "and the dots are still there")
    ns.Toggle()
    eq(Count(world.mapPins), 0, "closing takes them all off")
    WorldMapFrame = nil
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

---------------------------------------------------------------------------
-- The line on the minimap
---------------------------------------------------------------------------

-- A minimap 140 across showing `radius` yards round the player.
local function MinimapScene(radius, gx, gy)
    TravelScene(gx, gy)
    world.minimapSize, world.viewRadius = 140, radius
end

local function MiniLines()
    local out = {}
    for _, line in ipairs(lines) do
        if line.shown and line.owner.parent == Minimap then out[#out + 1] = line end
    end
    return out
end

-- Where HereBeDragons-Pins puts a point on the minimap: its drawMinimapPin,
-- line for line, in its own axes (x is the game's y, y the game's x), for a
-- minimap `half` wide from its centre. What the line is checked against.
local function PinOnMinimap(player, point, radius, facing, half)
    local xDist, yDist = player.y - point.y, player.x - point.x
    if facing then
        local dx, dy = xDist, yDist
        xDist = dx * math.cos(facing) - dy * math.sin(facing)
        yDist = dx * math.sin(facing) + dy * math.cos(facing)
    end
    local diffX, diffY = xDist / radius, yDist / radius
    return diffX * half, -diffY * half
end

local function Near(a, b) return type(a) == "number" and math.abs(a - b) < 0.01 end

local function Now(ns)
    local x, y, continent = ns.Geo.PlayerNow()
    return { x = x, y = y, continent = continent }
end

test("the walk is a yellow line on the minimap, from the player to the rim", function()
    MinimapScene(100, HAMMERFALL[1] - 200, HAMMERFALL[2])
    world.tomtom = false
    local ns = Load()
    ns.Toggle()
    local leg = ns.state.plan.ready[1].target.legs[1]
    eq(leg.kind, "walk", "the trip starts with a walk")
    local mini = MiniLines()
    eq(#mini, 1, "one line: the rest of the trip is out of sight")
    local px, py = PinOnMinimap(Now(ns), leg.to, 100, nil, 70)
    local far = math.sqrt(px * px + py * py)
    check(far > 70, "the flight master is beyond the minimap")
    check(Near(mini[1].to[1], px / far * 63) and Near(mini[1].to[2], py / far * 63),
        "it stops at the rim, toward where the pin library puts the flight master")
    check(Near(mini[1].from[1], px / far * 7) and Near(mini[1].from[2], py / far * 7),
        "and starts clear of the player's arrow")
    check(mini[1].to[2] > 60 and math.abs(mini[1].to[1]) < 1, "north of the player is up")
    eq(mini[1].colour[1], 1, "yellow")
    eq(mini[1].colour[2], 0.82, "as on the world map")
    for _, pin in pairs(world.minimapPins) do check(pin.edge, "and no dot on the minimap") end

    -- A hundred and fifty yards on: what was too far to matter now shows.
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 50, HAMMERFALL[2])
    ns.Trail.MiniLayout()
    eq(#MiniLines(), 2, "near the flight master, the flight's line is there too")
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 200, HAMMERFALL[2])
    ns.Trail.MiniLayout()
    eq(#MiniLines(), 1, "and gone again further back")
    local state = ns.Trail.State().miniLine
    eq(state.shown, 1, "the snapshot counts it")
    eq(state.source, "api", "and says where the view radius comes from")
    eq(state.radius, 100, "and what it is")
    check(Near(state.own[1], px / far * 63) and Near(state.own[2], py / far * 63),
        "and where the next stop's marker should be, to compare with where the library put it")
    ns.Toggle()
    eq(#MiniLines(), 0, "closing takes the line off")
end)

test("a stop within the minimap: the line ends on it and the next leg leaves from it", function()
    MinimapScene(100, HAMMERFALL[1] - 50, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local legs = ns.state.plan.ready[1].target.legs
    local mini = MiniLines()
    local px, py = PinOnMinimap(Now(ns), legs[1].to, 100, nil, 70)
    eq(ns.Nav.Mode(), "tomtom", "TomTom has the arrow")
    check(Near(mini[1].to[1], px) and Near(mini[1].to[2], py), "the walk ends where the pin library puts the flight master")
    eq(legs[2].kind, "fly", "then a flight")
    check(Near(mini[2].from[1], px) and Near(mini[2].from[2], py), "its line leaves from there")
    check(Near(math.sqrt(mini[2].to[1] ^ 2 + mini[2].to[2] ^ 2), 63), "and runs to the rim")
    eq(mini[2].colour[3], 1, "in the colour of a flight")

    -- Between two refreshes of the plan the player walks on: the line follows.
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 30, HAMMERFALL[2])
    ns.Trail.MiniLayout()
    mini = MiniLines()
    px, py = PinOnMinimap(Now(ns), legs[1].to, 100, nil, 70)
    check(Near(py, 21), "twenty yards on, the flight master is thirty yards ahead")
    check(Near(mini[1].to[1], px) and Near(mini[1].to[2], py), "and the line ends on it still")
    check(Near(mini[1].from[2], 7), "from the player still")
    ns.Toggle()
end)

test("a minimap that turns with the player: the line turns with it", function()
    MinimapScene(100, HAMMERFALL[1] - 50, HAMMERFALL[2] + 30)
    world.cvars.rotateMinimap = "1"
    world.facing = 2.1
    local ns = Load()
    ns.Toggle()
    local leg = ns.state.plan.ready[1].target.legs[1]
    local mini = MiniLines()
    local px, py = PinOnMinimap(Now(ns), leg.to, 100, 2.1, 70)
    local flat = { PinOnMinimap(Now(ns), leg.to, 100, nil, 70) }
    check(not Near(px, flat[1]), "turned: not where a fixed minimap has it")
    check(Near(mini[1].to[1], px) and Near(mini[1].to[2], py), "where the pin library puts the flight master")
    check(ns.Trail.State().miniLine.turned, "the snapshot says the minimap turns")

    world.facing = nil
    ns.Trail.MiniLayout()
    eq(#MiniLines(), 0, "facing unknown: no line rather than a wrong one")
    eq(ns.Trail.State().miniLine.why, "facing", "the snapshot says why")
    eq(ns.Trail.State().miniLine.error, nil, "and that is no error")
    world.facing = 0
    ns.Trail.MiniLayout()
    px, py = PinOnMinimap(Now(ns), leg.to, 100, 0, 70)
    check(Near(MiniLines()[1].to[1], px) and Near(MiniLines()[1].to[2], py), "known again: the line is back")
    ns.Toggle()
end)

test("a client without the view radius call: the zoom says how far the minimap shows", function()
    MinimapScene(nil, HAMMERFALL[1] - 50, HAMMERFALL[2])
    world.zoom = 5
    local ns = Load()
    ns.Toggle()
    local leg = ns.state.plan.ready[1].target.legs[1]
    local state = ns.Trail.State().miniLine
    eq(state.source, "outdoor", "outdoors")
    check(Near(state.radius, (133 + 1 / 3) / 2), "the outdoor view at the closest zoom")
    local _, py = PinOnMinimap(Now(ns), leg.to, (133 + 1 / 3) / 2, nil, 70)
    check(Near(MiniLines()[1].to[2], py), "the line is to that scale")

    world.indoors, world.zoom = true, 0
    ns.Trail.MiniLayout()
    state = ns.Trail.State().miniLine
    eq(state.source, "indoor", "indoors")
    eq(state.radius, 150, "the indoor view")
    ns.Toggle()
end)

test("a position the game keeps secret: no minimap line, and no error", function()
    MinimapScene(100, HAMMERFALL[1] - 50, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    check(#MiniLines() > 0, "a line")
    world.secretPosition = true
    ns.Trail.MiniLayout()
    eq(#MiniLines(), 0, "gone")
    eq(ns.Trail.State().miniLine.why, "position", "the snapshot says why")
    eq(ns.Trail.State().miniLine.error, nil, "no error")
    world.secretPosition = false
    ns.Trail.MiniLayout()
    check(#MiniLines() > 0, "back with the position")
    check(not ChatHas("error"), "nothing reached the player")
    ns.Toggle()
end)

test("a minimap that cannot take a line keeps its marker, and the world map keeps its line", function()
    MinimapScene(100, HAMMERFALL[1] - 200, HAMMERFALL[2])
    world.tomtom = false
    local ns = Load()
    OpenWorldMap(1417)
    local asked = 0
    function Minimap:GetWidth() asked = asked + 1; error("no minimap yet") end
    ns.Toggle()
    local legs = #ns.state.plan.ready[1].target.legs
    eq(#MiniLines(), 0, "no line on the minimap")
    check(ns.Trail.State().miniLine.error ~= nil, "the reason is kept for the snapshot")
    check(not ns.Trail.State().dotted, "the world map is not laid as dots for it")
    check(ns.Trail.State().lines > 0 and #ShownLines() > 0, "it keeps its line")
    eq(Count(world.mapPins), legs, "and has the markers only")
    local rim = 0
    for _, pin in pairs(world.minimapPins) do
        if pin.edge then rim = rim + 1 end
    end
    eq(rim, 1, "the next stop is still marked on the minimap")
    asked = 0
    world.player.x, world.player.y = OnMap(1417, HAMMERFALL[1] - 100, HAMMERFALL[2])
    Advance(4)
    ns.Trail.MiniLayout()
    eq(asked, 0, "further along the same trip it is not tried again")
    check(not ChatHas("error"), "and the player saw no error")
    ns.Toggle()
    WorldMapFrame = nil
end)

test("a minimap whose frame cannot be made: the world map still gets its line", function()
    MinimapScene(100, HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    OpenWorldMap(1417)
    function Minimap:GetWidth() error("not a minimap any more") end
    local make = CreateFrame
    CreateFrame = function(kind, name, parent)
        local frame = make(kind, name, parent)
        if parent == Minimap then function frame:SetAllPoints() error("no anchor") end end
        return frame
    end
    ns.Toggle()
    check(ns.Trail.State().miniLine.error ~= nil, "the reason is kept")
    check(ns.Trail.State().lines > 0 and #ShownLines() > 0, "the world map has its line")
    check(not ns.Trail.State().dotted, "and no dots")
    check(not ChatHas("error"), "and the player saw no error")
    ns.Toggle()
    WorldMapFrame = nil
end)

test("a path that comes back near itself: the minimap line does not jump ahead", function()
    MinimapScene(100, HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local at = Now(ns)
    local function Point(north, east) return { continent = at.continent, x = at.x + north, y = at.y - east } end
    -- North forty yards, a few yards east, and back south beside the way up.
    local path = { Point(0, 0), Point(40, 0), Point(40, 6), Point(-20, 6) }
    ns.Trail.Show({ { kind = "walk", from = path[1], to = path[4], path = path, pathId = 2, final = true } })
    world.player.x, world.player.y = OnMap(1417, at.x + 10, at.y - 4)
    ns.Trail.MiniLayout()
    local mini = MiniLines()
    local px, py = PinOnMinimap(Now(ns), path[2], 100, nil, 70)
    check(Near(mini[1].to[1], px) and Near(mini[1].to[2], py),
        "nearer to the way back than to the way up, the line still goes to the first turn")
    ns.Toggle()
end)

test("along a real path the minimap line starts at the turn ahead, not at one already passed", function()
    MinimapScene(100, HAMMERFALL[1] - 200, HAMMERFALL[2])
    local ns = Load()
    ns.Toggle()
    local at = Now(ns)
    local function Point(north, east) return { continent = at.continent, x = at.x + north, y = at.y - east } end
    local path = { Point(0, 0), Point(40, 0), Point(40, 40), Point(80, 40) }
    local legs = { { kind = "walk", from = path[1], to = path[4], path = path, pathId = 1, final = true } }
    ns.Trail.Show(legs)
    local mini = MiniLines()
    eq(#mini, 3, "one line per stretch of the path")
    check(Near(mini[1].to[1], 0) and Near(mini[1].to[2], 28), "the first to the turn ahead, forty yards north")
    check(Near(mini[2].to[1], 28) and Near(mini[2].to[2], 28), "then east")
    check(Near(mini[3].to[1], 28) and Near(mini[3].to[2], 56), "then north to the end")

    -- Five yards past the first turn, before the path is worked out again.
    world.player.x, world.player.y = OnMap(1417, at.x + 45, at.y)
    ns.Trail.MiniLayout()
    mini = MiniLines()
    eq(#mini, 2, "the stretch behind the player is gone")
    local px, py = PinOnMinimap(Now(ns), path[3], 100, nil, 70)
    check(Near(mini[1].to[1], px) and Near(mini[1].to[2], py), "the line goes from the player to the second turn")
    check(mini[1].to[1] > 0 and mini[1].from[1] > 0, "east: nothing points back at the turn behind")
    ns.Toggle()
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

test("the small window tells what to do now on a trip", function()
    TravelScene()
    local ns = Load()
    DropOffCharDB.compact = true
    ns.Toggle()
    eq(#ns.UI.Rows(), 1, "one row")
    check(HasLabel(ns, "Now: Fly to Undercity"), "the first step of the trip")
    check(HasLabel(ns, ns.L.ROUTE_ASSUMED), "and that its flights are not checked yet, as the whole list says")
    check(not HasLabel(ns, "  2. Go to the zeppelin: Undercity"), "not the others")
    check(Count(world.mapPins) > 0, "the trip is still drawn on the map")

    world.locale = "frFR"
    ns = Load()
    DropOffCharDB.compact = true
    ns.Toggle()
    check(HasLabel(ns, "Maintenant : Prends le vol pour Undercity"), "in French")
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

-- Zoram'gar Outpost and Ghost Walker Post: the trip that showed the problem.
local ZORAMGAR, GHOST_WALKER = { 3374.7, 997 }, { -1335, 1707 }
-- Where the mock world puts the pass from Stonetalon into Desolace: (54, 5)
-- on its Desolace map.
local STONETALON_PASS = { 452 + 0.05 * -4500, 4233 + 0.54 * -4500 }
-- The flight masters that character knew: no Shadowprey Village (38).
local KNOWN = { 61, 25, 58, 29, 56, 30, 22, 17, 77, 10, 20, 11, 80, 23, 13 }

-- A Horde character at Zoram'gar with a quest to hand in at Ghost Walker
-- Post in Desolace, knowing the flight masters in `known`.
local function DesolaceScene(known)
    TravelScene()
    local x, y = OnMap(1440, ZORAMGAR[1], ZORAMGAR[2])
    world.player = { map = 1440, x = x, y = y }
    local nx, ny = OnMap(1443, GHOST_WALKER[1], GHOST_WALKER[2])
    world.db.npcs[10] = { name = "Nataka Longhorn", spawns = { [405] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    local ns = Load()
    DropOffCharDB.flights, DropOffCharDB.flightsSeen = {}, { [0] = true, [1] = true }
    for _, id in ipairs(known) do DropOffCharDB.flights[id] = true end
    ns.Route.Reset()
    ns.Toggle()
    return ns, ns.state.plan.ready[1].target.legs
end

-- "fly>29 walk>1442|1443 walk>goal": each leg and where it ends.
local function Trip(legs)
    local out = {}
    for _, leg in ipairs(legs) do
        local to = leg.to
        out[#out + 1] = leg.kind .. ">" .. (to.node or to.pass and (to.zone .. "|" .. to.zone2)
            or to.dock and "dock" or "goal")
    end
    return table.concat(out, " ")
end

-- No walk may leave a zone except at a pass between the two.
local function WalksStayInZone(ns, legs, fromZone)
    local zone = fromZone
    for _, leg in ipairs(legs) do
        if leg.kind == "walk" then
            local to = leg.to
            if to.pass then
                check(to.zone == zone or to.zone2 == zone, "the pass is one out of zone " .. tostring(zone))
                zone = leg.enter
            elseif to.zone then
                eq(to.zone, zone, "a walk to a flight master or a dock stays in the zone")
            end
        else
            zone = leg.to.zone
        end
    end
    return zone
end

test("a walk changes zone only where the zones join", function()
    local ns, legs = DesolaceScene(KNOWN)
    local trip = Trip(legs)
    eq(trip, "fly>22 walk>1412|1443 walk>goal", "Thunder Bluff, the pass into Desolace, the hand-in")
    eq(WalksStayInZone(ns, legs, 1440), 1443, "the trip ends in Desolace")
    check(legs[#legs].final, "the last leg is the walk to the hand-in")
    eq(legs[2].enter, 1443, "the pass leads into Desolace")

    local labels = LabelTexts(ns)
    check(HasText(labels, "1. Fly to Thunder Bluff"), "step 1: the flight")
    check(HasText(labels, "2. Walk on into the next zone: Desolace"), "step 2: the pass, by the zone's name")
    check(HasText(labels, "3. Go to Nataka Longhorn"), "step 3: the hand-in")
end)

test("the trip follows the flight masters the character knows", function()
    local known = {}
    for _, id in ipairs(KNOWN) do
        if id ~= 22 then known[#known + 1] = id end
    end
    local ns, legs = DesolaceScene(known)
    eq(Trip(legs), "fly>29 walk>1442|1443 walk>goal", "no Thunder Bluff: Sun Rock Retreat and its pass")
    eq(WalksStayInZone(ns, legs, 1440), 1443, "into Desolace through Stonetalon")

    known[#known + 1] = 38
    ns, legs = DesolaceScene(known)
    eq(Trip(legs), "fly>38 walk>goal", "Shadowprey Village known: a flight into Desolace, then on foot")
end)

test("with no flight at all the walk goes from pass to pass", function()
    local ns, legs = DesolaceScene({})
    local trip = Trip(legs)
    check(not trip:find("fly", 1, true), "no flight: " .. trip)
    eq(WalksStayInZone(ns, legs, 1440), 1443, "every zone is left through a pass, down to Desolace")
    check(#legs >= 3, "several stretches: " .. trip)
    check(legs[#legs].final, "ending at the hand-in")
end)

test("standing at a pass, the walk to it is not a step", function()
    local ns = DesolaceScene(KNOWN)
    check(ns.Route.Begin(STONETALON_PASS[1] + 90, STONETALON_PASS[2], 1, 1442), "just north of the pass into Desolace")
    local _, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    eq(Trip(legs), "walk>goal", "one walk, from where the player is")
    check(legs[1].final, "to the hand-in")
end)

test("a zone the pass table does not know is not checked", function()
    local ns = DesolaceScene(KNOWN)
    check(ns.Route.Begin(-1197, 30, 1, 1456), "in Thunder Bluff")
    local _, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    eq(Trip(legs), "walk>1412|1443 walk>goal", "a city is its zone: out of Mulgore through its pass")
    _, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 99999)
    eq(Trip(legs), "walk>goal", "a hand-in on an unknown map: the straight line, as before")
    check(ns.Route.Begin(-1197, 30, 1, nil), "player's zone unknown")
    _, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    eq(Trip(legs), "walk>goal", "the straight line too")
end)

test("each leg's seconds add up to the trip's, also from beside a pass", function()
    local ns = DesolaceScene(KNOWN)
    local function sum(legs)
        local total = 0
        for _, leg in ipairs(legs) do total = total + leg.seconds end
        return total
    end
    check(ns.Route.Begin(ZORAMGAR[1], ZORAMGAR[2], 1, 1440), "from Zoram'gar")
    local seconds, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    check(math.abs(sum(legs) - seconds) < 1, "the whole trip: " .. sum(legs) .. " against " .. seconds)
    check(ns.Route.Begin(STONETALON_PASS[1] + 90, STONETALON_PASS[2], 1, 1442), "from 90 yards before the pass into Desolace")
    seconds, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    eq(#legs, 1, "one walk")
    check(math.abs(legs[1].seconds - seconds) < 1, "which carries the stretch to the pass too")
end)

test("a pass with no known zone beyond it is a plain step", function()
    local ns = DesolaceScene(KNOWN)
    ns.Route.Begin(-1197, 30, 1, nil)
    local legs = {
        { kind = "walk", from = {}, to = { pass = true, zone = 1412, zone2 = 1443 }, yards = 300, seconds = 60 },
        { kind = "walk", from = {}, to = {}, final = true, yards = 100, seconds = 20 },
    }
    eq(ns.Route.StepText(legs, 1, "x", true), "Walk on into the next zone", "no name: the plain wording")
    legs[1].enter = 1443
    eq(ns.Route.StepText(legs, 1, "x", true), "Walk on into the next zone: Desolace", "named when known")
end)

test("French pass step", function()
    TravelScene()
    world.locale = "frFR"
    local ns = Load()
    local legs = { { kind = "walk", from = {}, to = { pass = true, zone = 1412, zone2 = 1443 }, enter = 1443, yards = 300 } }
    eq(ns.Route.StepText(legs, 1, "x", true), "Rejoins à pied la zone suivante : Desolace", "the pass, in French")
end)

test("a map inside a zone counts as that zone", function()
    local ns = DesolaceScene(KNOWN)
    eq(ns.Route.Zone(1456), 1412, "a city is the zone around it")
    eq(ns.Route.Zone(1443), 1443, "a zone is itself")
    eq(ns.Route.Zone(1414), nil, "a continent is no zone")
    local real = C_Map.GetMapInfo
    C_Map.GetMapInfo = function(mapId)
        if mapId == 5001 then return { mapID = 5001, parentMapID = 1443 } end
        return real(mapId)
    end
    eq(ns.Route.Zone(5001), 1443, "a cave's map is its zone")
    eq(ns.Route.Zone(5002), nil, "an unknown map is not")
end)

test("every dock has the zone it stands in", function()
    local ns = DesolaceScene(KNOWN)
    -- Where each dock of the data is: the route's name says it.
    local expected = {
        ["1:-1005.6:-3841.6"] = 1413, ["0:-14277.7:582.9"] = 1434, ["0:-12464:231.6"] = 1434,
        ["1:1360.9:-4631.3"] = 1411, ["0:-3905.2:-585.8"] = 1437, ["1:-4016.4:-4740.6"] = 1445,
        ["1:8532:1023.7"] = 1438, ["1:6594.4:759.8"] = 1439, ["0:-12406.9:211.8"] = 1434,
        ["0:2062.6:235.3"] = 1420, ["1:1318.1:-4658"] = 1411, ["0:2062.4:293"] = 1420,
        ["1:-4197.3:3286.6"] = 1444, ["1:-4347.8:2444.4"] = 1444, ["0:-3709.5:-575.1"] = 1437,
        ["0:-1102.6:-554.7"] = 1424, ["1:6406.2:823.1"] = 1439, ["1:-6932.6:-4950.8"] = 1446,
        ["0:544.8:424.2"] = 1416, ["1:-802:366.5"] = 1412, ["1:6548.3:942.2"] = 1439,
        ["0:-8654.5:1344.4"] = 1429,
        -- Powderfuse Port (Riverglades) and Zephras Isle: zones the table does not know.
        ["0:-8232.3:-5800.8"] = false, ["2991:1848.3:569.1"] = false, ["2991:1952.5:1019.1"] = false,
    }
    -- Standing on a dock, in its zone, the trip to the far dock is the ride:
    -- a dock given the wrong zone could not be walked onto, or off.
    local rode = {}
    for _, faction in ipairs({ "Horde", "Alliance" }) do
        world.faction = faction
        ns.Route.Reset()
        for index, ride in ipairs(ns.TravelData.transports) do
            local from = ride[4] .. ":" .. ride[5] .. ":" .. ride[6]
            local to = ride[8] .. ":" .. ride[9] .. ":" .. ride[10]
            check(expected[from] ~= nil and expected[to] ~= nil, "both docks of " .. ride[2] .. " are listed in this test")
            if ns.Route.Begin(ride[5], ride[6], ride[4], expected[from] or nil) then
                local _, legs = ns.Route.To(ride[9], ride[10], ride[8], expected[to] or 99999)
                local trip = legs and Trip(legs)
                if trip == ride[1] .. ">dock walk>goal" or (expected[from] == expected[to] and trip == "walk>goal") then
                    rode[index] = true
                end
            end
        end
    end
    for index, ride in ipairs(ns.TravelData.transports) do
        check(rode[index], ride[2] .. " (" .. index .. ") is taken dock to dock by one faction at least")
    end
    eq(ns.Route.Zone(1416), 1416, "the Alterac Mountains are a zone")
end)

test("a flight master in an unknown zone is not walked to from a known one", function()
    local ns = DesolaceScene(KNOWN)
    DropOffCharDB.flightsSeen = {}   -- every flight master counts as known
    ns.Route.Reset()
    local hyjal
    for id, node in pairs(ns.TravelData.nodes) do
        if node[1]:find("Mount Hyjal", 1, true) and node[5] ~= "A" then hyjal = node end
    end
    check(hyjal ~= nil, "the data has a Hyjal flight master a Horde character can use")
    check(ns.Route.Begin(hyjal[3] + 300, hyjal[4], 1, 1448), "in Felwood, 300 yards from it")
    local _, legs = ns.Route.To(hyjal[3], hyjal[4] + 50, 1, 99999)
    eq(Trip(legs), "walk>goal", "a hand-in there is still walked to directly")
    check(ns.Route.Begin(hyjal[3] + 300, hyjal[4], 1, nil), "player's zone unknown too")
    _, legs = ns.Route.To(GHOST_WALKER[1], GHOST_WALKER[2], 1, 1443)
    check(legs ~= nil and legs[1].kind == "walk" and legs[1].to.node ~= nil, "from an unknown zone the walk to it is allowed")
end)

test("an island zone is reached by boat only", function()
    local ns = DesolaceScene(KNOWN)
    check(ns.Route.Begin(6341, 557, 1, 1439), "a Horde character in Auberdine")
    check(ns.Route.To(9900, 900, 1, 1438) == nil, "no way to Teldrassil without the Alliance's boat")
end)

test("every flight master and pass of the data has a place in the zone table", function()
    world = NewWorld()
    world.travel = true
    local ns = Load()
    local passes = ns.TravelPasses
    for id, node in pairs(ns.TravelData.nodes) do
        local zone = passes.names[node[1]:match(",%s*(.+)$") or node[1]]
        local name = node[1]
        if not (name:find("Riverglades", 1, true) or name:find("Mount Hyjal", 1, true)) then
            check(zone ~= nil, "zone of flight master " .. id .. " (" .. name .. ")")
            if zone then eq(passes.zones[zone], node[2], "continent of " .. name) end
        end
    end
    for index, pass in ipairs(passes.passes) do
        check(passes.zones[pass[1]] ~= nil and passes.zones[pass[1]] == passes.zones[pass[2]],
            "pass " .. index .. " joins two zones of one continent")
        check(pass[1] ~= pass[2], "pass " .. index .. " joins two different zones")
        if pass[3] then
            check(pass[3] == pass[1] or pass[3] == pass[2], "pass " .. index .. " is given on the map of one of its zones")
            check(pass[4] > 0 and pass[4] < 100 and pass[5] > 0 and pass[5] < 100, "pass " .. index .. " is on that map, in percent")
        else
            check(type(pass[4]) == "number" and type(pass[5]) == "number", "pass " .. index .. " is in world yards")
        end
    end
    for city, zone in pairs(passes.cities) do
        check(passes.zones[zone] ~= nil and passes.zones[city] == nil, "city " .. city .. " stands in a zone")
    end
end)

test("every zone can be walked to from the others of its continent, but the island", function()
    world = NewWorld()
    world.travel = true
    local passes = Load().TravelPasses
    local joined = {}
    for _, pass in ipairs(passes.passes) do
        joined[pass[1]] = joined[pass[1]] or {}
        joined[pass[2]] = joined[pass[2]] or {}
        joined[pass[1]][pass[2]], joined[pass[2]][pass[1]] = true, true
    end
    for continent, start in pairs({ [0] = 1429, [1] = 1411 }) do
        local reached, queue = { [start] = true }, { start }
        while #queue > 0 do
            local zone = table.remove(queue)
            for other in pairs(joined[zone] or {}) do
                if not reached[other] then
                    reached[other] = true
                    queue[#queue + 1] = other
                end
            end
        end
        for zone, on in pairs(passes.zones) do
            if on == continent and zone ~= 1438 then check(reached[zone], "zone " .. zone .. " is reached on foot") end
        end
    end
    check(joined[1438] == nil, "Teldrassil has no pass")
end)

test("a pass the game cannot place yet is left out, then placed", function()
    TravelScene()
    -- Ashenvale's map is not ready: none of its passes can be placed.
    world.unplaced[1440] = true
    local x, y = OnMap(1440, ZORAMGAR[1], ZORAMGAR[2])
    world.player = { map = 1440, x = x, y = y }
    local nx, ny = OnMap(1443, GHOST_WALKER[1], GHOST_WALKER[2])
    world.db.npcs[10] = { name = "Nataka Longhorn", spawns = { [405] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    local ns = Load()
    DropOffCharDB.flights, DropOffCharDB.flightsSeen = {}, { [0] = true, [1] = true }
    ns.Route.Reset()
    ns.Toggle()
    local target = ns.state.plan.ready[1].target
    check(target.legs == nil, "no way out of Ashenvale: no trip, and no straight line across the zones")
    -- What the mock world can place: a pass in world yards, or on a zone map
    -- it lays out over the real world. Its made-up maps are on a continent
    -- of their own, the other zones have no map at all.
    local onAshenvale, placeable, misplaced = 0, 0, 0
    for _, pass in ipairs(ns.TravelPasses.passes) do
        local map = pass[3] and MAPS[pass[3]]
        if pass[3] == 1440 then onAshenvale = onAshenvale + 1 end
        if not pass[3] or (map and not map.fake) then placeable = placeable + 1 end
        if map and map.fake then misplaced = misplaced + 1 end
    end
    check(onAshenvale > 0 and misplaced > 0, "the table has passes of both kinds")
    local before = ns.Route.PassState()
    eq(before.placed, placeable - onAshenvale, "Ashenvale's passes are not placed")
    eq(before.misplaced, misplaced, "the ones on another continent are counted apart")
    eq(before.waiting, before.total - before.placed - before.misplaced, "the rest is waiting")

    world.unplaced[1440] = nil
    Advance(5)
    check(ns.state.plan.ready[1].target.legs == nil, "not asked again at once")
    Advance(8)
    local legs = ns.state.plan.ready[1].target.legs
    check(legs ~= nil, "placed on a later try")
    eq(WalksStayInZone(ns, legs, 1440), 1443, "and the walk leaves Ashenvale through them")
    eq(ns.Route.PassState().placed, placeable, "Ashenvale's passes are placed now")
    eq(ns.Route.PassState().tries, 1, "on the first try: 10 seconds after the build")
    Advance(15)
    eq(ns.Route.PassState().tries, 1, "the next try waits twice as long")
    Advance(10)
    eq(ns.Route.PassState().tries, 2, "then comes")

    -- The mock places Durotar, the Barrens and Elwynn on a continent of their
    -- own: a pass the game places on another continent than its zones is left out.
    local _, _, found = ns.Geo.World(1411, 0.345, 0.425)
    eq(found, 9, "the bridge out of Durotar is placed, on the wrong continent")
    SlashCmdList.DROPOFF("debug")
    eq(DropOffDB.snapshot.passes.total, #ns.TravelPasses.passes, "the snapshot counts the passes")
    eq(DropOffDB.snapshot.passes.placed, placeable, "the ones placed")
    eq(DropOffDB.snapshot.passes.misplaced, misplaced, "the ones on the wrong continent")
    check(DropOffDB.snapshot.passes.tries >= 2, "and the tries")
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
-- Real walks: the embedded walking router
---------------------------------------------------------------------------

-- A router with the calls Walk.lua makes of the embedded one (ns.Path): it
-- keeps what it was asked and answers when the test says so. Its maps of a
-- continent are in memory once their addon was loaded (C_AddOns.LoadAddOn).
--   options.throws: every search raises an error
local function Router(options)
    options = options or {}
    local router = { asks = {}, cancels = 0, clears = 0, maps = {} }
    function router.Find(map, from, to, callback, ...)
        if options.throws then error("router exploded") end
        local job = { map = map, from = from, to = to, callback = callback, extra = select("#", ...) }
        router.asks[#router.asks + 1] = job
        return job
    end
    function router.Cancel(job)
        job.cancelled = true
        router.cancels = router.cancels + 1
    end
    function router.HasData(map) return router.maps[map] == true end
    function router.ClearCaches() router.clears = router.clears + 1 end
    -- Answers a search (the last one asked): a path from its start through
    -- `turns` ({ { x, y }, ... }) to its goal, or the reason there is none.
    -- A cancelled search is never answered, unless `late` says so.
    function router.Answer(turns, job, late)
        job = job or router.asks[#router.asks]
        if job.cancelled and not late then return end
        if type(turns) == "string" then
            job.callback(nil, turns, job)
            return
        end
        local points = { { map = job.map, x = job.from.x, y = job.from.y, z = 152 } }
        for _, turn in ipairs(turns) do points[#points + 1] = { map = job.map, x = turn[1], y = turn[2], z = 100 } end
        points[#points + 1] = { map = job.map, x = job.to.x, y = job.to.y }
        points.wet = 0
        local yards = 0
        for index = 2, #points do
            yards = yards + math.sqrt((points[index].x - points[index - 1].x) ^ 2 + (points[index].y - points[index - 1].y) ^ 2)
        end
        job.callback(points, yards * 1.15, job)
    end
    return router
end

-- The walk that showed the problem: from the Thunder Bluff flight master to
-- Ghost Walker Post, round the mountains. North out of the city, west over
-- the plateau, then south.
local THUNDER_BLUFF = { -1197.2, 29.7 }
local ROUND = { { -400, 40 }, { -620, 400 }, { -680, 750 }, { -1050, 1250 } }
-- The west lift of Thunder Bluff (Lifts.lua), and a way on from its foot.
local WEST_LIFT = { x = -1297.31, y = 187.505, top = 130.082, bottom = 68.711 }
local FROM_LIFT = { { -1400, 800 } }

local function PathYards(from, turns, to)
    local yards, at = 0, from
    for _, turn in ipairs(turns) do
        yards = yards + math.sqrt((turn[1] - at[1]) ^ 2 + (turn[2] - at[2]) ^ 2)
        at = turn
    end
    return yards + math.sqrt((to[1] - at[1]) ^ 2 + (to[2] - at[2]) ^ 2)
end

-- A Horde character at the Thunder Bluff flight master, a quest to hand in
-- at Ghost Walker Post, the window open. `router`: a router of the test's
-- own, with the map addons installed; nil: the embedded router, and no map
-- addon unless `before` puts one.
local function PlateauScene(router, before)
    TravelScene()
    local x, y = OnMap(1412, THUNDER_BLUFF[1], THUNDER_BLUFF[2])
    world.player = { map = 1412, x = x, y = y }
    local nx, ny = OnMap(1443, GHOST_WALKER[1], GHOST_WALKER[2])
    world.db.npcs[10] = { name = "Nataka Longhorn", spawns = { [405] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    world.engine = router
    if router then
        for name in pairs(MAP_ADDONS) do world.mapAddons[name] = true end
    end
    if before then before() end
    local ns = Load()
    DropOffCharDB.flights, DropOffCharDB.flightsSeen = {}, { [0] = true, [1] = true }
    for _, id in ipairs(KNOWN) do DropOffCharDB.flights[id] = true end
    ns.Route.Reset()
    ns.Toggle()
    return ns
end

local function Target(ns)
    return ns.state.plan.ready[1].target
end

local function MovePlayer(gx, gy)
    world.player.x, world.player.y = OnMap(world.player.map, gx, gy)
end

-- Yards from a point to the nearest stretch of a path.
local function OffPath(points, x, y)
    local least = math.huge
    for index = 1, #points - 1 do
        local a, b = points[index], points[index + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local t = math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / (dx * dx + dy * dy)))
        least = math.min(least, math.sqrt((a.x + dx * t - x) ^ 2 + (a.y + dy * t - y) ^ 2))
    end
    return least
end

local function Near(a, b, within)
    return math.abs(a - b) <= (within or 0.01)
end

test("without the walking maps a walk is a straight line and says so", function()
    local ns = PlateauScene(nil)
    local target = Target(ns)
    eq(Trip(target.legs), "walk>1412|1443 walk>goal", "to the pass, then to the hand-in")
    local labels = LabelTexts(ns)
    check(HasText(labels, "1. Walk on into the next zone: Desolace · " .. math.floor(target.legs[1].yards + 0.5) .. " yd"),
        "the walk to the pass, in straight yards")
    check(HasLabel(ns, "  Walking distances are as the crow flies."), "and a line of its own says so")
    DropOffFrame.size:Click()
    check(HasLabel(ns, "Walking distances are as the crow flies."), "in the small window too")
    DropOffFrame.size:Click()
    eq(target.walk, nil, "no real yards")
    Advance(30)
    eq(#world.loadCalls, 1, "the maps were asked for once, not at every tick")
    eq(world.loadCalls[1], "DropOff_Paths_Kalimdor", "those of the continent the walk is on")
    SlashCmdList.DROPOFF("debug")
    local walk = DropOffDB.snapshot.walk
    eq(walk.router, true, "the snapshot says the router is there")
    eq(walk.asked, 0, "that nothing was asked")
    eq(walk.held, "nodata", "for want of maps")
    eq(walk.maps[1].addon, "DropOff_Paths_Kalimdor", "which addon holds them")
    eq(walk.maps[1].inMemory, false, "that they are not in memory")
    eq(walk.maps[1].reason, "MISSING", "and why: the game does not know the addon")
    eq(walk.maps[1].why, "MISSING", "as the game's addon list says too")
    eq(walk.maps[0].tries, nil, "the other continent's were never asked for")
    eq(walk.player.map, 1412, "and the map the player is on")
    check(not ChatHas("error"), "no error")
    eq(#world.errors, 0, "none for the game's handler either")
end)

test("a plain walk says how far in a straight line, in both sizes", function()
    TravelScene()
    local nx, ny = OnMap(1417, HAMMERFALL[1] - 150, HAMMERFALL[2])
    world.db.npcs[10].spawns = { [45] = { { nx * 100, ny * 100 } } }
    local ns = Load()
    ns.Toggle()
    check(HasLabel(ns, "  Go to Karang Amakkar · 150 yd"), "one line under the hand-in")
    check(HasLabel(ns, "  Walking distances are as the crow flies."), "and that it is a straight line")
    DropOffFrame.size:Click()
    check(HasLabel(ns, "Now: Go to Karang Amakkar · 150 yd"), "the same in the small window")
    check(HasLabel(ns, "Walking distances are as the crow flies."), "with the straight line said")
    for _, line in ipairs(ns.UI.Lines(ns.state.plan, true)) do
        if line.kind == "label" then check(#line.text <= 45, "short enough not to be cut off: " .. line.text) end
    end
end)

test("with its maps loaded the walk follows the router's path", function()
    local router = Router()
    local ns = PlateauScene(router)
    eq(#world.loadCalls, 1, "the maps are loaded at the first walk")
    eq(world.loadCalls[1], "DropOff_Paths_Kalimdor", "those of Kalimdor only")
    eq(#router.asks, 1, "one search")
    local ask = router.asks[1]
    eq(ask.map, 1, "on Kalimdor")
    check(Near(ask.from.x, THUNDER_BLUFF[1]) and Near(ask.from.y, THUNDER_BLUFF[2]), "from the player")
    check(Near(ask.to.x, GHOST_WALKER[1], 0.5) and Near(ask.to.y, GHOST_WALKER[2], 0.5),
        "to the hand-in itself: the pass is not a place to go through")
    eq(ask.from.z, nil, "no height: the game gives none")
    eq(ask.extra, 0, "nothing after the callback: a fifth argument would walk on water")
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "still straight lines while the router searches")
    check(HasText(LabelTexts(ns), "as the crow flies"), "and said so")

    router.Answer(ROUND)
    Advance(0.1)
    local target = Target(ns)
    local yards = PathYards(THUNDER_BLUFF, ROUND, GHOST_WALKER)
    eq(Trip(target.legs), "walk>goal", "one walk: the pass is not a step any more")
    local leg = target.legs[1]
    check(leg.real and leg.final, "a real walk, to the hand-in")
    check(math.abs(leg.yards - yards) < 1, "its yards are the path's: " .. leg.yards .. " against " .. yards)
    check(yards > 2500, "far more than the straight line")
    check(math.abs(target.eta - yards / 7) < 0.5, "its time is the path's, with no guess for the roads")
    eq(#leg.path, #ROUND + 2, "the player, each turn and the hand-in")
    eq(leg.lift, nil, "with no lift on the way")

    local label = "Go to Nataka Longhorn · " .. math.floor(yards + 0.5) .. " yd"
    check(HasLabel(ns, "  " .. label), "the step says the real yards")
    check(not HasText(LabelTexts(ns), "as the crow flies"), "and no straight line is spoken of")
    check(not HasText(LabelTexts(ns), "lift"), "nor a lift")
    eq(ns.UI.Rows()[1].data.right, math.floor(yards + 0.5) .. " yd", "the row too")
    DropOffFrame.size:Click()
    check(HasLabel(ns, "Now: " .. label), "and the small window")
    DropOffFrame.size:Click()

    Advance(10)
    eq(#router.asks, 1, "standing still, nothing is asked again")
    eq(router.cancels, 0, "and nothing was cancelled")
    eq(#world.loadCalls, 1, "and the maps are not loaded twice")
end)

test("a trip gone through twice keeps its search, and a slow answer is not asked again at once", function()
    local router = Router()
    local ns = PlateauScene(router)
    ns.Walk.Use(Target(ns))
    ns.Walk.Use(Target(ns))
    eq(router.cancels, 0, "the search under way is not given up")
    eq(#router.asks, 1, "nor asked twice")

    -- The answer takes eight seconds, the player has walked on meanwhile.
    Advance(8)
    MovePlayer(THUNDER_BLUFF[1], THUNDER_BLUFF[2] + 60)
    router.Answer(ROUND)
    Advance(2)
    eq(#router.asks, 1, "off the new path already, but it has only just come")
    check(Target(ns).legs[1].real, "it is used meanwhile")
    Advance(4)
    eq(#router.asks, 2, "then asked again from where the player is")
end)

test("the path is drawn on the maps, turn by turn", function()
    local router = Router()
    local ns = PlateauScene(router)
    OpenWorldMap(1414)
    router.Answer(ROUND)
    Advance(0.1)
    eq(ns.Trail.State().lines, #ROUND + 1, "one line from each turn to the next")
    eq(#ShownLines(), #ROUND + 1, "all on the map of Kalimdor")
    eq(Count(world.mapPins), #Target(ns).legs, "the line is the trail: the marker of the hand-in, no dot")
    for _, pin in pairs(world.minimapPins) do check(pin.edge, "no dot on the minimap") end
    ns.Toggle()
    eq(#ShownLines(), 0, "closing the window takes the lines off")
    WorldMapFrame = nil
end)

test("the arrow goes from turn to turn, the hand-in keeps its pin", function()
    local router = Router()
    local ns = PlateauScene(router)
    eq(world.arrow[1], 1412, "before the answer the arrow is on the pass")
    router.Answer(ROUND)
    Advance(0.1)
    local tx, ty = OnMap(1412, ROUND[1][1], ROUND[1][2])
    eq(world.arrow[1], 1412, "the first turn is in Mulgore")
    check(math.abs(world.arrow[2] - tx) < 0.0001 and math.abs(world.arrow[3] - ty) < 0.0001, "the arrow is on it")
    eq(world.arrow.title, "Go to Nataka Longhorn", "and says where the walk ends")
    local handIn
    for uid in pairs(world.waypoints) do
        if uid ~= world.arrow then handIn = uid end
    end
    check(handIn and handIn[1] == 1443 and not handIn.opts.crazy, "the hand-in has its own pin in Desolace")

    local adds = world.waypointAdds
    MovePlayer(-900, 33.6)
    Advance(2)
    eq(world.waypointAdds, adds, "walking toward the turn, the arrow is not placed again")
    local walked = Target(ns).legs[1].yards
    check(math.abs(walked - (PathYards(THUNDER_BLUFF, ROUND, GHOST_WALKER) - 297.2)) < 1, "the yards left go down: " .. walked)

    MovePlayer(-450, 39.3)
    Advance(2)
    tx, ty = OnMap(1412, ROUND[2][1], ROUND[2][2])
    check(math.abs(world.arrow[2] - tx) < 0.0001 and math.abs(world.arrow[3] - ty) < 0.0001,
        "fifty yards from the turn, the arrow is on the next one")
    eq(#Target(ns).legs[1].path, #ROUND + 2, "the turn is still ahead")
    eq(#router.asks, 1, "on the path, nothing is asked again")
end)

test("a player who leaves the path gets a new one, not at every step", function()
    local router = Router()
    local ns = PlateauScene(router)
    router.Answer(ROUND)
    Advance(0.1)
    MovePlayer(-900, 53.6)
    Advance(2)
    eq(#router.asks, 1, "twenty yards off: the path still holds")
    MovePlayer(-900, 83.6)
    Advance(2)
    eq(#router.asks, 1, "fifty yards off, but the last search was a moment ago")
    check(Target(ns).legs[1].real, "the old path is still drawn meanwhile")
    Advance(4)
    eq(#router.asks, 2, "then a new search, from where the player is")
    check(math.abs(router.asks[2].from.y - 83.6) < 0.01, "from there")
    router.Answer({ { -400, 60 } })
    Advance(0.1)
    eq(#Target(ns).legs[1].path, 3, "the new path replaces the old one")
    Advance(20)
    eq(#router.asks, 2, "and holds")
end)

test("no way on foot: the straight line stays, and the router is not asked in a loop", function()
    local router = Router()
    local ns = PlateauScene(router)
    router.Answer("unreachable")
    Advance(0.1)
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "the trip is as the planner made it")
    check(HasText(LabelTexts(ns), "as the crow flies"), "in straight lines")
    Advance(60)
    eq(#router.asks, 1, "standing still, the same question is not asked again")
    MovePlayer(THUNDER_BLUFF[1] + 40, THUNDER_BLUFF[2])
    Advance(2)
    eq(#router.asks, 2, "from further on it is")
    SlashCmdList.DROPOFF("debug")
    local walk = DropOffDB.snapshot.walk
    eq(walk.router, true, "the snapshot says the router is there")
    eq(walk.answers[1].reason, "unreachable", "what it answered")
    eq(walk.answers[1].direct, "unreachable", "straight there")
    check(walk.answers[1].straight > 1600, "over how many straight yards")
    check(walk.waiting ~= nil, "and that a search is under way")
end)

test("the snapshot records the router's answer", function()
    local router = Router()
    local ns = PlateauScene(router)
    Advance(3)
    router.Answer(ROUND)
    Advance(0.1)
    SlashCmdList.DROPOFF("debug")
    local walk = DropOffDB.snapshot.walk
    eq(walk.asked, 1, "one walk asked for")
    eq(walk.answered, 1, "one answer")
    eq(walk.waiting, nil, "none under way")
    local answer = walk.answers[1]
    eq(answer.reason, "ok", "a path")
    eq(answer.drawn, math.floor(PathYards(THUNDER_BLUFF, ROUND, GHOST_WALKER) + 0.5), "its yards")
    eq(answer.direct, answer.drawn, "it is the way straight there")
    eq(answer.lift, nil, "with no lift")
    eq(answer.searches, 1, "found in one search")
    eq(answer.points, #ROUND + 2, "its points")
    check(answer.straight < answer.drawn, "the straight line beside it")
    check(answer.waited >= 3, "how long it took: " .. answer.waited)
    eq(walk.maps[1].inMemory, true, "Kalimdor's maps are in memory")
    eq(walk.maps[1].loaded, true, "loaded by DropOff")
    eq(walk.maps[1].tries, 1, "at the first try")
    eq(walk.maps[1].loadable, true, "as the game's addon list allowed")
    eq(walk.maps[0].inMemory, false, "the Eastern Kingdoms' are not")
    eq(walk.maps[0].tries, nil, "and were not asked for")
    eq(walk.maps[2991].addon, "DropOff_Paths_Zephras", "Zephras Isle has an addon of its own")
    eq(#router.asks, 1, "taking the snapshot asks for nothing")
    eq(router.cancels, 0, "and cancels nothing")
    eq(#world.loadCalls, 1, "and loads nothing")
    check(ns.Walk.State().answers ~= walk.answers, "the snapshot holds a copy")
end)

test("nothing is asked in a fight", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.combat = true end)
    eq(#router.asks, 0, "no search in combat")
    eq(#world.loadCalls, 0, "and no maps are read: that takes a moment")
    eq(ns.Walk.State().held, "combat", "the reason is kept")
    world.combat = false
    Advance(2)
    eq(#world.loadCalls, 1, "out of combat the maps are loaded")
    eq(#router.asks, 1, "and the walk is asked for")
end)

test("with the maps in memory, a new walk still waits for the end of a fight", function()
    local router = Router()
    local ns = PlateauScene(router)
    router.Answer(ROUND)
    Advance(6)
    eq(#router.asks, 1, "one search so far")
    world.combat = true
    MovePlayer(-900, 133.6)
    Advance(10)
    eq(#router.asks, 1, "off the path in a fight: nothing is asked")
    eq(ns.Walk.State().held, "combat", "the reason is kept")
    check(Target(ns).legs[1].real, "the path there is still drawn")
    world.combat = false
    Advance(2)
    eq(#router.asks, 2, "after the fight the new path is asked for")
    eq(#world.loadCalls, 1, "with the maps already there")
end)

test("closing the window gives the search up", function()
    local router = Router()
    local ns = PlateauScene(router)
    ns.Toggle()
    eq(router.cancels, 1, "the search is cancelled")
    eq(router.clears, 1, "and the router lets go of what it decoded")
    router.Answer(ROUND, nil, true)
    ns.Toggle()
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "an answer that comes all the same is not used")
    eq(#router.asks, 2, "the window open again: asked again")
end)

test("a walk on the other continent is searched too, with that continent's maps", function()
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local router = Router()
    world.engine = router
    for name in pairs(MAP_ADDONS) do world.mapAddons[name] = true end
    local ns = Load()
    ns.Toggle()
    eq(#router.asks, 1, "the walk to the flight master, where the player is")
    eq(router.asks[1].map, 0, "in the Eastern Kingdoms")
    eq(#world.loadCalls, 1, "with the maps of the Eastern Kingdoms only")
    router.Answer({})
    Advance(3)
    eq(#router.asks, 2, "then the walk to the zeppelin, one search at a time")
    eq(router.asks[2].map, 0, "there too")
    eq(router.asks[2].from.z, nil, "from a flight master: no height when there is one floor")
    router.Answer({})
    Advance(3)
    eq(#router.asks, 3, "then the walk beyond the crossing")
    eq(router.asks[3].map, 1, "on Kalimdor")
    eq(world.loadCalls[2], "DropOff_Paths_Kalimdor", "whose maps are loaded for it")
    eq(ns.Walk.State().held, nil, "nothing is held back")
    router.Answer({})
    Advance(3)
    eq(#router.asks, 4, "and the last walk, from the flight master to the hand-in")
    router.Answer({})
    Advance(3)
    eq(#world.loadCalls, 2, "each continent's maps were loaded once")
    local legs = Target(ns).legs
    eq(Trip(legs), "walk>17 fly>11 walk>dock zeppelin>dock walk>23 fly>58 walk>goal", "the trip is the planner's")
    check(legs[1].real, "the first walk is real")
    check(legs[#legs].real, "and the last one, in Ashenvale")
    check(not HasText(LabelTexts(ns), "as the crow flies"), "no straight line is left")
end)

test("maps that do not load are not asked for at every tick, and the walk stays straight", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.mapAddons.DropOff_Paths_Kalimdor = "DISABLED" end)
    Advance(30)
    eq(#router.asks, 0, "no search: the router is never called without maps")
    eq(#world.loadCalls, 1, "the maps were asked for once")
    eq(ns.Walk.State().held, "nodata", "the reason is kept")
    check(HasText(LabelTexts(ns), "as the crow flies"), "straight lines")
    SlashCmdList.DROPOFF("debug")
    local map = DropOffDB.snapshot.walk.maps[1]
    eq(map.reason, "DISABLED", "the snapshot says why they did not load")
    eq(map.loadable, false, "and that the game would not load them")
    eq(map.loaded, false, "so they are not")
    -- Enabled in the addon list meanwhile.
    world.mapAddons.DropOff_Paths_Kalimdor = true
    Advance(40)
    eq(#world.loadCalls, 2, "a minute on they are asked for again")
    eq(#router.asks, 1, "and the walk is searched")
end)

test("a broken router never breaks the trip", function()
    local ns = PlateauScene(Router({ throws = true }))
    Advance(5)
    check(not ChatHas("error"), "no error shown")
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "the trip is the planner's")
    eq(ns.Walk.State().answers[1].reason:sub(1, 6), "error:", "the snapshot keeps why")
    eq(ns.Walk.State().asked, 1, "and it is not asked at every tick")

    ns = PlateauScene({ Find = "not a function", Cancel = function() end })
    eq(ns.Walk.State().router, false, "a table that is not a router is not one")

    local router = Router()
    ns = PlateauScene(router)
    router.asks[1].callback({ "junk", { x = "a" } }, 12, nil)
    Advance(0.1)
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "points that are no path are not drawn")
    eq(ns.Walk.State().answers[1].reason, "empty", "and said so")

    router = Router()
    ns = PlateauScene(router, function() world.lifts = true end)
    router.asks[1].callback(nil, "error", nil)
    Advance(0.1)
    eq(#router.asks, 1, "after an error of the router no lift is tried")
    eq(ns.Walk.State().answers[1].reason, "error", "and the snapshot says so")
end)

test("after an update and a /reload the new file is not read: straight lines, no error", function()
    local ns = PlateauScene(Router(), function() world.unread = { ["Walk.lua"] = true } end)
    eq(ns.Walk, nil, "the game has not read Walk.lua")
    Advance(5)
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "the trip is the planner's")
    check(HasLabel(ns, "  Walking distances are as the crow flies."), "in straight lines, said so")
    eq(#LiveWaypoints(), 2, "the arrow and the hand-in's pin are there")
    SlashCmdList.DROPOFF("debug")
    eq(DropOffDB.snapshot.walk, nil, "the snapshot has no walk")
    check(DropOffDB.snapshot.passes ~= nil, "and everything else")
    ns.Toggle()
    eq(#LiveWaypoints(), 0, "closing works")
    check(not ChatHas("error"), "no error anywhere")
end)

test("from 0.6 to 0.7 with a /reload: the router's files are not read, straight lines, no error", function()
    -- Walk.lua was there before and is read anew; the files that are new
    -- are not, and the game does not know the map addons yet.
    local ns = PlateauScene(nil, function() world.unread = { Router = true, ["Lifts.lua"] = true } end)
    check(ns.Walk ~= nil, "Walk.lua is read")
    eq(ns.Path, nil, "the router is not")
    eq(ns.TravelLifts and #ns.TravelLifts or 0, 0, "nor the lifts")
    Advance(5)
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "the trip is the planner's")
    check(HasLabel(ns, "  Walking distances are as the crow flies."), "in straight lines, said so")
    eq(#world.loadCalls, 0, "no maps are asked for without a router")
    SlashCmdList.DROPOFF("debug")
    local walk = DropOffDB.snapshot.walk
    eq(walk.router, false, "the snapshot says the router is missing")
    eq(walk.maps[1].why, "MISSING", "and that the game does not know the map addon")
    ns.Toggle()
    check(not ChatHas("error"), "no error anywhere")
    eq(#world.errors, 0, "none for the game's handler either")
end)

test("the order of the list does not move when a real walk is longer", function()
    local router = Router()
    local ns = PlateauScene(router, function()
        -- A second hand-in 300 straight yards beyond the first.
        world.items[200] = { name = "Kodo Horn", class = 12 }
        Put(200, 1)
        world.quests[2] = { id = 2, title = "Further", complete = true, objectives = { { "Horn: 1/1", "item", true } } }
        world.db.quests[2] = { objectives = { nil, nil, { { 200 } } }, finishedBy = { { 20 } } }
        local nx, ny = OnMap(1443, GHOST_WALKER[1] - 300, GHOST_WALKER[2])
        world.db.npcs[20] = { name = "Far One", spawns = { [405] = { { nx * 100, ny * 100 } } }, friendlyToFaction = "H" }
    end)
    eq(Titles(ns.state.plan.ready), "King of the Foulweald,Further", "the nearer one first")
    router.Answer(ROUND)
    Advance(5)
    eq(Titles(ns.state.plan.ready), "King of the Foulweald,Further", "still first with its real, longer walk")
    check(Target(ns).eta > ns.state.plan.ready[2].target.eta, "though its real time is the longer one")
    eq(#router.asks, 1, "and only the trip the arrow is on is searched")
end)

test("French: à vol d'oiseau", function()
    local ns = PlateauScene(nil, function() world.locale = "frFR" end)
    check(HasLabel(ns, "  Distances à pied : à vol d'oiseau."), "a straight line says so in French")
end)

---------------------------------------------------------------------------
-- Lifts: not in the walking maps, tried as two walks joined
---------------------------------------------------------------------------

test("with no way straight there, the walk takes a lift", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer("unreachable")
    eq(#router.asks, 2, "a lift is tried at once")
    local ask = router.asks[2]
    check(Near(ask.from.x, THUNDER_BLUFF[1]) and ask.from.z == nil, "from the player")
    check(Near(ask.to.x, WEST_LIFT.x) and Near(ask.to.y, WEST_LIFT.y), "to the lift the straight lines make shortest")
    eq(ask.to.z, WEST_LIFT.top, "entered at the top first: the height picks the end")
    eq(ask.extra, 0, "nothing after the callback")
    eq(Trip(Target(ns).legs), "walk>1412|1443 walk>goal", "nothing is drawn before the search is over")
    router.Answer({})
    eq(#router.asks, 3, "then the way on from the other end")
    ask = router.asks[3]
    check(Near(ask.from.x, WEST_LIFT.x) and Near(ask.from.y, WEST_LIFT.y), "from the same spot on the map")
    eq(ask.from.z, WEST_LIFT.bottom, "at the bottom")
    check(Near(ask.to.x, GHOST_WALKER[1], 0.5), "to the hand-in")
    router.Answer(FROM_LIFT)
    eq(#router.asks, 4, "the same lift the other way round could still be shorter")
    eq(router.asks[4].to.z, WEST_LIFT.bottom, "entered at the bottom")
    router.Answer("unreachable")
    Advance(0.1)
    eq(#router.asks, 4, "the north lift is further than the way found: not tried")

    local target = Target(ns)
    local yards = PathYards(THUNDER_BLUFF, { { WEST_LIFT.x, WEST_LIFT.y }, FROM_LIFT[1] }, GHOST_WALKER)
    eq(Trip(target.legs), "walk>goal", "one walk")
    local leg = target.legs[1]
    check(leg.real, "along a real path")
    check(math.abs(leg.yards - yards) < 1, "the yards of both halves: " .. leg.yards .. " against " .. yards)
    check(math.abs(leg.seconds - (yards / 7 + 20)) < 0.5, "and twenty seconds for the lift")
    check(math.abs(target.eta - leg.seconds) < 0.5, "in the trip's time too")
    eq(#leg.path, 4, "the player, the lift, the turn, the hand-in: the lift is one point")
    eq(leg.lift, 2, "the lift is the next point")
    check(HasLabel(ns, "  Go to Nataka Longhorn · " .. math.floor(yards + 0.5) .. " yd"), "the step says the real yards")
    check(HasLabel(ns, "  On the way: take the lift."), "and a line of its own says to take the lift")
    check(not HasText(LabelTexts(ns), "as the crow flies"), "no straight line")
    DropOffFrame.size:Click()
    check(HasLabel(ns, "On the way: take the lift."), "in the small window too")
    DropOffFrame.size:Click()

    SlashCmdList.DROPOFF("debug")
    local answer = DropOffDB.snapshot.walk.answers[1]
    eq(answer.reason, "ok", "the snapshot has a path")
    eq(answer.direct, "unreachable", "that there was no way straight there")
    eq(answer.lift, true, "that it takes a lift")
    eq(answer.searches, 4, "and how many searches it took")
    eq(DropOffDB.snapshot.walk.answered, 1, "all of them one answer")
end)

test("the arrow stops at the lift, and the walk goes on from its other end", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer("unreachable")
    router.Answer({})
    router.Answer(FROM_LIFT)
    router.Answer("unreachable")
    Advance(0.1)
    -- Forty yards from the lift, on the way to it.
    local dx, dy = WEST_LIFT.x - THUNDER_BLUFF[1], WEST_LIFT.y - THUNDER_BLUFF[2]
    local length = math.sqrt(dx * dx + dy * dy)
    MovePlayer(WEST_LIFT.x - dx / length * 40, WEST_LIFT.y - dy / length * 40)
    Advance(2)
    local lx, ly = OnMap(1412, WEST_LIFT.x, WEST_LIFT.y)
    check(math.abs(world.arrow[2] - lx) < 0.0001 and math.abs(world.arrow[3] - ly) < 0.0001,
        "the arrow is on the lift, not on a turn beyond it on the floor below")
    eq(Target(ns).legs[1].lift, 2, "the lift is still ahead")

    -- At the lift: what led to it is behind, whichever end the player is at.
    MovePlayer(WEST_LIFT.x - dx / length * 10, WEST_LIFT.y - dy / length * 10)
    Advance(2)
    local leg = Target(ns).legs[1]
    eq(leg.lift, nil, "the lift is not ahead any more")
    eq(#leg.path, 3, "the player, the turn, the hand-in")
    check(not HasText(LabelTexts(ns), "take the lift"), "the window does not speak of it any more")
    local tx, ty = OnMap(1412, FROM_LIFT[1][1], FROM_LIFT[1][2])
    check(math.abs(world.arrow[2] - tx) < 0.0001 and math.abs(world.arrow[3] - ty) < 0.0001, "the arrow is on the next turn")
    check(math.abs(leg.seconds - leg.yards / 7) < 0.5, "and the time has no lift in it")

    -- Down below, walking back under the way that led to the lift: it is not taken up again.
    MovePlayer(WEST_LIFT.x - dx / length * 12, WEST_LIFT.y - dy / length * 12)
    Advance(2)
    eq(#Target(ns).legs[1].path, 3, "the path is still the one from the lift on")
    eq(#router.asks, 4, "and nothing is asked again")
end)

test("a lift that could beat the way round is tried, and the shorter way is kept", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer(ROUND)
    eq(#router.asks, 2, "the way round is long: the west lift could be shorter")
    eq(router.asks[2].to.z, WEST_LIFT.top, "entered at the top")
    router.Answer({})
    router.Answer(FROM_LIFT)
    router.Answer("unreachable")
    Advance(0.1)
    local leg = Target(ns).legs[1]
    local yards = PathYards(THUNDER_BLUFF, { { WEST_LIFT.x, WEST_LIFT.y }, FROM_LIFT[1] }, GHOST_WALKER)
    check(math.abs(leg.yards - yards) < 1, "the way through the lift is kept: " .. leg.yards)
    eq(leg.lift, 2, "with its lift")
    local answer = ns.Walk.State().answers[1]
    eq(answer.direct, math.floor(PathYards(THUNDER_BLUFF, ROUND, GHOST_WALKER) + 0.5), "the snapshot keeps the way round beside it")
    eq(answer.drawn, math.floor(yards + 0.5), "and the way kept")
end)

test("a lift that makes the walk longer is not taken", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer(ROUND)
    router.Answer({})
    -- From the foot of the lift, a long way round.
    router.Answer({ { -1400, 800 }, { -3000, 800 } })
    eq(router.asks[4].to.z, WEST_LIFT.bottom, "the same lift entered at the bottom")
    router.Answer("unreachable")
    eq(#router.asks, 5, "then the north lift, which could still beat the way round")
    router.Answer("unreachable")
    router.Answer("unreachable")
    Advance(0.1)
    eq(#router.asks, 6, "both ways, and no third lift")
    local leg = Target(ns).legs[1]
    check(math.abs(leg.yards - PathYards(THUNDER_BLUFF, ROUND, GHOST_WALKER)) < 1, "the way round is kept")
    eq(leg.lift, nil, "with no lift")
    eq(#leg.path, #ROUND + 2, "its own points")
    check(not HasText(LabelTexts(ns), "take the lift"), "and the window speaks of none")
end)

test("with no way on foot, only a lift close to the straight line is tried", function()
    -- At Hammerfall, far from the lifts of the Undercity: no way to the flight master.
    TravelScene(HAMMERFALL[1] - 200, HAMMERFALL[2])
    local router = Router()
    world.engine, world.lifts = router, true
    for name in pairs(MAP_ADDONS) do world.mapAddons[name] = true end
    local ns = Load()
    ns.Toggle()
    eq(router.asks[1].map, 0, "a walk in the Eastern Kingdoms")
    router.Answer("unreachable")
    eq(#router.asks, 1, "no lift of the continent is searched")
    eq(ns.Walk.State().answers[1].reason, "unreachable", "there is no way, and the snapshot says so")
    eq(ns.Walk.State().answers[1].searches, 1, "after one search")

    -- An end of the walk off the maps: the lift's two walks would have the same ends.
    router = Router()
    ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer("offmesh")
    eq(#router.asks, 1, "beside a lift, but no lift is tried")
    eq(ns.Walk.State().answers[1].reason, "offmesh", "the reason is the router's")
    router = Router()
    ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer("outside")
    eq(#router.asks, 1, "nor for a place outside the maps")
end)

test("a lift is not searched beyond the point where it can no longer win", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    -- A way straight there, shorter than the straight lines through any lift.
    router.Answer({})
    Advance(0.1)
    eq(#router.asks, 1, "no lift is tried")
    check(Target(ns).legs[1].real, "the way is used")

    router = Router()
    ns = PlateauScene(router, function() world.lifts = true end)
    -- A way a little longer than the straight lines through the west lift.
    router.Answer({ { -850, 900 } })
    eq(#router.asks, 2, "the lift is tried")
    -- The walk to its top alone is already too long.
    router.Answer({ { -1100, 300 }, { -700, 300 } })
    eq(#router.asks, 3, "so the way on from its foot is not asked")
    eq(router.asks[3].to.z, WEST_LIFT.bottom, "the next question is the lift entered at the bottom")
    router.Answer("unreachable")
    Advance(0.1)
    eq(#router.asks, 3, "and that is all")
    eq(Target(ns).legs[1].lift, nil, "the way straight there is kept")
end)

test("a lift search that takes too long leaves the way already found", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts = true end)
    router.Answer(ROUND)
    eq(#router.asks, 2, "a lift is being tried")
    Advance(100)
    eq(router.cancels, 1, "given up after a minute and a half")
    local leg = Target(ns).legs[1]
    check(leg.real, "the way round is used")
    eq(#leg.path, #ROUND + 2, "as it was answered")
    eq(ns.Walk.State().answers[1].reason, "ok", "and the snapshot has it")
    router.Answer({}, router.asks[2], true)
    Advance(0.1)
    eq(#router.asks, 2, "an answer that comes after that is dropped")
end)

test("in the Undercity the walk starts on the city's floor, not in the ruins over it", function()
    TravelScene()
    local x, y = OnMap(1458, 1596, 240)
    world.player = { map = 1458, x = x, y = y }
    local router = Router()
    world.engine = router
    for name in pairs(MAP_ADDONS) do world.mapAddons[name] = true end
    local ns = Load()
    ns.Toggle()
    eq(#router.asks, 1, "one search")
    eq(router.asks[1].from.z, -43.1, "from the height of the city's floor")
    check(Near(router.asks[1].from.x, 1596) and Near(router.asks[1].from.y, 240), "where the player stands")
    eq(ns.Walk.State().player.map, 1458, "the snapshot says which map told it")
end)

test("French: prends l'ascenseur", function()
    local router = Router()
    local ns = PlateauScene(router, function() world.lifts, world.locale = true, "frFR" end)
    router.Answer("unreachable")
    router.Answer({})
    router.Answer(FROM_LIFT)
    router.Answer("unreachable")
    Advance(0.1)
    check(HasLabel(ns, "  En chemin : prends l'ascenseur."), "the lift is said in French")
end)

---------------------------------------------------------------------------
-- The real router on the real maps
---------------------------------------------------------------------------

local function FileExists(path)
    local file = io.open(path)
    if file then file:close() end
    return file ~= nil
end

-- The embedded router searching the walking maps as shipped. Needs LuaJIT's
-- ffi and zlib, and the map folders.
local function RealMaps(name, fn)
    if not Inflate or not FileExists(ROOT .. "DropOff_Paths_Kalimdor/Nav1.lua") then
        print("SKIP [" .. name .. "] needs LuaJIT's ffi, zlib and the map folders")
        return
    end
    test(name, fn)
end

-- A walk of the real router from `from` to `to` ({ continent, x, y }), asked
-- through Walk.Use as the window does: the leg once the search is over.
local function RealWalk(ns, from, to)
    local straight = math.sqrt((from.x - to.x) ^ 2 + (from.y - to.y) ^ 2)
    local function Trip()
        local target = { eta = straight / 7, legs = {
            { kind = "walk", from = from, to = to, final = true, yards = straight, seconds = straight / 7 },
        } }
        ns.Walk.Use(target)
        return target
    end
    Trip()
    for _ = 1, 400 do
        Advance(0.05)
        local state = ns.Walk.State()
        if state.answered > 0 and not state.waiting then break end
    end
    local target = Trip()
    return target.legs[1], ns.Walk.State().answers[1], target
end

local function PassesBy(path, x, y, within)
    for _, point in ipairs(path) do
        if math.sqrt((point.x - x) ^ 2 + (point.y - y) ^ 2) <= within then return true end
    end
    return false
end

RealMaps("real maps: from the Thunder Bluff flight master down a lift to Ghost Walker Post", function()
    local ns = PlateauScene(nil, function()
        world.mapAddons.DropOff_Paths_Kalimdor = "real"
        world.lifts = true
    end)
    eq(world.loadCalls[1], "DropOff_Paths_Kalimdor", "the maps are read from their addon")
    for _ = 1, 400 do
        Advance(0.05)
        local state = ns.Walk.State()
        if state.answered > 0 and not state.waiting then break end
    end
    Advance(2)
    local target = Target(ns)
    eq(Trip(target.legs), "walk>goal", "one walk")
    local leg = target.legs[1]
    check(leg.real, "along a real path")
    check(leg.yards > 2600 and leg.yards < 3300, "about three kilometres, not 1700 yards: " .. math.floor(leg.yards))
    check(leg.lift ~= nil, "down a lift")
    check(PassesBy(leg.path, WEST_LIFT.x, WEST_LIFT.y, 6) or PassesBy(leg.path, -1032.655, -38.796, 6),
        "one of the two lifts of Thunder Bluff")
    check(HasLabel(ns, "  On the way: take the lift."), "the window says so")
    check(not HasText(LabelTexts(ns), "as the crow flies"), "and no straight line")
    local walk = ns.Walk.State()
    eq(walk.answers[1].direct, "unreachable", "there is no way down on foot")
    eq(walk.maps[1].loaded, true, "the snapshot says the maps loaded")
    eq(walk.maps[1].inMemory, true, "and are in memory")
    eq(#world.errors, 0, "the router raised nothing: " .. tostring(world.errors[1]))
    check(not ChatHas("error"), "no error shown")
    ns.Toggle()
    eq(#world.errors, 0, "closing lets go of the maps without an error")
end)

RealMaps("real maps: from Camp Taurajo to the floor of Thousand Needles by the Great Lift", function()
    NewWorld()
    world.mapAddons.DropOff_Paths_Kalimdor = "real"
    world.lifts = true
    local ns = Load()
    local leg, answer = RealWalk(ns, { continent = 1, x = -2380.7, y = -1882.7 }, { continent = 1, x = -4900, y = -1950 })
    check(leg.real, "a real path")
    check(leg.lift ~= nil, "with a lift")
    check(PassesBy(leg.path, -4668.1, -1838.64, 6), "the Great Lift")
    check(leg.yards > 2500 and leg.yards < 2900, "about 2700 yards: " .. math.floor(leg.yards))
    check(type(answer.direct) == "number" and answer.direct > leg.yards + 140,
        "shorter than the way round on foot: " .. tostring(answer.direct))
    eq(#world.errors, 0, "the router raised nothing: " .. tostring(world.errors[1]))
end)

RealMaps("real maps: a hand-in under another floor is reached on its own floor", function()
    NewWorld()
    world.mapAddons.DropOff_Paths_EasternKingdoms = "real"
    world.lifts = true
    local ns = Load()
    -- From Brill to the bat handler of the Undercity, under the Ruins of Lordaeron.
    local leg, answer = RealWalk(ns, { continent = 0, x = 2260, y = 290 }, { continent = 0, x = 1567.1, y = 266.3 })
    eq(world.loadCalls[1], "DropOff_Paths_EasternKingdoms", "with the maps of the Eastern Kingdoms")
    eq(answer.to.z, -42, "the hand-in's height comes from the spawn table")
    check(leg.real and leg.lift ~= nil, "down a lift of the city")
    check(leg.yards > 700 and leg.yards < 1000, "about 850 yards, not 1500 through the sewers: " .. math.floor(leg.yards))
    check(type(answer.direct) == "number" and answer.direct > 1300, "the way on foot alone: " .. tostring(answer.direct))
    eq(#world.errors, 0, "the router raised nothing: " .. tostring(world.errors[1]))
end)

RealMaps("real maps: out of the Undercity the walk goes up a lift", function()
    NewWorld()
    local x, y = OnMap(1458, 1596, 240)
    world.player = { map = 1458, x = x, y = y }
    world.mapAddons.DropOff_Paths_EasternKingdoms = "real"
    world.lifts = true
    local ns = Load()
    -- From the middle of the city, under the ruins, to Brill.
    local leg, answer = RealWalk(ns, { continent = 0, x = 1596, y = 240 }, { continent = 0, x = 2260, y = 290 })
    eq(answer.from.z, -43.1, "the walk starts on the city's floor")
    check(leg.real and leg.lift ~= nil, "up a lift: " .. tostring(answer.reason))
    check(leg.yards > 750 and leg.yards < 1050, "about 900 yards: " .. math.floor(leg.yards))
    check(type(answer.direct) == "number" and answer.direct > 1300, "not out through the sewers: " .. tostring(answer.direct))
    eq(#world.errors, 0, "the router raised nothing: " .. tostring(world.errors[1]))
end)

---------------------------------------------------------------------------
-- Packaging
---------------------------------------------------------------------------

test("each map addon lists every map file of its folder and follows DropOff's version", function()
    local version
    for line in io.lines(ROOT .. "DropOff.toc") do version = version or line:match("^## Version: (%S+)") end
    check(version ~= nil, "DropOff.toc has a version")
    local prefix = { DropOff_Paths_EasternKingdoms = "Nav0", DropOff_Paths_Kalimdor = "Nav1", DropOff_Paths_Zephras = "Nav2991" }
    for name in pairs(MAP_ADDONS) do
        current = "map addon " .. name
        local listed, fields = {}, {}
        for line in io.lines(ROOT .. name .. "/" .. name .. ".toc") do
            local field, value = line:match("^## ([%w%-]+): (.-)%s*$")
            if field then fields[field] = value end
            local file = line:match("^([%w_]+%.lua)%s*$")
            if file then listed[#listed + 1] = file end
        end
        eq(fields.Version, version, "its version is DropOff's")
        eq(fields.LoadOnDemand, "1", "loaded on demand")
        eq(fields.Dependencies, "DropOff", "after DropOff")
        eq(fields.Interface, "16001", "for this game version")
        eq(listed[1], prefix[name] .. ".lua", "the map's table first")
        for index = 2, #listed do eq(listed[index], prefix[name] .. "_" .. (index - 1) .. ".lua", "then its parts in order") end
        for _, file in ipairs(listed) do check(FileExists(ROOT .. name .. "/" .. file), file .. " is in the folder") end
        check(not FileExists(ROOT .. name .. "/" .. prefix[name] .. "_" .. #listed .. ".lua"), "and no part is left out")
    end
end)

---------------------------------------------------------------------------

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
