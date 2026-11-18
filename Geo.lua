local _, ns = ...
local Try, Secret = ns.Try, ns.Secret

-- Turns database spawn points (zone area ID + 0..100 percentages) into map
-- positions and distances from the player.
local Geo = {}
ns.Geo = Geo

local ZONE_MAP_TYPE = 3

---------------------------------------------------------------------------
-- Libraries other addons already loaded (never embedded here)
---------------------------------------------------------------------------

local function HBD()
    local stub = rawget(_G, "LibStub")
    if not stub then return nil end
    local ok, lib = pcall(stub, "HereBeDragons-2.0", true)
    if ok and type(lib) == "table" and lib.GetPlayerWorldPosition and lib.GetWorldCoordinatesFromZone then
        return lib
    end
    return nil
end

function Geo.HasHBD()
    return HBD() ~= nil
end

-- Questie's zone module: owns the area ID -> map ID table and dungeon entrances.
local function ZoneDB()
    local loader = rawget(_G, "QuestieLoader")
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then return nil end
    local ok, module = pcall(loader.ImportModule, loader, "ZoneDB")
    if ok and type(module) == "table" then return module end
    return nil
end

---------------------------------------------------------------------------
-- Area ID -> UI map ID
---------------------------------------------------------------------------

local RETRY = 10  -- seconds before asking again about something that failed

local areaToMap, missAt = {}, {}
local nameIndex, nameIndexAt

local function Clock()
    return type(GetTime) == "function" and GetTime() or 0
end

-- Fallback without Questie: match the area's name against the zone maps.
local function BuildNameIndex()
    if not (C_Map and C_Map.GetMapInfo and C_Map.GetMapChildrenInfo and C_Map.GetBestMapForUnit) then return nil end
    local root = Try(C_Map.GetBestMapForUnit, "player")
    if type(root) ~= "number" then return nil end
    for _ = 1, 10 do
        local info = Try(C_Map.GetMapInfo, root)
        if type(info) ~= "table" or not info.parentMapID or info.parentMapID == 0 then break end
        root = info.parentMapID
    end
    local children = Try(C_Map.GetMapChildrenInfo, root, nil, true)
    if type(children) ~= "table" then return nil end

    local index = {}
    for pass = 1, 2 do
        for _, child in ipairs(children) do
            local isZone = child.mapType == ZONE_MAP_TYPE
            if child.name and child.mapID and not index[child.name] and (isZone or pass == 2) then
                index[child.name] = child.mapID
            end
        end
    end
    return index
end

-- The index is built once. While it cannot be built (player map unknown at
-- login), it is retried every RETRY seconds, not for every spawn point.
local function NameIndex()
    if nameIndex then return nameIndex end
    local now = Clock()
    if nameIndexAt and now - nameIndexAt < RETRY then return nil end
    nameIndexAt = now
    nameIndex = BuildNameIndex()
    return nameIndex
end

function Geo.MapForArea(areaId)
    local known = areaToMap[areaId]
    if known then return known end
    local now = Clock()
    if missAt[areaId] and now - missAt[areaId] < RETRY then return nil end

    local mapId
    local zones = ZoneDB()
    if zones and type(zones.GetUiMapIdByAreaId) == "function" then
        local ok, id = pcall(zones.GetUiMapIdByAreaId, zones, areaId)
        if ok and type(id) == "number" then mapId = id end
    end
    if not mapId and C_Map and C_Map.GetAreaInfo then
        local name = Try(C_Map.GetAreaInfo, areaId)
        if type(name) == "string" then
            local index = NameIndex()
            mapId = index and index[name] or nil
        end
    end

    if mapId then
        areaToMap[areaId], missAt[areaId] = mapId, nil
    else
        missAt[areaId] = now
    end
    return mapId
end

-- Outdoor entrances of a dungeon area: list of { areaId, x, y } or nil.
local function DungeonEntrances(areaId)
    local zones = ZoneDB()
    if not zones or type(zones.GetDungeonLocation) ~= "function" then return nil end
    local ok, list = pcall(zones.GetDungeonLocation, zones, areaId)
    if ok and type(list) == "table" then return list end
    return nil
end

function Geo.MapName(mapId)
    local info = C_Map and Try(C_Map.GetMapInfo, mapId)
    return type(info) == "table" and info.name or nil
end

---------------------------------------------------------------------------
-- Player position, read once per plan
---------------------------------------------------------------------------

local player = {}

local function Usable(value)
    return value ~= nil and not Secret(value) and type(value) == "number"
end

function Geo.BeginPass()
    player = {}
    local hbd = HBD()
    if hbd then
        local ok, x, y, instance = pcall(hbd.GetPlayerWorldPosition, hbd)
        if ok and Usable(x) and Usable(y) then
            player.hbd, player.x, player.y, player.instance = hbd, x, y, instance
            -- HereBeDragons swaps the game's axes: its x runs west, its y north.
            player.gx, player.gy = y, x
            return
        end
    end
    if C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos then
        local mapId = Try(C_Map.GetBestMapForUnit, "player")
        local position = mapId and Try(C_Map.GetPlayerMapPosition, mapId, "player")
        if position then
            local continent, world = Try(C_Map.GetWorldPosFromMapPos, mapId, position)
            if type(world) == "table" and Usable(world.x) and Usable(world.y) then
                player.x, player.y, player.instance = world.x, world.y, continent
                player.gx, player.gy = world.x, world.y
            end
        end
    end
end

