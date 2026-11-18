local _, ns = ...

-- Draws the route: a line on the world map, dots on the minimap, and a marker
-- at each change of transport and at the hand-in. The dots and markers use
-- the pin library that Questie and TomTom load (HereBeDragons-Pins), never
-- embedded here. The line is drawn on the world map's canvas itself: on
-- OpenMap's stitched map through its API, on Blizzard's own through the
-- coordinates of the map it shows. The world map keeps its dots under the
-- line, so the trip still shows where the line cannot be drawn.
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

local LINE_PX = 4               -- width of the line on screen
local LINE_ALPHA = 0.9

local COLOUR = {
    walk = { 1, 0.82, 0 },
    fly = { 0.45, 0.8, 1 },
    ride = { 1, 0.45, 0.3 },
}

local drawn             -- signature of what is on the maps now
local pools = { world = {}, minimap = {} }
local used = { world = 0, minimap = 0 }

local overlay                   -- a frame over the world map's canvas, holding the lines
local segments, usedSegments = {}, 0   -- { line, from, to }: one per stretch on one continent
local lineState = {}            -- how the last layout went, for the debug snapshot

-- The world map and its canvas, when there is one to draw on.
local function Canvas()
    local map = rawget(_G, "WorldMapFrame")
    if type(map) ~= "table" or type(map.GetCanvas) ~= "function" then return nil end
    local ok, canvas = pcall(map.GetCanvas, map)
    if not ok or type(canvas) ~= "table" then return nil end
    return map, canvas
end

-- A world point on the canvas: x, y with 0..1 the map it shows, and beyond.
-- Nil when the point cannot be placed on what the map shows.
local function OnCanvas(map, point)
    local api = rawget(_G, "OpenMapAPI")
    if type(api) == "table" and type(api.CanvasFromWorldPos) == "function" then
        local ok, x, y = pcall(api.CanvasFromWorldPos, point.continent, point.x, point.y)
        if ok and type(x) == "number" and type(y) == "number" then return x, y end
    end
    local ok, mapId = pcall(map.GetMapID, map)
    if not ok then return nil end
    return ns.Geo.OnShownMap(mapId, point.continent, point.x, point.y)
end

-- The frame level for the lines: over the map's art, under the pins OpenMap
-- lifts above it.
local function Level(map, canvas)
    local level = canvas:GetFrameLevel()
    level = type(level) == "number" and level + 1 or 1
    if type(map.GetPinFrameLevelsManager) == "function" then
        local ok, manager = pcall(map.GetPinFrameLevelsManager, map)
        if ok and type(manager) == "table" and type(manager.GetValidFrameLevel) == "function" then
            local found, pinLevel = pcall(manager.GetValidFrameLevel, manager, "PIN_FRAME_LEVEL_AREA_POI")
            if found and type(pinLevel) == "number" then level = math.max(level, pinLevel) end
        end
    end
    local api = rawget(_G, "OpenMapAPI")
    if type(api) == "table" and type(api.ArtTopLevel) == "function" then
        local ok, top = pcall(api.ArtTopLevel)
        if ok and type(top) == "number" then level = math.max(level, top + 1) end
    end
    return level
end

-- Puts every line where the map now shows its two ends, and hides those the
-- map cannot place. Runs while the world map is open: the map under the
-- canvas changes as the player moves around it.
local function Place()
    local map, canvas = Canvas()
    if not map or not overlay or usedSegments == 0 then return end
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then return end
    -- The canvas grows with the zoom: the line keeps its width on screen.
    local scale = 1
    local mine = canvas:GetEffectiveScale()
    local base = type(UIParent) == "table" and UIParent:GetEffectiveScale()
    if type(mine) == "number" and type(base) == "number" and mine > 0 and base > 0 then scale = mine / base end
    local thickness = LINE_PX / scale

    local level = Level(map, canvas)
    if level ~= overlay.level then
        overlay:SetFrameLevel(level)
        overlay.level = level
    end

    local shown = 0
    for index = 1, usedSegments do
        local segment = segments[index]
        local x1, y1 = OnCanvas(map, segment.from)
        local x2, y2 = OnCanvas(map, segment.to)
        if x1 and x2 then
            x1, y1, x2, y2 = x1 * width, -y1 * height, x2 * width, -y2 * height
            if x1 ~= segment.x1 or y1 ~= segment.y1 or x2 ~= segment.x2 or y2 ~= segment.y2
                or thickness ~= segment.thickness then
                segment.line:SetStartPoint("TOPLEFT", overlay, x1, y1)
                segment.line:SetEndPoint("TOPLEFT", overlay, x2, y2)
                segment.line:SetThickness(thickness)
                segment.x1, segment.y1, segment.x2, segment.y2, segment.thickness = x1, y1, x2, y2, thickness
            end
            segment.line:Show()
            shown = shown + 1
        else
            segment.line:Hide()
        end
    end
    lineState.shown, lineState.level, lineState.scale = shown, level, scale
    lineState.width, lineState.height = width, height
end

-- Never lets a drawing error reach the player: the lines go, the dots stay.
function Trail.Layout()
    if lineState.error then return end
    local ok, err = pcall(Place)
    if not ok then
        lineState.error = tostring(err)
        for index = 1, usedSegments do pcall(segments[index].line.Hide, segments[index].line) end
        if ns.Log then ns.Log("trail line: %s", lineState.error) end
    end
end

local function Overlay()
    if overlay then return overlay end
    local _, canvas = Canvas()
    if not canvas or type(CreateFrame) ~= "function" then return nil end
    local ok, frame = pcall(CreateFrame, "Frame", nil, canvas)
    if not ok or type(frame) ~= "table" or type(frame.CreateLine) ~= "function" then return nil end
    frame:SetAllPoints(canvas)
    if frame.EnableMouse then frame:EnableMouse(false) end
    frame:SetScript("OnUpdate", Trail.Layout)
    overlay = frame
    return overlay
end

-- One stretch of the trip as a line, placed by the next layout.
local function Segment(from, to, colour)
    local frame = Overlay()
    if not frame or lineState.error then return end
    local segment = segments[usedSegments + 1]
    if not segment then
        local ok, line = pcall(frame.CreateLine, frame, nil, "ARTWORK")
        if not ok or type(line) ~= "table" then return end
        segment = { line = line }
        segments[usedSegments + 1] = segment
    end
    usedSegments = usedSegments + 1
    segment.from, segment.to, segment.x1 = from, to, nil
    segment.line:SetColorTexture(colour[1], colour[2], colour[3], LINE_ALPHA)
    segment.line:Hide()
end

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
    for index = 1, usedSegments do segments[index].line:Hide() end
    usedSegments = 0
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
    if type(CreateFrame) ~= "function" then return end

    -- The line: one stretch per leg that stays on one continent.
    for _, leg in ipairs(legs) do
        if leg.from.continent == leg.to.continent then
            Segment(leg.from, leg.to, COLOUR[leg.kind] or COLOUR.ride)
        end
    end
    Trail.Layout()

    local pins = Pins()
    if not pins then
        drawn = usedSegments > 0 and signature or nil
        return
    end
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
    return { drawn = drawn ~= nil, world = used.world, minimap = used.minimap,
             lines = usedSegments, line = lineState }
end
