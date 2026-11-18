local _, ns = ...
local Try, Secret = ns.Try, ns.Secret

-- Plans the trip to a hand-in: on foot, by flight path, boat, zeppelin or
-- airship. It works in seconds along straight lines inside a zone, and a walk
-- changes zone only where the zones join (Passes.lua). What it returns is an
-- estimate of the fastest way, not a path that follows the roads.
local Route = {}
ns.Route = Route

local WALK_SPEED = 7        -- yards a second on foot
Route.WALK_SPEED = WALK_SPEED
local DETOUR = 1.3          -- roads are longer than straight lines
local FLY_SPEED = 30        -- yards a second on a flight path
local RIDE_SECONDS = 240    -- a boat, zeppelin or airship: the wait plus the crossing
local ARRIVE = 30           -- yards: this close to a flight master or a dock is "there"
local PASS_NEAR = 200       -- yards: this close to a pass, the walk to it is done
local DOCK_ZONE = 1200      -- yards: a dock is in the zone of a flight master this close
local NAMES_RETRY = 10      -- seconds before asking the game for names again
local PASS_RETRY = 10       -- seconds before placing again the passes the game could not place,
local PASS_RETRY_MAX = 300  -- doubled after each try, up to this

local CONTINENT_MAPS = { 1415, 1414 }   -- Eastern Kingdoms, Kalimdor
local FACTION = { Horde = "H", Alliance = "A" }
-- What the flight map calls a master the character has learned. DISTANT is
-- one a flight only passes through: not learned.
local LEARNED_TYPE = { CURRENT = true, REACHABLE = true, UNREACHABLE = true }

local hubs, edges           -- the travel graph, built when first needed
local builtFor              -- the faction it was built for (false: not known yet)
local builtAt               -- when it was built
-- How the passes were placed. `waiting`: the game could not place them yet.
-- `misplaced`: it put them on another continent than their zones.
local passCount = { total = 0, placed = 0, waiting = 0, misplaced = 0, tries = 0 }
local passWait = PASS_RETRY -- seconds before the next try
local origin                -- where the last pass started
local cost, cameFrom, cameBy   -- per hub: seconds from the origin, previous hub, edge used

---------------------------------------------------------------------------
-- What this character can use
---------------------------------------------------------------------------

local function Faction()
    local group = type(UnitFactionGroup) == "function" and Try(UnitFactionGroup, "player")
    return FACTION[group]
end

local function CharDB()
    return type(DropOffCharDB) == "table" and DropOffCharDB or nil
end

-- Has the flight map been read on this continent? Until it has, every flight
-- master of the faction is taken as known.
local function Seen(continent)
    local db = CharDB()
    return db ~= nil and type(db.flightsSeen) == "table" and db.flightsSeen[continent] == true
end

local function Knows(id, continent)
    if not Seen(continent) then return true end
    local db = CharDB()
    return type(db.flights) == "table" and db.flights[id] == true
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------

local function Passes()
    return type(ns.TravelPasses) == "table" and ns.TravelPasses or nil
end

-- The zone a map counts as when walking: a city is the zone around it, a
-- map inside a zone (a cave, a district) is that zone. Nil for a map the
-- pass table does not know.
function Route.Zone(mapId)
    local data = Passes()
    if not data then return nil end
    for _ = 1, 3 do
        if type(mapId) ~= "number" then return nil end
        mapId = data.cities[mapId] or mapId
        if data.zones[mapId] then return mapId end
        local info = C_Map and C_Map.GetMapInfo and Try(C_Map.GetMapInfo, mapId)
        mapId = type(info) == "table" and info.parentMapID or nil
    end
    return nil
end

-- "Sun Rock Retreat, Stonetalon Mountains" -> the zone of that flight master.
local function NodeZone(node)
    local data = Passes()
    if not data or not node then return nil end
    return data.names[node[1]:match(",%s*([^,]+)$") or node[1]]
end