-- The player in the game's world yards (x north, y west) and the continent,
-- as of the last pass. Nil when unknown.
function Geo.PlayerWorld()
    if not player.gx or type(player.instance) ~= "number" then return nil end
    return player.gx, player.gy, player.instance
end

-- A map point (x, y in 0..1) in the game's world yards, plus its continent.
function Geo.World(mapId, x, y)
    local hbd = HBD()
    if hbd then
        local ok, wx, wy, instance = pcall(hbd.GetWorldCoordinatesFromZone, hbd, x, y, mapId)
        if ok and Usable(wx) and Usable(wy) and type(instance) == "number" then return wy, wx, instance end
    end
    if C_Map and C_Map.GetWorldPosFromMapPos and type(CreateVector2D) == "function" then
        local continent, world = Try(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D(x, y))
        if type(world) == "table" and Usable(world.x) and Usable(world.y) and type(continent) == "number" then
            return world.x, world.y, continent
        end
    end
    return nil
end

local CONTINENT_MAP = { [0] = 1415, [1] = 1414 }  -- Eastern Kingdoms, Kalimdor

local function Inside(value)
    return Usable(value) and value >= 0 and value <= 1
end

-- World yards on a map: x, y in 0..1, or nil when the point is not on it.
local function OnMap(continent, gx, gy, mapId)
    local hbd = HBD()
    if hbd and hbd.GetZoneCoordinatesFromWorld then
        local ok, x, y = pcall(hbd.GetZoneCoordinatesFromWorld, hbd, gy, gx, mapId)
        if ok and Inside(x) and Inside(y) then return x, y end
    end
    if C_Map and C_Map.GetMapPosFromWorldPos and type(CreateVector2D) == "function" then
        local _, position = Try(C_Map.GetMapPosFromWorldPos, continent, CreateVector2D(gx, gy), mapId)
        if type(position) == "table" and Inside(position.x) and Inside(position.y) then
            return position.x, position.y
        end
    end
    return nil
end

local places = {}

-- The map to show a world point on: the zone under it when the game can name
-- it, else the continent. Returns mapId, x, y (0..1), or nil. Travel hubs do
-- not move, so answers are kept.
function Geo.Place(continent, gx, gy)
    local key = ("%d:%.0f:%.0f"):format(continent, gx, gy)
    local known = places[key]
    if known then return known[1], known[2], known[3] end

    local mapId = CONTINENT_MAP[continent]
    if not mapId then return nil end
    local x, y = OnMap(continent, gx, gy, mapId)
    if not x then return nil end
    local info = C_Map and Try(C_Map.GetMapInfoAtPosition, mapId, x, y)
    if type(info) == "table" and type(info.mapID) == "number" and info.mapID ~= mapId then
        local zx, zy = OnMap(continent, gx, gy, info.mapID)
        if zx then mapId, x, y = info.mapID, zx, zy end
    end
    places[key] = { mapId, x, y }
    return mapId, x, y
end

-- For the debug snapshot: where the last pass thought the player was.
function Geo.PlayerDebug()
    return {
        known = player.x ~= nil,
        via = player.hbd and "hbd" or player.x and "native" or nil,
        x = player.x, y = player.y, instance = player.instance,
        map = C_Map and Try(C_Map.GetBestMapForUnit, "player"),
    }
end

-- Yards from the player to a map point (x, y in 0..1).
-- Returns nil when unknown, plus true when the point is on another continent.
function Geo.Distance(mapId, x, y)
    if not player.x then return nil end
    local tx, ty, instance
    if player.hbd then
        local ok, wx, wy, winstance = pcall(player.hbd.GetWorldCoordinatesFromZone, player.hbd, x, y, mapId)
        if ok then tx, ty, instance = wx, wy, winstance end
    elseif type(CreateVector2D) == "function" then
        local continent, world = Try(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D(x, y))
        if type(world) == "table" then tx, ty, instance = world.x, world.y, continent end
    end
    if not (Usable(tx) and Usable(ty)) then return nil end
    if instance ~= player.instance then return nil, true end
    local dx, dy = tx - player.x, ty - player.y
    return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- Nearest spawn
---------------------------------------------------------------------------

local function Valid(value)
    return type(value) == "number" and value >= 0 and value <= 100
end

-- spawns: { [areaId] = { { x, y }, ... } } with percentages 0..100, or -1/-1
-- for "inside this dungeon". Returns the closest reachable point as
-- { mapId, x, y, dist, far, dungeon, areaId } (x, y in 0..1), or nil.
function Geo.NearestSpawn(spawns)
    local best
    local function consider(areaId, sx, sy, dungeon)
        if not (Valid(sx) and Valid(sy)) then return end
        local mapId = Geo.MapForArea(areaId)
        if not mapId then return end
        local x, y = sx / 100, sy / 100
        local dist, far = Geo.Distance(mapId, x, y)
        local closer = not best
            or (dist and (not best.dist or dist < best.dist))
            or (not dist and not best.dist and best.far and not far)
        if closer then
            best = { mapId = mapId, x = x, y = y, dist = dist, far = far or false,
                     dungeon = dungeon or false, areaId = areaId }
        end
    end

    for areaId, points in pairs(spawns) do
        if type(points) == "table" then
            for _, point in pairs(points) do
                if type(point) == "table" then
                    if point[1] == -1 or point[2] == -1 then
                        for _, entrance in pairs(DungeonEntrances(areaId) or {}) do
                            if type(entrance) == "table" then
                                consider(entrance[1], entrance[2], entrance[3], true)
                            end
                        end
                    else
                        consider(areaId, point[1], point[2], false)
                    end
                end
            end
        end
    end
    return best
end
