local _, ns = ...

-- Points the way to one map position: TomTom's arrow when TomTom is loaded,
-- otherwise the game's own map pin. Only ever removes what it added.
local Nav = {}
ns.Nav = Nav

local state = { key = nil, uid = nil, native = nil, endUid = nil }

local function TomTomAddon()
    local addon = rawget(_G, "TomTom")
    if type(addon) == "table" and type(addon.AddWaypoint) == "function"
        and type(addon.RemoveWaypoint) == "function" then
        return addon
    end
    return nil
end

local function NativeAvailable()
    return type(C_Map) == "table" and type(C_Map.SetUserWaypoint) == "function"
        and type(UiMapPoint) == "table" and type(UiMapPoint.CreateFromCoordinates) == "function"
end

-- For the debug snapshot: what is currently placed, if anything.
function Nav.State()
    return {
        mode = Nav.Mode(),
        placed = state.key ~= nil,
        handIn = state.endUid ~= nil,
        via = state.uid and "tomtom" or state.native and "native" or nil,
        key = state.key,
        failedKey = state.failedKey,
    }
end

function Nav.Mode()
    if TomTomAddon() then return "tomtom" end
    if NativeAvailable() then return "native" end
    return "none"
end

-- Is the game's map pin still the one we placed?
local function NativePinIsOurs()
    local ours = state.native
    if not ours or type(C_Map.GetUserWaypoint) ~= "function" then return false end
    local ok, point = pcall(C_Map.GetUserWaypoint)
    if not ok or type(point) ~= "table" or point.uiMapID ~= ours.mapId then return false end
    local position = point.position
    if type(position) ~= "table" then return false end
    return math.abs((position.x or 0) - ours.x) < 0.002 and math.abs((position.y or 0) - ours.y) < 0.002
end

function Nav.Clear()
    local addon = (state.uid or state.endUid) and TomTomAddon()
    if addon then
        if state.uid then pcall(addon.RemoveWaypoint, addon, state.uid) end
        if state.endUid then pcall(addon.RemoveWaypoint, addon, state.endUid) end
    end
    if state.native and NativePinIsOurs() and type(C_Map.ClearUserWaypoint) == "function" then
        pcall(C_Map.ClearUserWaypoint)
    end
    state.key, state.uid, state.native, state.endUid = nil, nil, nil, nil
    state.failedKey, state.failedAt = nil, nil
end

-- Points at target ({ mapId, x, y } with x, y in 0..1). Returns true when a
-- new waypoint was placed. Asking again for the same place does nothing, so a
-- waypoint the player removed by hand stays removed until the target changes.
-- When the target is only a stop on the way (a flight master, a dock),
-- `handIn` and `handInTitle` say where the trip ends: with TomTom that place
-- keeps its own pin on the map, without the arrow.
function Nav.Set(target, title, handIn, handInTitle)
    local key = ("%d:%.4f:%.4f:%s"):format(target.mapId, target.x, target.y, title or "")
    if handIn then
        key = key .. ("|%d:%.4f:%.4f"):format(handIn.mapId, handIn.x, handIn.y)
    end
    if state.key == key then return false end
    -- A place nothing could point at is retried every 10 s, not every tick.
    local now = type(GetTime) == "function" and GetTime() or 0
    if state.failedKey == key and now - (state.failedAt or 0) < 10 then return false end
    Nav.Clear()
    state.failedKey, state.failedAt = key, now

    local addon = TomTomAddon()
    if addon then
        local ok, uid = pcall(addon.AddWaypoint, addon, target.mapId, target.x, target.y, {
            title = title,
            from = "DropOff",
            persistent = false,
            minimap = true,
            world = true,
            crazy = true,
            silent = true,
            cleardistance = 0,  -- keep the arrow until the quest is handed in
        })
        if ok and type(uid) == "table" then
            state.key, state.uid = key, uid
            if handIn then
                local okEnd, endUid = pcall(addon.AddWaypoint, addon, handIn.mapId, handIn.x, handIn.y, {
                    title = handInTitle,
                    from = "DropOff",
                    persistent = false,
                    minimap = false,
                    world = true,
                    crazy = false,
                    silent = true,
                    cleardistance = 0,
                })
                if okEnd and type(endUid) == "table" then state.endUid = endUid end
            end
            return true
        end
        ns.Log("TomTom waypoint failed: %s", tostring(uid))
    end

    if NativeAvailable() then
        local ok, err = pcall(function()
            if type(C_Map.CanSetUserWaypointOnMap) == "function"
                and not C_Map.CanSetUserWaypointOnMap(target.mapId) then
                error("map does not accept waypoints")
            end
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(target.mapId, target.x, target.y))
            if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if ok then
            state.key = key
            state.native = { mapId = target.mapId, x = target.x, y = target.y }
            return true
        end
        ns.Log("native waypoint failed: %s", tostring(err))
    end
    return false
end

-- OpenMap (the stitched world map addon) keeps its own view: a zone opened
-- from here can leave the place outside the part of the map on screen. Its
-- public API moves the view. Returns true when the view was sent there.
local function FocusOpenMap(mapId, x, y)
    local api = rawget(_G, "OpenMapAPI")
    if type(api) ~= "table" or api.major ~= 1 then return false end
    if type(api.IsStitched) ~= "function" or type(api.WorldFromMap) ~= "function"
        or type(api.ShowWorld) ~= "function" then
        return false
    end
    local ok, moved = pcall(function()
        if not api.IsStitched() then return false end
        local u, v = api.WorldFromMap(mapId, x, y)
        if type(u) ~= "number" or type(v) ~= "number" then return false end
        return api.ShowWorld(u, v) and true or false
    end)
    return ok and moved or false
end

local FOCUS_AFTER = { 0.2, 0.8 }  -- seconds: once the map has settled, then a second try

-- Brings a point of the open map into view. The map sets its own view while
-- it opens, so this waits for it; the second try only runs if the first one
-- found the map not ready.
function Nav.Focus(mapId, x, y)
    if type(x) ~= "number" or type(y) ~= "number" then return end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        FocusOpenMap(mapId, x, y)
        return
    end
    local done = false
    for _, delay in ipairs(FOCUS_AFTER) do
        C_Timer.After(delay, function()
            if not done then done = FocusOpenMap(mapId, x, y) end
        end)
    end
end

local function Open(mapId)
    local map = rawget(_G, "WorldMapFrame")
    local hasPanel = type(map) == "table" and type(map.IsShown) == "function"
    if type(C_Map) == "table" and type(C_Map.OpenWorldMap) == "function"
        and pcall(C_Map.OpenWorldMap, mapId) then
        -- A call that did not throw may still have done nothing (combat).
        if not hasPanel or map:IsShown() then return true end
    end
    -- By hand: show the panel, which the game blocks in combat.
    if not hasPanel or type(map.SetMapID) ~= "function" then return false end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return false end
    local show = rawget(_G, "ShowUIPanel")
    local shown = pcall(function()
        if type(show) == "function" then show(map) else map:Show() end
    end)
    -- A panel that opened on the wrong zone is still an open map.
    if shown then pcall(map.SetMapID, map, mapId) end
    return shown
end

-- Opens the world map on a zone, with the point x, y (0..1) in view when
-- given. Returns true when the map was opened.
function Nav.OpenMap(mapId, x, y)
    local opened = Open(mapId)
    if opened then Nav.Focus(mapId, x, y) end
    return opened
end