-- Can a character walk from one place to the other without leaving a zone?
-- A pass stands in its two zones. The player or a hand-in whose zone is not
-- known is not checked: it walks anywhere on its continent, as every place
-- did before. A flight master or a dock in an unknown zone is walked to from
-- unknown places only: nothing says a known zone joins it, and a trip must
-- not slip from one zone to another through it.
local function Joined(a, b)
    if a.zone and b.zone then
        return a.zone == b.zone or a.zone == b.zone2
            or (a.zone2 ~= nil and (a.zone2 == b.zone or a.zone2 == b.zone2))
    end
    if a.zone or b.zone then return not (a.zone and b or a).hub end
    return true
end

-- The zone a walk is in once through `pass`, heading for `after` (the next
-- place of the trip) out of `fromZone`.
local function Beyond(pass, after, fromZone)
    if after and after.zone then
        local first = after.zone == pass.zone or after.zone2 == pass.zone
        local second = after.zone == pass.zone2 or after.zone2 == pass.zone2
        if first ~= second then return first and pass.zone or pass.zone2 end
    end
    if fromZone == pass.zone then return pass.zone2 end
    if fromZone == pass.zone2 then return pass.zone end
    return nil
end

---------------------------------------------------------------------------
-- Graph
---------------------------------------------------------------------------

