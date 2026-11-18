local _, ns = ...

-- Draws the route on the world map and the minimap as a dotted line, with a
-- marker at each change of transport and at the hand-in. Uses the pin library
-- that Questie and TomTom load (HereBeDragons-Pins), never embedded here; with
-- neither loaded nothing is drawn.
local Trail = {}
ns.Trail = Trail

local REF = "DropOffTrail"
local SHOW_EVERYWHERE = 3       -- zone, continent and world maps
local DOT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"   -- a plain disc
local ICON_HAND_IN = "Interface\\GossipFrame\\ActiveQuestIcon"

local SPACING = { walk = 40, fly = 120 }    -- yards between dots
local RIDE_SPACING = 150
local MAX_DOTS = 300
local MINIMAP_REACH = 600       -- yards of walking drawn on the minimap, from the player
local REDRAW_YARDS = 60         -- the player moved this far: lay the first stretch again
local NEAR_PLAYER = 15          -- no dots this close to the player

local COLOUR = {
    walk = { 1, 0.82, 0 },
    fly = { 0.45, 0.8, 1 },
    ride = { 1, 0.45, 0.3 },
}

local drawn             -- signature of what is on the maps now
local pools = { world = {}, minimap = {} }
local used = { world = 0, minimap = 0 }

local function Pins()
    local stub = rawget(_G, "LibStub")
    if not stub then return nil end
    local ok, lib = pcall(stub, "HereBeDragons-Pins-2.0", true)
    if ok and type(lib) == "table" and lib.AddWorldMapIconWorld and lib.AddMinimapIconWorld
        and lib.RemoveAllWorldMapIcons and lib.RemoveAllMinimapIcons then
        return lib
    end
    return nil
end

local function Dot(kind)
    used[kind] = used[kind] + 1
    local dot = pools[kind][used[kind]]
    if not dot then
        dot = CreateFrame("Frame", nil, UIParent)
        dot.texture = dot:CreateTexture(nil, "OVERLAY")
        dot.texture:SetAllPoints(dot)
        if dot.EnableMouse then dot:EnableMouse(false) end
        dot:Hide()   -- the pin library shows it once it is placed
        pools[kind][used[kind]] = dot
    end
    return dot
end

local function Style(dot, size, colour, texture)
    dot:SetSize(size, size)
    dot.texture:SetTexture(texture or DOT_TEXTURE)
    if colour then
        dot.texture:SetVertexColor(colour[1], colour[2], colour[3], 1)
    else
        dot.texture:SetVertexColor(1, 1, 1, 1)
    end
end

function Trail.Clear()
    if not drawn then return end
    drawn = nil
    local pins = Pins()
    if pins then
        pcall(pins.RemoveAllWorldMapIcons, pins, REF)
        pcall(pins.RemoveAllMinimapIcons, pins, REF)
    end
    for _, kind in ipairs({ "world", "minimap" }) do
        for index = 1, used[kind] do pools[kind][index]:Hide() end
        used[kind] = 0
    end
end

-- What the drawing depends on: the legs, and roughly where the player is.
local function Signature(legs)
    local parts = {}
    for index, leg in ipairs(legs) do
        local from = leg.from
        local step = index == 1 and REDRAW_YARDS or 1
        parts[#parts + 1] = ("%s:%d:%d:%d>%d:%d:%d"):format(leg.kind,
            from.continent, math.floor(from.x / step), math.floor(from.y / step),
            leg.to.continent, math.floor(leg.to.x), math.floor(leg.to.y))
    end
    return table.concat(parts, "|")
end

-- The pin library takes HereBeDragons coordinates: the game's axes swapped.
local function OnWorldMap(pins, dot, point)
    return pcall(pins.AddWorldMapIconWorld, pins, REF, dot, point.continent, point.y, point.x, SHOW_EVERYWHERE)
end

local function OnMinimap(pins, dot, point, floatOnEdge)
    return pcall(pins.AddMinimapIconWorld, pins, REF, dot, point.continent, point.y, point.x, floatOnEdge)
end

-- Draws `legs` (from Route.To). Calling it again with the same route and the
-- player in about the same place changes nothing.
function Trail.Show(legs)
    if type(legs) ~= "table" or #legs == 0 then
        Trail.Clear()
        return
    end
    local signature = Signature(legs)
    if signature == drawn then return end
    Trail.Clear()
    local pins = Pins()
    if not pins or type(CreateFrame) ~= "function" then return end
    drawn = signature

    -- Spread the dot budget: long trips get wider gaps.
    local wanted = 0
    for _, leg in ipairs(legs) do
        if leg.from.continent == leg.to.continent then
            local dx, dy = leg.to.x - leg.from.x, leg.to.y - leg.from.y
            wanted = wanted + math.sqrt(dx * dx + dy * dy) / (SPACING[leg.kind] or RIDE_SPACING)
        end
    end
    local stretch = math.max(1, wanted / MAX_DOTS)

    for index, leg in ipairs(legs) do
        local from, to = leg.from, leg.to
        local colour = COLOUR[leg.kind] or COLOUR.ride
        if from.continent == to.continent then
            local dx, dy = from.x - to.x, from.y - to.y
            local length = math.sqrt(dx * dx + dy * dy)
            local gap = (SPACING[leg.kind] or RIDE_SPACING) * stretch
            -- From the far end back toward the start, so the dots stay put
            -- while the player walks along them.
            local skip = index == 1 and NEAR_PLAYER or 0
            local at = gap
            while at < length - skip do
                local point = { continent = to.continent, x = to.x + dx * at / length, y = to.y + dy * at / length }
                local dot = Dot("world")
                Style(dot, leg.kind == "walk" and 5 or 4, colour)
                OnWorldMap(pins, dot, point)
                if leg.kind == "walk" and index == 1 and length - at < MINIMAP_REACH then
                    local small = Dot("minimap")
                    Style(small, 5, colour)
                    OnMinimap(pins, small, point, false)
                end
                at = at + gap
            end
        end

        -- A marker where this leg ends: the hand-in, or a change of transport.
        local marker = Dot("world")
        if leg.final then
            Style(marker, 16, nil, ICON_HAND_IN)
        else
            Style(marker, 9, colour)
        end
        OnWorldMap(pins, marker, to)
        if index == 1 and ns.Nav.Mode() ~= "tomtom" then
            -- Without TomTom's own minimap icon: ours, kept on the rim when far.
            local rim = Dot("minimap")
            if leg.final then Style(rim, 14, nil, ICON_HAND_IN) else Style(rim, 9, colour) end
            OnMinimap(pins, rim, to, true)
        end
    end
end

-- For the debug snapshot and the tests.
function Trail.State()
    return { drawn = drawn ~= nil, world = used.world, minimap = used.minimap }
end
