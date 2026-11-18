local _, ns = ...
local Try = ns.Try

-- The real way on foot. The route planner works along straight lines; a
-- walking router knows the roads, the cliffs and the mountains. When another
-- addon has one loaded, DropOff asks it for the walks of the trip the arrow
-- is on, draws the path it answers and counts its real yards. Without one,
-- every walk stays a straight line and says so.
--
-- The router is Polestar's (the addon Polestar_Nav, which Polestar loads at
-- login): it hands itself over as the global Polestar_NavEngine. DropOff
-- holds none of its code or maps and never loads it: it calls what is there,
-- at run time, and checks every function before calling it.
--
--   engine.Find(continent, from, to, callback, opts) -> a handle
--       from, to: { x, y } in the game's world yards
--       callback(points, cost, job): points { { x, y }, ... } from start to
--       goal, or nil with the reason in `cost`; job.yards: the path's length
--   engine.Cancel(handle)
--   engine.Available(continent), engine.Resident(continent): can it search
--       there, and are that continent's maps already in memory
local Walk = {}
ns.Walk = Walk

local STRAY = 25            -- yards off the path: ask for a new one
local KEEP = 150            -- yards off the path: it is not drawn any more
local ASK_EVERY = 5         -- seconds between two asks for the same place
local FAIL_RETRY = 15       -- a walk the router found no way for is asked again this late,
local FAIL_MOVED = 25       -- and only from this many yards further
local ERROR_RETRY = 30      -- seconds before asking again after an error or no answer
local GIVE_UP = 90          -- seconds without an answer
local AIM_AHEAD = 80        -- yards along the path: the arrow points at the first turn past this
local REACH = 5             -- yards: a path ending this close to the goal has reached it
local KEPT = 8              -- paths remembered
local ANSWERS_KEPT = 4      -- answers kept for the debug snapshot

-- The router's reasons that are answers, not failures: no way from there.
local NO_WAY = { unreachable = true, offmesh = true, outside = true }

local paths = {}            -- by goal: { key, continent, x, y, points, rest, id, reason, askedAt (when it was answered), from, used }
local pending               -- the one search under way: { key, handle, at, continent, from, to }
local pathId = 0            -- every path drawn has its own number
local counts = { asked = 0, answered = 0 }
local answers = {}          -- the last answers, newest first, for the debug snapshot
local held                  -- why the last walk was not asked for: "combat", "nodata", "elsewhere"

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

local function Engine()
    local engine = rawget(_G, "Polestar_NavEngine")
    if type(engine) == "table" and type(engine.Find) == "function" and type(engine.Cancel) == "function" then
        return engine
    end
    return nil
end

-- What the router says of a continent: true, false, or nil when it has no
-- such question.
local function Says(engine, question, continent)
    if type(engine[question]) ~= "function" then return nil end
    local ok, answer = pcall(engine[question], continent)
    return ok and answer and true or false
end

-- May a walk on `continent` be asked for now? The router keeps one
-- continent's maps in memory, the one its own addon is walking on: a walk on
-- the other one waits until the player is there.
local function CanSearch(engine, continent, playerContinent)
    if Says(engine, "Available", continent) == false then return false, "nodata" end
    if Says(engine, "Resident", continent) == false and continent ~= playerContinent then
        return false, "elsewhere"
    end
    if InCombat() then return false, "combat" end
    return true
end

-- Priced for the character's faction: the router keeps out of the other
-- side's towns.
local function Options()
    local group = type(UnitFactionGroup) == "function" and Try(UnitFactionGroup, "player")
    if group == "Horde" or group == "Alliance" then return { profile = group } end
    return nil
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