local function Yards(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function WalkSeconds(yards)
    return yards * DETOUR / WALK_SPEED
end

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

-- A pass of the table in world yards. Nil when the game cannot place it yet
-- (its map is not ready), or, with true, when it places it on another
-- continent than its zones: the pass is then left out, never guessed.
local function PassWorld(pass, continent)
    if not pass[3] then return pass[4], pass[5] end
    local x, y, found = ns.Geo.World(pass[3], pass[4] / 100, pass[5] / 100)
    if not x then return nil end
    if found ~= continent then return nil, true end
    return x, y
end

local function Build()
    hubs, edges = {}, {}
    passCount.total, passCount.placed, passCount.waiting, passCount.misplaced = 0, 0, 0, 0
    builtAt = Now()
    local data = ns.TravelData
    if type(data) ~= "table" then return end
    local mine = Faction()
    builtFor = mine or false
    local function usable(faction) return faction == "B" or faction == mine end
    local function add(hub)
        hub.hub = true
        hubs[#hubs + 1] = hub
        edges[#hubs] = {}
        return #hubs
    end

    -- Flight masters, in a fixed order so equal routes always come out the same.
    local ids = {}
    for id in pairs(data.nodes or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    local byNode = {}
    for _, id in ipairs(ids) do
        local node = data.nodes[id]
        if usable(node[5]) and Knows(id, node[2]) then
            byNode[id] = add({ continent = node[2], x = node[3], y = node[4], node = id, zone = NodeZone(node) })
        end
    end
    for _, path in ipairs(data.flights or {}) do
        local from, to = byNode[path[1]], byNode[path[2]]
        if from and to then
            edges[from][#edges[from] + 1] = { to = to, seconds = path[3] / FLY_SPEED, kind = "fly" }
        end
    end

    -- Docks: one hub per platform, shared by the routes that use it. A dock
    -- is in the zone the pass table gives it, else in the zone of the nearest
    -- flight master, whoever that one serves.
    local passes = Passes()
    local function dockZone(place, key)
        if passes and passes.docks[key] then return passes.docks[key] end
        local zone, nearest = nil, DOCK_ZONE
        for _, id in ipairs(ids) do
            local node = data.nodes[id]
            if node[2] == place.continent then
                local yards = Yards(place, { x = node[3], y = node[4] })
                if yards < nearest then zone, nearest = NodeZone(node), yards end
            end
        end
        return zone
    end
    local byDock = {}
    local function dock(continent, x, y, near)
        local key = continent .. ":" .. x .. ":" .. y
        if not byDock[key] then
            local hub = { continent = continent, x = x, y = y, dock = true, near = near or nil }
            hub.zone = dockZone(hub, key)
            byDock[key] = add(hub)
        end
        return byDock[key]
    end
    for _, ride in ipairs(data.transports or {}) do
        if usable(ride[3]) then
            local from = dock(ride[4], ride[5], ride[6], ride[7])
            local to = dock(ride[8], ride[9], ride[10], ride[11])
            edges[from][#edges[from] + 1] = { to = to, seconds = RIDE_SECONDS, kind = ride[1], route = ride[2] }
        end
    end

    -- Passes: where two zones join on foot. One the game cannot place is left
    -- out, and the two zones stay apart until a later build places it: the
    -- zone check is never dropped for it.
    for _, pass in ipairs(passes and passes.passes or {}) do
        local continent = passes.zones[pass[1]]
        local x, y = PassWorld(pass, continent)
        passCount.total = passCount.total + 1
        if x then
            passCount.placed = passCount.placed + 1
            add({ continent = continent, x = x, y = y, pass = true, zone = pass[1], zone2 = pass[2] })
        elseif y then
            passCount.misplaced = passCount.misplaced + 1
        else
            passCount.waiting = passCount.waiting + 1
        end
    end

    -- On foot between two hubs of one continent that share a zone.
    for a = 1, #hubs do
        for b = a + 1, #hubs do
            if hubs[a].continent == hubs[b].continent and Joined(hubs[a], hubs[b]) then
                local seconds = WalkSeconds(Yards(hubs[a], hubs[b]))
                edges[a][#edges[a] + 1] = { to = b, seconds = seconds, kind = "walk" }
                edges[b][#edges[b] + 1] = { to = a, seconds = seconds, kind = "walk" }
            end
        end
    end
end

-- Forgets the graph and the last pass: the data or what the character knows
-- has changed.
function Route.Reset()
    hubs, edges, origin = nil, nil, nil
    passCount.tries, passWait = 0, PASS_RETRY
end

-- The game could not place some passes yet, and it is time to try again.
-- Each try waits twice as long as the one before: a map that never gets
-- ready costs one rebuild every five minutes, no more.
local function PassesDue()
    if passCount.waiting == 0 or Now() - builtAt < passWait then return false end
    passCount.tries = passCount.tries + 1
    passWait = math.min(passWait * 2, PASS_RETRY_MAX)
    return true
end

-- For the debug snapshot: how many passes the table has, how many the game
-- placed, could not place yet or placed on the wrong continent, and how many
-- times placing the rest was tried again.
function Route.PassState()
    return { total = passCount.total, placed = passCount.placed, waiting = passCount.waiting,
             misplaced = passCount.misplaced, tries = passCount.tries }
end

---------------------------------------------------------------------------
-- One pass: fastest way from the player to every hub
---------------------------------------------------------------------------

local FROM_ORIGIN = { kind = "walk" }

-- x, y: the game's world yards. mapId: the map of the zone the player is in,
-- when known. Returns true when routes can be asked for.
function Route.Begin(x, y, continent, mapId)
    origin = nil
    if type(x) ~= "number" or type(y) ~= "number" or type(continent) ~= "number" then return false end
    -- Built once, and again if the faction was not known the first time (login).
    -- And again while some passes are not placed.
    if not hubs or builtFor ~= (Faction() or false) or PassesDue() then Build() end
    origin = { continent = continent, x = x, y = y, zone = Route.Zone(mapId) }
    cost, cameFrom, cameBy = {}, {}, {}

    for index, hub in ipairs(hubs) do
        if hub.continent == continent and Joined(origin, hub) then
            cost[index], cameFrom[index], cameBy[index] = WalkSeconds(Yards(origin, hub)), 0, FROM_ORIGIN
        end
    end
    local settled = {}
    while true do
        local best, bestCost
        for index = 1, #hubs do
            local seconds = cost[index]
            if seconds and not settled[index] and (not bestCost or seconds < bestCost) then
                best, bestCost = index, seconds
            end
        end
        if not best then break end
        settled[best] = true
        for _, edge in ipairs(edges[best]) do
            local total = bestCost + edge.seconds
            if not cost[edge.to] or total < cost[edge.to] then
                cost[edge.to], cameFrom[edge.to], cameBy[edge.to] = total, best, edge
            end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Legs
---------------------------------------------------------------------------

local function Point(place)
    return { continent = place.continent, x = place.x, y = place.y,
             node = place.node, dock = place.dock, near = place.near,
             pass = place.pass, zone = place.zone, zone2 = place.zone2 }
end

-- Appends one stretch of the trip, joining it to the previous one when both
-- are flights (a flight through several masters is one leg) or both on foot.
-- A walk that reached a pass ends there: the next one starts a new leg, so
-- the trip is never shown as one straight line across a zone border.
local function AddLeg(legs, kind, from, to, seconds, edge)
    local last = legs[#legs]
    local yards = kind == "walk" and Yards(from, to) or nil
    if last and last.kind == kind and (kind == "fly" or (kind == "walk" and not last.to.pass)) then
        last.to, last.seconds = Point(to), last.seconds + seconds
        if yards then last.yards = last.yards + yards end
        if kind == "fly" then last.stops = last.stops + 1 end
        return
    end
    legs[#legs + 1] = {
        kind = kind, from = Point(from), to = Point(to), seconds = seconds,
        yards = yards, stops = kind == "fly" and 0 or nil, route = edge and edge.route or nil,
        assumed = kind == "fly" and not (Seen(from.continent) and Seen(to.continent)) or nil,
    }
end

-- Fastest way from the last pass's origin to a world point. mapId: the map
-- of the zone the point is in, when known. Returns the seconds and the legs
-- ({ kind, from, to, seconds, ... }, the last one always the walk to the
-- point), or nil when there is no way.
function Route.To(x, y, continent, mapId)
    if not origin or type(x) ~= "number" or type(y) ~= "number" or type(continent) ~= "number" then return nil end
    local goal = { continent = continent, x = x, y = y, zone = Route.Zone(mapId) }

    local seconds, lastHub
    if continent == origin.continent and Joined(origin, goal) then seconds = WalkSeconds(Yards(origin, goal)) end
    for index, hub in ipairs(hubs) do
        if cost[index] and hub.continent == continent and Joined(hub, goal) then
            local total = cost[index] + WalkSeconds(Yards(hub, goal))
            if not seconds or total < seconds then seconds, lastHub = total, index end
        end
    end
    if not seconds then return nil end

    local chain = {}
    local index = lastHub
    while index and index ~= 0 do
        table.insert(chain, 1, index)
        index = cameFrom[index]
    end

    -- `at`: where the next leg starts. `through`: the last place of the
    -- chain, which is a pass the player is already at when it gave no leg.
    local legs, at, through, zone = {}, origin, origin, origin.zone
    local skipped = 0   -- seconds of a walk to a pass that gave no leg: the next leg takes them
    for position, hubIndex in ipairs(chain) do
        local hub, edge = hubs[hubIndex], cameBy[hubIndex]
        local stretch = (edge == FROM_ORIGIN and WalkSeconds(Yards(through, hub)) or edge.seconds) + skipped
        skipped = 0
        if hub.pass then
            zone = Beyond(hub, hubs[chain[position + 1]] or goal, zone)
            -- At the pass already: the walk goes on from where the player is.
            if Yards(at, hub) >= PASS_NEAR then
                AddLeg(legs, "walk", at, hub, stretch, edge)
                legs[#legs].enter = zone
                at = hub
            else
                skipped = stretch
            end
        else
            -- Already standing at the flight master or on the dock: no step for it.
            if not (edge.kind == "walk" and Yards(at, hub) < ARRIVE) then
                AddLeg(legs, edge.kind, at, hub, stretch, edge)
            end
            at, zone = hub, hub.zone
        end
        through = hub
    end
    local ending = WalkSeconds(Yards(through, goal)) + skipped
    local last = legs[#legs]
    if last and last.kind == "walk" and not last.to.pass then
        -- The trip ends on foot through a hub it does not use: one walk.
        last.to, last.final = Point(goal), true
        last.seconds, last.yards = last.seconds + ending, last.yards + Yards(at, goal)
    else
        AddLeg(legs, "walk", at, goal, ending)
        legs[#legs].final = true
    end
    return seconds, legs
end

---------------------------------------------------------------------------
-- Names, in the client's language when the game gives them
---------------------------------------------------------------------------

local names, namesAt

local function LocalNames()
    if names then return names end
    local now = type(GetTime) == "function" and GetTime() or 0
    if namesAt and now - namesAt < NAMES_RETRY then return nil end
    namesAt = now
    if type(C_TaxiMap) ~= "table" or type(C_TaxiMap.GetTaxiNodesForMap) ~= "function" then return nil end
    local found, any = {}, false
    for _, mapId in ipairs(CONTINENT_MAPS) do
        local list = Try(C_TaxiMap.GetTaxiNodesForMap, mapId)
        if type(list) == "table" then
            for _, info in ipairs(list) do
                if type(info) == "table" and type(info.nodeID) == "number"
                    and type(info.name) == "string" and not Secret(info.name) and info.name ~= "" then
                    found[info.nodeID], any = info.name, true
                end
            end
        end
    end
    if any then names = found end
    return names
end

-- A flight master's place name.
function Route.NodeName(id)
    local localNames = LocalNames()
    if localNames and localNames[id] then return localNames[id] end
    local node = ns.TravelData and ns.TravelData.nodes and ns.TravelData.nodes[id]
    return node and node[1] or nil
end

-- "Hammerfall, Arathi" -> "Hammerfall": the steps are one short line each.
local function Short(name)
    return name and (name:match("^(.-),%s") or name) or nil
end

-- A dock is named after the flight master next to it, else after its zone.
local function DockName(point)
    if point.near then return Short(Route.NodeName(point.near)) end
    local mapId = ns.Geo.Place(point.continent, point.x, point.y)
    return mapId and ns.Geo.MapName(mapId) or nil
end

local RIDE = { zeppelin = "ZEPPELIN", boat = "BOAT", airship = "AIRSHIP" }

local function Named(base, name)
    local L = ns.L
    if name then return L[base]:format(name) end
    return L[base .. "_PLAIN"]
end

-- One line telling the player what to do for leg `index` of `legs`.
-- `who` is the name of the hand-in, for the last leg. `bare` leaves out the
-- walking distance, for a text that must not change at every step.
function Route.StepText(legs, index, who, bare)
    local L = ns.L
    local leg = legs[index]
    local text
    if leg.kind == "fly" then
        text = Named("STEP_FLY", Short(Route.NodeName(leg.to.node)))
    elseif RIDE[leg.kind] then
        text = Named("STEP_RIDE_" .. RIDE[leg.kind], DockName(leg.to))
    elseif leg.final then
        text = Named("STEP_HAND_IN", who)
    elseif leg.to.node then
        text = Named("STEP_TO_FLIGHT", Short(Route.NodeName(leg.to.node)))
    elseif leg.to.pass then
        text = Named("STEP_PASS", leg.enter and ns.Geo.MapName(leg.enter) or nil)
    else
        local nextLeg = legs[index + 1]
        text = Named("STEP_TO_" .. (nextLeg and RIDE[nextLeg.kind] or "BOAT"), DockName(leg.to))
    end
    if leg.yards and not bare then text = text .. " · " .. L.DIST_YARDS:format(math.floor(leg.yards + 0.5)) end
    return text
end

-- "about 13 min" style duration.
function Route.TimeText(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 1 then return ns.L.TIME_UNDER_MIN end
    return ns.L.TIME_MIN:format(minutes)
end

-- Where the player has to be next: the end of a walk, else the flight master
-- or dock they are standing at. In the air (`flying`), where the flight lands.
-- `carried` ("fly" on a flight path, "ride" on a boat, zeppelin or airship)
-- means the plan dates from before boarding: the place is where it lands.
function Route.NextPlace(legs, carried)
    local first = legs and legs[Route.FirstLeg(legs, carried)]
    if not first then return nil end
    if carried or first.kind == "walk" then return first.to end
    return first.from
end

local NEAR_DOCK = 150   -- yards: just stepped off the platform, onto the vessel

-- Does the trip start with a crossing the player is at, or has just boarded?
function Route.AtCrossing(legs)
    local first, second = legs and legs[1], legs and legs[2]
    if not first then return false end
    if RIDE[first.kind] then return true end
    return first.kind == "walk" and first.to.dock == true and first.yards < NEAR_DOCK
        and second ~= nil and RIDE[second.kind] ~= nil
end

-- Index of the leg the player is on: 1, or while carried the first flight or
-- crossing of the plan (the walk to it is behind them). Nil when the plan has
-- no such leg.
function Route.FirstLeg(legs, carried)
    if not legs then return nil end
    if not carried then return legs[1] and 1 or nil end
    for index, leg in ipairs(legs) do
        if (carried == "fly" and leg.kind == "fly") or (carried == "ride" and RIDE[leg.kind]) then
            return index
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Learning which flight masters the character knows
---------------------------------------------------------------------------

-- Returns whether the flight map lists this master as learned, and whether
-- it is the one the player is standing at.
local function IsLearned(info)
    if type(TaxiNodeGetType) == "function" and type(info.slotIndex) == "number" then
        local kind = Try(TaxiNodeGetType, info.slotIndex)
        if type(kind) == "string" then return LEARNED_TYPE[kind] == true, kind == "CURRENT" end
    end
    local states = type(Enum) == "table" and Enum.FlightPathState
    if type(states) == "table" then
        return info.state == states.Current or info.state == states.Reachable, info.state == states.Current
    end
    return info.state == 0 or info.state == 1, info.state == 0
end

-- Reads the open flight map: the masters it lists as learned are the ones the
-- character knows on that continent. Returns true when something was read.
function Route.RecordTaxiMap()
    local db, data = CharDB(), ns.TravelData
    if not db or type(data) ~= "table" then return false end
    local learned, continents, any, here = {}, {}, false, false
    local function learn(id, current)
        local node = data.nodes[id]
        if node then
            learned[id], continents[node[2]], any = true, true, true
            here = here or current == true
        end
    end

    if type(C_TaxiMap) == "table" and type(C_TaxiMap.GetAllTaxiNodes) == "function" then
        local mapId = type(GetTaxiMapID) == "function" and Try(GetTaxiMapID)
        if type(mapId) ~= "number" then mapId = C_Map and Try(C_Map.GetBestMapForUnit, "player") end
        local list = type(mapId) == "number" and Try(C_TaxiMap.GetAllTaxiNodes, mapId)
        if type(list) == "table" then
            for _, info in ipairs(list) do
                if type(info) == "table" and type(info.nodeID) == "number" then
                    local known, current = IsLearned(info)
                    if known then learn(info.nodeID, current) end
                end
            end
        end
    end
    -- Older flight map: by name, in the client's language.
    if not any and type(NumTaxiNodes) == "function" and type(TaxiNodeName) == "function"
        and type(TaxiNodeGetType) == "function" then
        local byName = {}
        for id in pairs(data.nodes) do
            local name = Route.NodeName(id)
            if name then
                byName[name] = byName[name] or {}
                table.insert(byName[name], id)
            end
        end
        for slot = 1, Try(NumTaxiNodes) or 0 do
            local name, kind = Try(TaxiNodeName, slot), Try(TaxiNodeGetType, slot)
            if type(name) == "string" and LEARNED_TYPE[kind] then
                for _, id in ipairs(byName[name] or {}) do learn(id, kind == "CURRENT") end
            end
        end
    end
    if not any then return false end

    db.flights = type(db.flights) == "table" and db.flights or {}
    db.flightsSeen = type(db.flightsSeen) == "table" and db.flightsSeen or {}
    -- A list with the master the player is standing at is a complete read:
    -- it replaces what was known on that continent. Anything less only adds.
    if here then
        for id in pairs(db.flights) do
            local node = data.nodes[id]
            if not node or continents[node[2]] then db.flights[id] = nil end
        end
        for continent in pairs(continents) do db.flightsSeen[continent] = true end
    end
    for id in pairs(learned) do db.flights[id] = true end
    Route.Reset()
    return true
end
