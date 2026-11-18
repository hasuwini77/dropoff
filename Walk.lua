local _, ns = ...
local Try = ns.Try

-- The real way on foot. The route planner works along straight lines; the
-- walking router knows the roads, the cliffs and the mountains. DropOff asks
-- it for the walks of the trip the arrow is on, draws the path it answers
-- and counts its real yards. A walk it has no path for stays a straight line
-- and says so.
--
-- The router and its maps are Shortest Path Forever's (GPL-3.0-or-later, see
-- LICENSES/ShortestPathForever.txt): the files of Router/, loaded with the
-- addon, and one map addon per continent (DropOff_Paths_*), loaded on demand
-- at the first walk there. Find below is the only place that calls it.
--
--   router.Find(continent, from, to, callback) -> a handle
--       from, to: { x, y, z } in the game's world yards. z is optional: it
--       picks the floor where two lie over each other.
--       callback(points, cost): points { { x, y }, ... } from start to goal,
--       or nil with the reason in `cost`
--   router.Cancel(handle), router.HasData(continent), router.ClearCaches()
--
-- A lift is not in the maps: its two ends are not joined. After the direct
-- answer, the lifts that could make the walk shorter are tried, each one
-- entered at the top and at the bottom, and the shortest way is kept.
local Walk = {}
ns.Walk = Walk

local OFF_PATH = 30         -- yards from the path at which the player has left it: a new one is wanted
local KEEP = 150            -- yards from the path beyond which it is not drawn any more
local SEARCH_GAP = 5        -- seconds after an answer before the same walk is searched again
local NO_WAY_WAIT = 20      -- "no way on foot" is asked again after this many seconds,
local NO_WAY_MOVED = 30     -- and only once the player is this many yards from where it was asked
local ERROR_RETRY = 30      -- seconds before asking again after an error or no answer
local GIVE_UP = 90          -- seconds without an answer
local AIM_AHEAD = 80        -- yards along the path: the arrow points at the first turn past this
local REACH = 5             -- yards: a path ending this close to the goal has reached it
local KEPT = 8              -- paths remembered
local ANSWERS_KEPT = 4      -- answers kept for the debug snapshot
local LIFT_SECONDS = 20     -- a lift: the wait for it and the ride
local LIFTS_TRIED = 2       -- lifts tried for one walk, the likeliest first
local LIFT_NEAR = 15        -- yards: this close to a lift, the player has reached it
local LOAD_RETRY = 60       -- seconds before maps that did not load are asked for again
local SPAWN_REACH = 8       -- yards round a place in which a spawn gives it its height
local CACHE_KB = 8192       -- the router's memory for decoded maps (its own default is 24 MB)

-- The addon holding the walking maps of each continent.
local MAPS = {
    [0] = "DropOff_Paths_EasternKingdoms",
    [1] = "DropOff_Paths_Kalimdor",
    [2991] = "DropOff_Paths_Zephras",
}

-- A city under another place: the height of its floor, by the map the player
-- is on. Standing there, the walk starts in the city and not on what lies
-- over it (the Undercity under the Ruins of Lordaeron).
local FLOORS = { [1458] = -43.1 }

-- The router's reasons that are answers, not failures: no way from there.
local NO_WAY = { unreachable = true, offmesh = true, outside = true }

local paths = {}            -- by goal: { key, continent, x, y, points, rest, id, lift, start, reason, askedAt (when it was answered), from, used }
local pending               -- the one search under way: { key, at, continent, from, to, router, handle, token, best { points, yards, cost, lift }, reason, tries, searches }
local pathId = 0            -- every path drawn has its own number
local counts = { asked = 0, answered = 0 }
local answers = {}          -- the last answers, newest first, for the debug snapshot
local held                  -- why the last walk was not asked for: "combat", "nodata"
local loads = {}            -- by continent: how loading its maps went { addon, at, tries, loaded, reason, ms }

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

