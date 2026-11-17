local _, ns = ...

-- Points the way to one map position: TomTom's arrow when TomTom is loaded,
-- otherwise the game's own map pin. Only ever removes what it added.
local Nav = {}
ns.Nav = Nav

local state = { key = nil, uid = nil, native = nil }

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
    if state.uid then
        local addon = TomTomAddon()
        if addon then pcall(addon.RemoveWaypoint, addon, state.uid) end
    end
    if state.native and NativePinIsOurs() and type(C_Map.ClearUserWaypoint) == "function" then
        pcall(C_Map.ClearUserWaypoint)
    end
    state.key, state.uid, state.native = nil, nil, nil
    state.failedKey, state.failedAt = nil, nil
end

-- Points at target ({ mapId, x, y } with x, y in 0..1). Returns true when a
-- new waypoint was placed. Asking again for the same place does nothing, so a
-- waypoint the player removed by hand stays removed until the target changes.
function Nav.Set(target, title)
    local key = ("%d:%.4f:%.4f:%s"):format(target.mapId, target.x, target.y, title or "")
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