-- The router's points as ours, ending at the goal. Nil when they are no path.
local function Clean(points, goal)
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
    if #list < 2 then return nil end
    if Yards(list[#list], goal) > REACH then
        list[#list + 1] = { continent = goal.continent, x = goal.x, y = goal.y }
    end
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

-- Where `from` is along a path: the index of the point ahead of it, and how
-- far off the path it stands.
local function Along(points, from)
    local ahead, least
    for index = 1, #points - 1 do
        local a, b = points[index], points[index + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local length2 = dx * dx + dy * dy
        local t = length2 > 0 and ((from.x - a.x) * dx + (from.y - a.y) * dy) / length2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local ox, oy = a.x + dx * t - from.x, a.y + dy * t - from.y
        local off = math.sqrt(ox * ox + oy * oy)
        if not least or off < least then ahead, least = index + 1, off end
    end
    return ahead, least
end

-- The path from `from` on: itself, then the points ahead of it. And its yards.
local function Ahead(entry, from, index)
    local points = entry.points
    -- Standing on a turn: the next one is ahead.
    if index < #points and Yards(from, points[index]) < 1 then index = index + 1 end
    local path = { { continent = from.continent, x = from.x, y = from.y } }
    for at = index, #points do path[#path + 1] = points[at] end
    return path, Yards(from, points[index]) + entry.rest[index]
end

local function Remember(answer)
    table.insert(answers, 1, answer)
    answers[ANSWERS_KEPT + 1] = nil
end

-- The router answered the search `job`.
local function Answered(job, points, cost, handle)
    local entry = Entry(job.key, job.to)
    -- The waits before asking again count from the answer: a search takes
    -- seconds, and the player has moved on meanwhile.
    entry.askedAt, entry.from = Now(), job.from
    local list = type(points) == "table" and Clean(points, job.to) or nil
    local answer = {
        continent = job.continent,
        from = { x = job.from.x, y = job.from.y },
        to = { x = job.to.x, y = job.to.y },
        straight = math.floor(Yards(job.from, job.to) + 0.5),
        waited = math.floor((Now() - job.at) * 10 + 0.5) / 10,
    }
    if list then
        pathId = pathId + 1
        entry.points, entry.rest, entry.id, entry.reason = list, Rest(list), pathId, nil
        answer.reason, answer.points = "ok", #list
        answer.drawn = math.floor(entry.rest[1] + 0.5)
        if type(handle) == "table" and type(handle.yards) == "number" then
            answer.real = math.floor(handle.yards + 0.5)
        end
    else
        entry.reason = type(cost) == "string" and cost or (type(points) == "table" and "empty" or "error")
        -- No way from there: the old path is no way either. After an error it stays.
        if NO_WAY[entry.reason] then entry.points, entry.rest, entry.id = nil, nil, nil end
        answer.reason = entry.reason
    end
    counts.answered = counts.answered + 1
    Remember(answer)
    if ns.Log then
        ns.Log("walk: %s, %s yd straight, %s yd real, %.1f s", answer.reason, answer.straight,
            tostring(answer.real or answer.drawn or "?"), answer.waited)
    end
    if ns.IsOpen and ns.IsOpen() and ns.RequestRefresh then ns.RequestRefresh(0) end
end

-- A search that failed on our side of the router: said so, asked again later.
local function Failed(job, reason)
    local entry = Entry(job.key, job.to)
    entry.askedAt, entry.from, entry.reason = Now(), job.from, reason
    Remember({ continent = job.continent, reason = reason, from = job.from, to = job.to,
               straight = math.floor(Yards(job.from, job.to) + 0.5) })
    if ns.Log then ns.Log("walk: %s", reason) end
end

local function Cancel()
    local job = pending
    pending = nil
    if not job then return end
    local engine = Engine()
    if engine and job.handle ~= nil then pcall(engine.Cancel, job.handle) end
end

local function Ask(engine, key, from, to)
    local job = {
        key = key, at = Now(), continent = from.continent,
        from = { continent = from.continent, x = from.x, y = from.y },
        to = { continent = to.continent, x = to.x, y = to.y },
    }
    pending = job
    counts.asked = counts.asked + 1
    local ok, handle = pcall(engine.Find, from.continent, { x = from.x, y = from.y }, { x = to.x, y = to.y },
        function(points, cost, answered)
            -- An answer to a search given up since is not ours any more.
            if pending ~= job then return end
            pending = nil
            local done, err = pcall(Answered, job, points, cost, answered)
            if not done then Failed(job, "error: " .. tostring(err)) end
        end, Options())
    if not ok then
        if pending == job then pending = nil end
        Failed(job, "error: " .. tostring(handle))
    elseif pending == job then
        job.handle = handle
    end
end

-- The path of the walk from `from` to `to`, when there is one: its points
-- from `from` on, its yards and its number. Asks the router for it when it
-- is missing or the player has left it, one search at a time.
local function Find(engine, from, to, playerContinent, wanted)
    local key = Key(to)
    wanted[key] = true
    local entry = paths[key]
    local now = Now()
    local path, yards, ask
    if entry and entry.points then
        local index, off = Along(entry.points, from)
        if off <= KEEP then path, yards = Ahead(entry, from, index) end
        ask = off > STRAY and now - entry.askedAt >= (entry.reason and ERROR_RETRY or ASK_EVERY)
    elseif entry and entry.reason then
        if NO_WAY[entry.reason] then
            ask = now - entry.askedAt >= FAIL_RETRY and Yards(entry.from, from) >= FAIL_MOVED
        else
            ask = now - entry.askedAt >= ERROR_RETRY
        end
    else
        ask = true
    end
    if entry then entry.used = now end
    if ask and not pending then
        local can, why = CanSearch(engine, from.continent, playerContinent)
        if can then Ask(engine, key, from, to) else held = why end
    end
    return path, yards, entry and entry.id
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
        local engine = Engine()
        local speed = ns.Route.WALK_SPEED
        local playerContinent = legs[1].from.continent
        local out, index = {}, 1
        while index <= #legs do
            local leg, last = legs[index], index
            if leg.kind == "walk" then
                while legs[last + 1] and legs[last + 1].kind == "walk" do last = last + 1 end
                local from, to = leg.from, legs[last].to
                local path, yards, id
                if engine and from.continent == to.continent then
                    path, yards, id = Find(engine, from, to, playerContinent, wanted)
                end
                if path then
                    local straight = 0
                    for at = index, last do straight = straight + (legs[at].seconds or 0) end
                    out[#out + 1] = {
                        kind = "walk", from = from, to = to, final = legs[last].final,
                        yards = yards, seconds = yards / speed, path = path, pathId = id, real = true,
                    }
                    if target.eta then target.eta = target.eta - straight + yards / speed end
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
        Failed(job, "timeout")
    end
end

-- The window closed: nothing is asked for any more. The paths are kept.
function Walk.Stop()
    Cancel()
    held = nil
end

-- Where the arrow points on a walk with a real path: the first turn far
-- enough ahead, so the arrow changes at a turn and not at every step. Nil
-- when the walk has no path or its end is the next thing ahead.
function Walk.Aim(leg)
    local path = leg and leg.path
    if type(path) ~= "table" then return nil end
    local walked = 0
    for index = 2, #path - 1 do
        walked = walked + Yards(path[index - 1], path[index])
        if walked >= AIM_AHEAD then return path[index] end
    end
    return nil
end

-- For the debug snapshot: is there a router, what it says of the two
-- continents, and what it answered last.
function Walk.State()
    local engine = Engine()
    local state = {
        engine = engine ~= nil,
        asked = counts.asked, answered = counts.answered,
        held = held,
        answers = {},
    }
    for index, answer in ipairs(answers) do state.answers[index] = answer end
    if engine then
        state.maps = {}
        for continent = 0, 1 do
            state.maps[continent] = {
                available = Says(engine, "Available", continent),
                resident = Says(engine, "Resident", continent),
            }
        end
    end
    if pending then
        state.waiting = {
            continent = pending.continent, from = pending.from, to = pending.to,
            seconds = math.floor(Now() - pending.at + 0.5),
        }
    end
    return state
end