local function Yards(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function InCombat()
    return type(InCombatLockdown) == "function" and Try(InCombatLockdown) == true
end

---------------------------------------------------------------------------
-- The router
---------------------------------------------------------------------------

local function Router()
    local router = ns.Path
    if type(router) == "table" and type(router.Find) == "function" and type(router.Cancel) == "function"
        and type(router.HasData) == "function" then
        return router
    end
    return nil
end

-- The one call into the router. Nothing goes in after the callback: its
-- fifth argument means "this character walks on water".
local function Find(router, continent, from, to, callback)
    return router.Find(continent, from, to, callback)
end

local function HasMaps(router, continent)
    local ok, has = pcall(router.HasData, continent)
    return ok and has and true or false
end

-- Are the walking maps of `continent` in memory? The first walk there loads
-- their addon, out of combat: reading them takes a moment. Maps that did not
-- load (the addon is disabled, or the game was not restarted since it was
-- installed) are asked for again later, not at every tick.
local function Maps(router, continent)
    if HasMaps(router, continent) then return true end
    local addon = MAPS[continent]
    if not addon then return false, "nodata" end
    local last = loads[continent]
    if last and Now() - last.at < LOAD_RETRY then return false, "nodata" end
    if InCombat() then return false, "combat" end
    local state = { addon = addon, at = Now(), tries = (last and last.tries or 0) + 1 }
    loads[continent] = state
    local load = type(C_AddOns) == "table" and C_AddOns.LoadAddOn or rawget(_G, "LoadAddOn")
    if type(load) ~= "function" then
        state.loaded, state.reason = false, "no LoadAddOn"
        return false, "nodata"
    end
    local clock = type(debugprofilestop) == "function" and debugprofilestop
    local before = clock and clock()
    local called, loaded, reason = pcall(load, addon)
    if clock then state.ms = math.floor(clock() - before + 0.5) end
    state.loaded = HasMaps(router, continent)
    if not state.loaded then
        state.reason = not called and ("error: " .. tostring(loaded))
            or not loaded and tostring(reason or "not loaded")
            or "loaded without maps"
    end
    if ns.Log then ns.Log("walk: maps %s: %s", addon, state.loaded and "loaded" or state.reason) end
    return state.loaded, "nodata"
end

-- The height of the spawn (an NPC, a quest object) at a place, when it
-- stands over or under another floor: a hand-in inside a mine and not on the
-- hill over it. After Shortest Path Forever's ns.SpawnHeight. Nil for a
-- place with one floor, or while the continent's maps are not in memory.
local function SpawnHeight(continent, x, y)
    local heights = type(ns.SpawnHeights) == "table" and ns.SpawnHeights[continent]
    local grid = ns.PathGrid
    if type(heights) ~= "table" or type(grid) ~= "table" then return nil end
    if type(grid.State) ~= "function" or type(grid.locate) ~= "function" then return nil end
    local ok, height = pcall(function()
        local st = grid.State(continent)
        if not st then return nil end
        local best, gap, seen = nil, SPAWN_REACH * SPAWN_REACH, {}
        for _, dx in ipairs({ -SPAWN_REACH, SPAWN_REACH }) do
            for _, dy in ipairs({ -SPAWN_REACH, SPAWN_REACH }) do
                local k = grid.locate(st, x + dx, y + dy)
                if k and not seen[k] then
                    seen[k] = true
                    for sx, sy, sz in (heights[k + 1] or ""):gmatch("(%S+) (%S+) (%S+)") do
                        local d = (tonumber(sx) - x) ^ 2 + (tonumber(sy) - y) ^ 2
                        if d <= gap then best, gap = tonumber(sz), d end
                    end
                end
            end
        end
        return best
    end)
    return ok and height or nil
end

-- A place as the router takes it. The player has no height the game tells:
-- only the floor of a city under another place is known.
local function Spot(place, isPlayer)
    local z
    if isPlayer then
        z = FLOORS[ns.Geo and ns.Geo.PlayerZone and ns.Geo.PlayerZone() or false]
    else
        z = SpawnHeight(place.continent, place.x, place.y)
    end
    return { continent = place.continent, x = place.x, y = place.y, z = z }
end

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

local function Key(place)
    return ("%d:%d:%d"):format(place.continent, math.floor(place.x + 0.5), math.floor(place.y + 0.5))
end

-- The entry of a goal, made when missing. The oldest one goes when there are
-- too many.
local function Entry(key, goal)
    local entry = paths[key]
    if entry then return entry end
    local count, oldest = 0, nil
    for _, other in pairs(paths) do
        count = count + 1
        if not oldest or other.used < oldest.used then oldest = other end
    end
    if count >= KEPT and oldest then paths[oldest.key] = nil end
    entry = { key = key, continent = goal.continent, x = goal.x, y = goal.y, used = Now() }
    paths[key] = entry
    return entry
end

-- The router's points as ours, ending at the goal. Nil when they are no
-- path: fewer than `least` points (2, or 1 for a walk that starts at its goal).
local function Clean(points, goal, least)
    if type(points) ~= "table" then return nil end
    local list = {}
    for index = 1, #points do
        local point = points[index]
        if type(point) == "table" and type(point.x) == "number" and type(point.y) == "number" then
            local last = list[#list]
            if not last or Yards(last, point) >= 0.5 then
                list[#list + 1] = { continent = goal.continent, x = point.x, y = point.y }
            end
        end
    end
    if #list == 0 then return nil end
    if Yards(list[#list], goal) > REACH then
        list[#list + 1] = { continent = goal.continent, x = goal.x, y = goal.y }
    end
    if #list < (least or 2) then return nil end
    return list
end

-- rest[i]: the yards from point i to the end of the path.
local function Rest(points)
    local rest = { [#points] = 0 }
    for index = #points - 1, 1, -1 do
        rest[index] = rest[index + 1] + Yards(points[index], points[index + 1])
    end
    return rest
end

local function Length(points)
    return Rest(points)[1]
end

-- Where `from` is along a path, between its points `first` and `last`: the
-- index of the point ahead of it, and how far off the path it stands.
local function Along(points, from, first, last)
    local ahead, least = first, Yards(from, points[first])
    for index = first, last - 1 do
        local a, b = points[index], points[index + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local length2 = dx * dx + dy * dy
        local t = length2 > 0 and ((from.x - a.x) * dx + (from.y - a.y) * dy) / length2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local ox, oy = a.x + dx * t - from.x, a.y + dy * t - from.y
        local off = math.sqrt(ox * ox + oy * oy)
        if index == first or off < least then ahead, least = index + 1, off end
    end
    return ahead, least
end

-- The path from `from` on: itself, then the points ahead of it. And its
-- yards, and where the lift still ahead is in it.
local function Ahead(entry, from, index)
    local points = entry.points
    -- Standing on a turn: the next one is ahead.
    if index < #points and index ~= entry.lift and Yards(from, points[index]) < 1 then index = index + 1 end
    local path = { { continent = from.continent, x = from.x, y = from.y } }
    for at = index, #points do path[#path + 1] = points[at] end
    return path, Yards(from, points[index]) + entry.rest[index], entry.lift and entry.lift - index + 2 or nil
end

local function Remember(answer)
    table.insert(answers, 1, answer)
    answers[ANSWERS_KEPT + 1] = nil
end

local function Place(spot)
    return { x = spot.x, y = spot.y, z = spot.z }
end

-- The search `job` is over: its best way, or the reason there is none.
local function Settle(job)
    if pending == job then pending = nil end
    job.token = nil
    local entry = Entry(job.key, job.to)
    -- The waits before asking again count from the answer: a search takes
    -- seconds, and the player has moved on meanwhile.
    entry.askedAt, entry.from = Now(), job.from
    local answer = {
        continent = job.continent,
        from = Place(job.from), to = Place(job.to),
        straight = math.floor(Yards(job.from, job.to) + 0.5),
        waited = math.floor((Now() - job.at) * 10 + 0.5) / 10,
        searches = job.searches,
        direct = job.direct,
    }
    local best = job.best
    if best then
        pathId = pathId + 1
        entry.points, entry.rest, entry.id, entry.reason = best.points, Rest(best.points), pathId, nil
        entry.lift, entry.start = best.lift, nil
        answer.reason, answer.points = "ok", #best.points
        answer.drawn = math.floor(entry.rest[1] + 0.5)
        answer.lift = best.lift and true or nil
    else
        entry.reason = job.reason or "error"
        -- No way from there: the old path is no way either. After an error it stays.
        if NO_WAY[entry.reason] then entry.points, entry.rest, entry.id, entry.lift, entry.start = nil, nil, nil, nil, nil end
        answer.reason = entry.reason
    end
    counts.answered = counts.answered + 1
    Remember(answer)
    if ns.Log then
        ns.Log("walk: %s, %s yd straight, %s yd real, %s searches, %.1f s", answer.reason, answer.straight,
            tostring(answer.drawn or "?"), tostring(answer.searches), answer.waited)
    end
    if ns.IsOpen and ns.IsOpen() and ns.RequestRefresh then ns.RequestRefresh(0) end
end

-- A search that failed on our side of the router: said so, asked again later.
local function Failed(job, reason)
    if pending == job then pending = nil end
    job.token = nil
    if job.handle ~= nil then pcall(job.router.Cancel, job.handle) end
    job.handle = nil
    local entry = Entry(job.key, job.to)
    entry.askedAt, entry.from, entry.reason = Now(), job.from, reason
    Remember({ continent = job.continent, reason = reason, from = Place(job.from), to = Place(job.to),
               straight = math.floor(Yards(job.from, job.to) + 0.5), searches = job.searches })
    if ns.Log then ns.Log("walk: %s", reason) end
end

local function Cancel()
    local job = pending
    pending = nil
    if not job then return end
    job.token = nil
    if job.handle ~= nil then pcall(job.router.Cancel, job.handle) end
    job.handle = nil
end

-- One question of the search `job` to the router. `done(points, reason)`
-- gets the router's points, or nil and why. An answer to a search given up
-- since, or to an earlier question of this one, is dropped.
-- (The router calls back inside its own coroutine: `done` records the answer
-- and asks the next question, nothing more.)
local function Run(job, from, to, done)
    local token = {}
    job.token, job.handle = token, nil
    local ok, handle = pcall(Find, job.router, job.continent, Place(from), Place(to), function(points, cost)
        if pending ~= job or job.token ~= token then return end
        job.handle = nil
        job.searches = job.searches + 1
        local reason = type(cost) == "string" and cost or nil
        local fine, err = pcall(done, type(points) == "table" and points or nil, reason)
        if not fine then Failed(job, "error: " .. tostring(err)) end
    end)
    if not ok then
        if pending == job then Failed(job, "error: " .. tostring(handle)) end
    elseif pending == job and job.token == token then
        job.handle = handle
    end
end

-- What a lift costs, in yards on foot.
local function LiftYards()
    return LIFT_SECONDS * ns.Route.WALK_SPEED
end

-- The lifts that could make the walk of `job` shorter than its best way so
-- far, the likeliest first, each one both ways: in at the top, in at the
-- bottom. A lift is worth a try when the straight lines to it and on from it
-- are shorter than the best way, or when there is no way at all.
local function LiftTries(job)
    local best = job.best and job.best.cost
    local worth = {}
    for _, lift in ipairs(type(ns.TravelLifts) == "table" and ns.TravelLifts or {}) do
        if lift[1] == job.continent then
            local spot = { x = lift[2], y = lift[3] }
            local bound = Yards(job.from, spot) + Yards(spot, job.to) + LiftYards()
            if not best or bound < best then
                worth[#worth + 1] = { bound = bound, x = lift[2], y = lift[3], top = lift[4], bottom = lift[5] }
            end
        end
    end
    table.sort(worth, function(a, b) return a.bound < b.bound end)
    local tries = {}
    for index = 1, math.min(#worth, LIFTS_TRIED) do
        local lift = worth[index]
        tries[#tries + 1] = { x = lift.x, y = lift.y, enter = lift.top, leave = lift.bottom }
        tries[#tries + 1] = { x = lift.x, y = lift.y, enter = lift.bottom, leave = lift.top }
    end
    return tries
end

-- The next lift of the search, or its end. A way through a lift is the path
-- to one end of it and the path from the other; a half with no way, or
-- already longer than the best way, ends the try.
local function NextTry(job)
    local try = table.remove(job.tries, 1)
    if not try then return Settle(job) end
    local spot = { continent = job.continent, x = try.x, y = try.y }
    -- Is a way through this lift, `yards` long at least, no better than the best one?
    local function beaten(yards)
        return job.best and yards + LiftYards() >= job.best.cost
    end
    if beaten(Yards(job.from, spot) + Yards(spot, job.to)) then return NextTry(job) end
    Run(job, job.from, { x = try.x, y = try.y, z = try.enter }, function(points)
        local first = Clean(points, spot, 1)
        if not first then return NextTry(job) end
        local walked = Length(first)
        if beaten(walked + Yards(spot, job.to)) then return NextTry(job) end
        Run(job, { x = try.x, y = try.y, z = try.leave }, job.to, function(more)
            local second = Clean(more, job.to, 1)
            if second and not beaten(walked + Length(second)) then
                local joined = {}
                for index = 1, #first do joined[index] = first[index] end
                for index = 1, #second do
                    -- The far end of the lift is the same spot on the map.
                    if index > 1 or Yards(second[1], first[#first]) >= 0.5 then joined[#joined + 1] = second[index] end
                end
                if #joined >= 2 then
                    local yards = Length(joined)
                    job.best = { points = joined, yards = yards, cost = yards + LiftYards(), lift = #first }
                end
            end
            return NextTry(job)
        end)
    end)
end

-- Asks for the walk from `from` to `to`: straight there first, then the lifts.
local function Ask(router, key, from, to)
    local job = {
        key = key, at = Now(), continent = from.continent, router = router,
        from = from, to = to, searches = 0, tries = {},
    }
    pending = job
    counts.asked = counts.asked + 1
    Run(job, from, to, function(points, reason)
        local list = Clean(points, to)
        if list then
            local yards = Length(list)
            job.best = { points = list, yards = yards, cost = yards }
            job.direct = math.floor(yards + 0.5)
        else
            job.reason = reason or (points and "empty" or "error")
            job.direct = job.reason
        end
        -- With no way straight there a lift may be the way; after an error it is not asked.
        if list or NO_WAY[job.reason] then job.tries = LiftTries(job) end
        NextTry(job)
    end)
end

-- The path of the walk from `from` to `to`, when there is one: its points
-- from `from` on, its yards, its number, and where its lift is. Asks the
-- router for it when it is missing or the player has left it, one search at
-- a time.
local function PathFor(router, from, to, isPlayer, wanted)
    local key = Key(to)
    wanted[key] = true
    local entry = paths[key]
    local now = Now()
    local path, yards, lift, ask
    if entry and entry.points then
        -- A lift the player has reached: what led to it is behind.
        if entry.lift and Yards(from, entry.points[entry.lift]) <= LIFT_NEAR then
            entry.start, entry.lift = entry.lift, nil
        end
        -- Up to the lift only: what is beyond it lies on another floor, and
        -- may pass right under the player.
        local index, off = Along(entry.points, from, entry.start or 1, entry.lift or #entry.points)
        if off <= KEEP then path, yards, lift = Ahead(entry, from, index) end
        ask = off > OFF_PATH and now - entry.askedAt >= (entry.reason and ERROR_RETRY or SEARCH_GAP)
    elseif entry and entry.reason then
        if NO_WAY[entry.reason] then
            ask = now - entry.askedAt >= NO_WAY_WAIT and Yards(entry.from, from) >= NO_WAY_MOVED
        else
            ask = now - entry.askedAt >= ERROR_RETRY
        end
    else
        ask = true
    end
    if entry then entry.used = now end
    if ask and not pending then
        local can, why = Maps(router, from.continent)
        if can then Ask(router, key, Spot(from, isPlayer), Spot(to)) else held = why end
    end
    return path, yards, entry and entry.id, lift
end

---------------------------------------------------------------------------
-- The trip the arrow is on
---------------------------------------------------------------------------

-- Puts the real walks into the trip to `target` (a hand-in of the plan, with
-- its legs from Route.To): each run of walks the router has a path for
-- becomes one walk along it, with its real yards and time, and the walks to
-- the zone borders in between are gone. The others stay straight lines. Asks
-- the router for the paths that are missing. With no target, the search
-- under way is given up.
function Walk.Use(target)
    local legs = target and target.legs
    -- A trip gone through already is as it should be: the search it asked
    -- for goes on.
    if target and target.walked then return end
    local wanted = {}
    held = nil
    if type(legs) == "table" and #legs > 0 then
        target.walked = true
        local router = Router()
        local speed = ns.Route.WALK_SPEED
        local out, index = {}, 1
        while index <= #legs do
            local leg, last = legs[index], index
            if leg.kind == "walk" then
                while legs[last + 1] and legs[last + 1].kind == "walk" do last = last + 1 end
                local from, to = leg.from, legs[last].to
                local path, yards, id, lift
                if router and from.continent == to.continent then
                    -- The trip starts where the player stands.
                    path, yards, id, lift = PathFor(router, from, to, index == 1, wanted)
                end
                if path then
                    local straight = 0
                    for at = index, last do straight = straight + (legs[at].seconds or 0) end
                    local seconds = yards / speed + (lift and LIFT_SECONDS or 0)
                    out[#out + 1] = {
                        kind = "walk", from = from, to = to, final = legs[last].final,
                        yards = yards, seconds = seconds, path = path, pathId = id, real = true, lift = lift,
                    }
                    if target.eta then target.eta = target.eta - straight + seconds end
                else
                    for at = index, last do out[#out + 1] = legs[at] end
                end
            else
                out[#out + 1] = leg
            end
            index = last + 1
        end
        target.legs = out
        -- A trip that is one real walk: its yards, for the list.
        target.walk = #out == 1 and out[1].real and out[1].yards or nil
    end

    local job = pending
    if job and not wanted[job.key] then
        Cancel()
    elseif job and not InCombat() and Now() - job.at > GIVE_UP then
        -- The router holds its searches during a fight: that wait is not counted.
        Cancel()
        -- The way found before the lifts took too long is still a way.
        if job.best then
            Settle(job)
        else
            Failed(job, "timeout")
        end
    end
end

-- The window closed: nothing is asked for any more, and the router lets go
-- of the maps it decoded. The paths are kept.
function Walk.Stop()
    Cancel()
    held = nil
    local router = Router()
    if router and type(router.ClearCaches) == "function" then pcall(router.ClearCaches) end
end

-- Where the arrow points on a walk with a real path: the first turn far
-- enough ahead, so the arrow changes at a turn and not at every step, and
-- never past a lift: the path beyond it is on another floor. Nil when the
-- walk has no path or its end is the next thing ahead.
function Walk.Aim(leg)
    local path = leg and leg.path
    if type(path) ~= "table" then return nil end
    local walked = 0
    for index = 2, #path - 1 do
        walked = walked + Yards(path[index - 1], path[index])
        if walked >= AIM_AHEAD or index == leg.lift then return path[index] end
    end
    return nil
end

-- For the debug snapshot: is the router there, are the maps of each
-- continent in memory and how did loading them go, and what it answered last.
function Walk.State()
    local router = Router()
    local state = {
        router = router ~= nil,
        asked = counts.asked, answered = counts.answered,
        held = held,
        answers = {},
        maps = {},
    }
    for index, answer in ipairs(answers) do state.answers[index] = answer end
    -- Each map addon: does the game know it, may it be loaded, and what
    -- happened when it was asked for.
    local info = type(C_AddOns) == "table" and C_AddOns.GetAddOnInfo
    for continent, addon in pairs(MAPS) do
        local map = { addon = addon, inMemory = router and HasMaps(router, continent) or false }
        if type(info) == "function" then
            local ok, name, _, _, loadable, reason = pcall(info, addon)
            map.known = ok and name ~= nil
            map.loadable = ok and loadable and true or false
            map.why = ok and reason or nil
        end
        local load = loads[continent]
        if load then map.tries, map.loaded, map.reason, map.ms = load.tries, load.loaded, load.reason, load.ms end
        state.maps[continent] = map
    end
    -- What tells the floor the player stands on (FLOORS).
    state.player = {
        map = ns.Geo and ns.Geo.PlayerZone and ns.Geo.PlayerZone() or nil,
        subzone = type(GetSubZoneText) == "function" and Try(GetSubZoneText) or nil,
        indoors = type(IsIndoors) == "function" and Try(IsIndoors) and true or false,
    }
    if pending then
        state.waiting = {
            continent = pending.continent, from = Place(pending.from), to = Place(pending.to),
            seconds = math.floor(Now() - pending.at + 0.5), searches = pending.searches,
        }
    end
    return state
end

-- The router decodes the maps it walks through and keeps them a while.
do
    local router = Router()
    if router then router.cacheKB = CACHE_KB end
end
