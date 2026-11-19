local _, ns = ...

-- Draws the route: a line on the world map, and a marker at each change of
-- transport and at the hand-in. The line is drawn on the world map's canvas
-- itself: on OpenMap's stitched map through its API, on Blizzard's own
-- through the coordinates of the map it shows. A walk with a real path
-- (Walk.lua) is drawn along it, turn by turn; any other stretch is a straight
-- line between its two ends. The markers use the pin library that Questie
-- and TomTom load (HereBeDragons-Pins), never embedded here. Only a trip
-- whose line cannot be drawn is laid as dots on the world map instead.
--
-- The minimap has the same line, from the player on, placed at every frame
-- with the pin library's own rule (its axes, its view radius, the rotating
-- minimap) and cut at the rim; and the marker of the next stop. No dots: a
-- minimap line that fails leaves the marker, and the world map as it is.
local Trail = {}
ns.Trail = Trail

local REF = "DropOffTrail"
local SHOW_EVERYWHERE = 3       -- zone, continent and world maps
local DOT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"   -- a plain disc
local ICON_HAND_IN = "Interface\\GossipFrame\\ActiveQuestIcon"

local SPACING = { walk = 40, fly = 120 }    -- yards between dots
local RIDE_SPACING = 150
local MAX_DOTS = 300
local REDRAW_YARDS = 60         -- the player moved this far: lay the first stretch again
local NEAR_PLAYER = 15          -- no dots this close to the player

local LINE_PX = 4               -- width of the line on screen
local LINE_ALPHA = 0.9

local MINI_PX = 2.5             -- width of the line on the minimap
local MINI_RIM = 0.9            -- share of the minimap's radius the line stops at: where the pin library keeps its rim markers
local MINI_ARROW = 7            -- the line starts this far from the centre: clear of the player's arrow
local MINI_MAX = 150            -- lines on the minimap at most
local MINI_LOOK = 12            -- turns of the first leg searched for where the player is along it
-- Yards across the minimap at each zoom, for a client without
-- C_Minimap.GetViewRadius.
local MINI_OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local MINI_INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local COLOUR = {
    walk = { 1, 0.82, 0 },
    fly = { 0.45, 0.8, 1 },
    ride = { 1, 0.45, 0.3 },
}

local drawn             -- signature of what is on the maps now
local dotted            -- that trip has no line: it is laid as dots
local laying            -- where the trip being laid, or laid last, ends
local failed            -- where the trip whose line could not be drawn ends
local stale             -- the line failed after the trip was laid: lay it again, as dots
local pools = { world = {}, minimap = {} }
local used = { world = 0, minimap = 0 }

local overlay                   -- a frame over the world map's canvas, holding the lines
local segments, usedSegments = {}, 0   -- { line, from, to }: one per stretch on one continent
local wanted                    -- the stretches to draw as lines: { from, to, colour }
local view                      -- what the last layout was made for; nil: lay out again
local lineState = {}            -- how the last layout went, for the debug snapshot

local mini                      -- a frame over the minimap, holding its lines
local miniLines, miniShown = {}, 0
local miniView = {}             -- what the minimap's lines were last placed for; `set` false: place again
local miniFailed                -- where the trip whose minimap line could not be drawn ends
local miniState = {}            -- how the last placing went, for the debug snapshot
local rim                       -- the marker of the next stop on the minimap, and the point it marks

-- The world map and its canvas, when there is one to draw on.
local function Canvas()
    local map = rawget(_G, "WorldMapFrame")
    if type(map) ~= "table" or type(map.GetCanvas) ~= "function" then return nil end
    local ok, canvas = pcall(map.GetCanvas, map)
    if not ok or type(canvas) ~= "table" then return nil end
    return map, canvas
end

local function ShownMap(map)
    local ok, mapId = pcall(map.GetMapID, map)
    return ok and type(mapId) == "number" and mapId or nil
end

-- A world point on the canvas: x, y with 0..1 the map it shows, and beyond.
-- Nil when the point cannot be placed on what the map shows.
local function OnCanvas(map, point)
    local api = rawget(_G, "OpenMapAPI")
    if type(api) == "table" and type(api.CanvasFromWorldPos) == "function" then
        local ok, x, y = pcall(api.CanvasFromWorldPos, point.continent, point.x, point.y)
        if ok and type(x) == "number" and type(y) == "number" then return x, y end
        -- On its stitched map only OpenMap knows where a point is: one it
        -- cannot place is not drawn, rather than placed by another map's rule.
        if type(api.IsStitched) == "function" then
            local asked, stitched = pcall(api.IsStitched)
            if asked and stitched then return nil end
        end
    end
    return ns.Geo.OnShownMap(ShownMap(map), point.continent, point.x, point.y)
end

-- The frame level for the lines: among the map's pins, and over OpenMap's
-- art, under the pins it lifts above that.
local function Level(map, canvas)
    local level = canvas:GetFrameLevel()
    level = type(level) == "number" and level + 1 or 1
    if type(map.GetPinFrameLevelsManager) == "function" then
        local ok, manager = pcall(map.GetPinFrameLevelsManager, map)
        if ok and type(manager) == "table" and type(manager.GetValidFrameLevel) == "function" then
            local found, pinLevel = pcall(manager.GetValidFrameLevel, manager, "PIN_FRAME_LEVEL_AREA_POI", 1)
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

local function HideLines()
    for index = 1, usedSegments do segments[index].line:Hide() end
    lineState.shown = 0
end

-- Puts every line where the map now shows its two ends, and hides those the
-- map cannot place. Runs while the world map is open, and does the work only
-- when the map, its size, its zoom or the place of the first point changed:
-- the map under the canvas changes as the player moves around it.
local function Place()
    local map, canvas = Canvas()
    if not map or not overlay or usedSegments == 0 then return end
    local width, height = canvas:GetWidth(), canvas:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
        HideLines()
        view = nil
        return
    end
    -- The canvas grows with the zoom: the line keeps its width on screen.
    local scale = 1
    local mine = canvas:GetEffectiveScale()
    local base = type(UIParent) == "table" and UIParent:GetEffectiveScale()
    if type(mine) == "number" and type(base) == "number" and mine > 0 and base > 0 then scale = mine / base end

    local mapId = ShownMap(map)
    local firstX, firstY = OnCanvas(map, segments[1].from)
    if view and view.mapId == mapId and view.width == width and view.height == height
        and view.scale == scale and view.x == firstX and view.y == firstY then
        return
    end
    view = { mapId = mapId, width = width, height = height, scale = scale, x = firstX, y = firstY }

    local level = Level(map, canvas)
    if level ~= overlay.level then
        overlay:SetFrameLevel(level)
        overlay.level = level
    end

    local thickness = LINE_PX / scale
    local shown = 0
    for index = 1, usedSegments do
        local segment = segments[index]
        local x1, y1 = firstX, firstY
        if index > 1 then x1, y1 = OnCanvas(map, segment.from) end
        local x2, y2 = OnCanvas(map, segment.to)
        if x1 and x2 then
            segment.line:SetStartPoint("TOPLEFT", overlay, x1 * width, -y1 * height)
            segment.line:SetEndPoint("TOPLEFT", overlay, x2 * width, -y2 * height)
            segment.line:SetThickness(thickness)
            segment.line:Show()
            shown = shown + 1
        else
            segment.line:Hide()
        end
    end
    lineState.shown, lineState.level, lineState.scale = shown, level, scale
    lineState.width, lineState.height, lineState.mapId = width, height, mapId
end

-- Never lets a drawing error reach the player: the lines go, and the trip
-- is laid again as dots. The next route tries a line again.
function Trail.Layout()
    if lineState.error then return end
    local ok, err = pcall(Place)
    if not ok then
        lineState.error = tostring(err)
        failed, stale = laying, true
        pcall(HideLines)
        if overlay then overlay:Hide() end
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
    frame:Hide()   -- shown while there are lines: its OnUpdate runs only then
    frame:SetScript("OnUpdate", Trail.Layout)
    overlay = frame
    return overlay
end

-- One stretch of the trip as a line, placed by the next layout.
local function Segment(from, to, colour)
    local frame = Overlay()
    if not frame then return end
    local segment = segments[usedSegments + 1]
    if not segment then
        local ok, line = pcall(frame.CreateLine, frame, nil, "ARTWORK")
        if not ok or type(line) ~= "table" then return end
        segment = { line = line }
        segments[usedSegments + 1] = segment
    end
    usedSegments = usedSegments + 1
    segment.from, segment.to = from, to
    segment.line:SetColorTexture(colour[1], colour[2], colour[3], LINE_ALPHA)
    segment.line:Hide()
end

---------------------------------------------------------------------------
-- The line on the minimap
---------------------------------------------------------------------------

local Number = ns.Geo.Number

local function MiniHide(why)
    -- Every line made, not only those counted: a placing may have stopped
    -- half way. Nothing to do when they are hidden already.
    if miniState.shown ~= 0 or miniShown > 0 then
        for _, line in ipairs(miniLines) do line:Hide() end
    end
    miniShown, miniView.set = 0, false
    miniState.shown, miniState.why = 0, why
end

-- Yards from the centre of the minimap to its edge, and where the figure
-- comes from.
local function ViewRadius(minimap)
    local api = rawget(_G, "C_Minimap")
    if type(api) == "table" and type(api.GetViewRadius) == "function" then
        local ok, radius = pcall(api.GetViewRadius)
        if ok and Number(radius) and radius > 0 then return radius, "api" end
    end
    local zoom = minimap:GetZoom()
    local indoors = type(IsIndoors) == "function" and ns.Try(IsIndoors) == true
    local across = Number(zoom) and (indoors and MINI_INDOOR or MINI_OUTDOOR)[zoom]
    if across then return across / 2, indoors and "indoor" or "outdoor" end
    return nil
end

-- The player's facing when the minimap turns with the player, false when it
-- does not turn, nil when it turns and the facing is not known.
local function Turned()
    if type(GetCVar) ~= "function" or ns.Try(GetCVar, "rotateMinimap") ~= "1" then return false end
    local facing = type(GetPlayerFacing) == "function" and ns.Try(GetPlayerFacing)
    return Number(facing) and facing or nil
end

-- The part of the stretch a-b inside the circle of radius `rim` round the
-- centre: its two ends, or nil when it is all outside.
local function Inside(ax, ay, bx, by, rim)
    local dx, dy = bx - ax, by - ay
    local a = dx * dx + dy * dy
    if a <= 0 then return nil end
    local b = 2 * (ax * dx + ay * dy)
    local c = ax * ax + ay * ay - rim * rim
    local disc = b * b - 4 * a * c
    if disc <= 0 then return nil end
    local root = math.sqrt(disc)
    local lo, hi = (-b - root) / (2 * a), (-b + root) / (2 * a)
    if lo < 0 then lo = 0 end
    if hi > 1 then hi = 1 end
    if lo >= hi then return nil end
    return ax + dx * lo, ay + dy * lo, ax + dx * hi, ay + dy * hi
end

-- How far (yards, squared) the point is from the stretch a-b.
local function Off(x, y, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local length = dx * dx + dy * dy
    local t = length > 0 and ((x - a.x) * dx + (y - a.y) * dy) / length or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local ox, oy = x - (a.x + dx * t), y - (a.y + dy * t)
    return ox * ox + oy * oy
end

-- A world point on the minimap as the last placing saw it: x to the right
-- and y up from the centre, 1 at the edge. The pin library's rule.
local function OnMini(point)
    local east, north = miniView.y - point.y, point.x - miniView.x
    return (east * miniView.cos + north * miniView.sin) / miniView.radius,
           (north * miniView.cos - east * miniView.sin) / miniView.radius
end

local function MiniLine(colour, x1, y1, x2, y2)
    local line = miniLines[miniShown + 1]
    if not line then
        line = mini:CreateLine(nil, "ARTWORK")
        line:SetThickness(MINI_PX)
        miniLines[miniShown + 1] = line
    end
    miniShown = miniShown + 1
    local half, tall = miniView.half, miniView.tall
    line:SetColorTexture(colour[1], colour[2], colour[3], LINE_ALPHA)
    line:SetStartPoint("CENTER", mini, x1 * half, y1 * tall)
    line:SetEndPoint("CENTER", mini, x2 * half, y2 * tall)
    line:Show()
end

-- Puts the lines where the minimap now shows the trip. Runs at every frame
-- while there is a trip, and does the work only when the player moved or
-- turned, or the minimap changed its zoom or its size.
local function MiniPlace()
    local minimap = rawget(_G, "Minimap")
    if not mini or not wanted or type(minimap) ~= "table" then return end
    local x, y, continent = ns.Geo.PlayerNow()
    if not x then return MiniHide("position") end
    local width, height = minimap:GetWidth(), minimap:GetHeight()
    if not Number(width) or not Number(height) or width <= 0 or height <= 0 then return MiniHide("size") end
    local radius, source = ViewRadius(minimap)
    if not radius then return MiniHide("radius") end
    local facing = Turned()
    if facing == nil then return MiniHide("facing") end

    local view = miniView
    if view.set and view.x == x and view.y == y and view.continent == continent and view.radius == radius
        and view.facing == facing and view.width == width and view.height == height then
        return
    end
    view.set, view.x, view.y, view.continent, view.radius = true, x, y, continent, radius
    view.facing, view.width, view.height = facing, width, height
    view.half, view.tall = width / 2, height / 2
    view.cos, view.sin = 1, 0
    if facing then view.cos, view.sin = math.cos(facing), math.sin(facing) end

    local was = miniShown
    miniShown = 0
    local from = 1
    -- The first leg starts at the player: the line does too, and goes to the
    -- turn ahead. The player may have passed a turn or two since the trip
    -- was laid, so the stretch nearest to the player says which turn that is.
    if wanted[1] and wanted[1].first and wanted[1][1].continent == continent then
        local nearest, least = 1, nil
        for index = 1, math.min(#wanted, MINI_LOOK) do
            local stretch = wanted[index]
            if not stretch.first then break end
            local off = Off(x, y, stretch[1], stretch[2])
            -- As near as the one before: the turn between them is passed.
            if not least or off <= least + 0.01 then nearest, least = index, off end
        end
        local tx, ty = OnMini(wanted[nearest][2])
        local length = math.sqrt(tx * tx + ty * ty)
        local gap = MINI_ARROW / view.half
        if length > gap then
            local x1, y1, x2, y2 = Inside(tx * gap / length, ty * gap / length, tx, ty, MINI_RIM)
            if x1 then MiniLine(wanted[nearest][3], x1, y1, x2, y2) end
        end
        from = nearest + 1
    end
    for index = from, #wanted do
        if miniShown >= MINI_MAX then break end
        local stretch = wanted[index]
        if stretch[1].continent == continent then
            local ax, ay = OnMini(stretch[1])
            local bx, by = OnMini(stretch[2])
            -- Both ends past the same side of the minimap: nothing of it shows.
            if not ((ax > MINI_RIM and bx > MINI_RIM) or (ax < -MINI_RIM and bx < -MINI_RIM)
                or (ay > MINI_RIM and by > MINI_RIM) or (ay < -MINI_RIM and by < -MINI_RIM)) then
                local x1, y1, x2, y2 = Inside(ax, ay, bx, by, MINI_RIM)
                if x1 then MiniLine(stretch[3], x1, y1, x2, y2) end
            end
        end
    end
    for index = miniShown + 1, was do miniLines[index]:Hide() end
    miniState.shown, miniState.why, miniState.radius, miniState.source = miniShown, nil, radius, source
    miniState.turned, miniState.width, miniState.continent = facing and true or false, width, continent
end

-- Never lets a drawing error reach the player: the minimap's lines go, and
-- only they. The next trip tries again.
function Trail.MiniLayout()
    if miniState.error then return end
    local ok, err = pcall(MiniPlace)
    if not ok then
        miniState.error = tostring(err)
        miniFailed = laying
        pcall(MiniHide, "error")
        if mini then mini:Hide() end
        if ns.Log then ns.Log("trail minimap line: %s", miniState.error) end
    end
end

-- The frame of the minimap's lines, made when the first trip needs it.
local function Mini()
    if mini then return mini end
    local minimap = rawget(_G, "Minimap")
    if type(minimap) ~= "table" or type(CreateFrame) ~= "function" then return nil end
    local ok, frame = pcall(CreateFrame, "Frame", nil, minimap)
    if not ok or type(frame) ~= "table" or type(frame.CreateLine) ~= "function" then return nil end
    frame:SetAllPoints(minimap)
    if frame.EnableMouse then frame:EnableMouse(false) end
    frame:Hide()   -- shown while there is a trip: its OnUpdate runs only then
    frame:SetScript("OnUpdate", Trail.MiniLayout)
    mini = frame
    return mini
end

-- Starts the minimap's lines for the trip just laid in `wanted`.
local function MiniStart()
    if laying ~= miniFailed then miniState.error, miniFailed = nil, nil end
    if miniState.error or #wanted == 0 or not Mini() then return end
    miniView.set = false
    mini:Show()
    Trail.MiniLayout()
end

local function MiniStop()
    if not mini then return end
    pcall(MiniHide)
    mini:Hide()
end

-- Makes the lines of the current route once the world map can take them: it
-- may not exist yet when the route is first shown.
local function Lines()
    if not wanted or usedSegments > 0 or lineState.error then return end
    for _, stretch in ipairs(wanted) do Segment(stretch[1], stretch[2], stretch[3]) end
    if usedSegments > 0 then
        view = nil
        overlay:Show()
        Trail.Layout()
    end
end

-- The same route, the player a little further: the line starts where the
-- player is now.
local function Follow(legs)
    local first = legs[1]
    if usedSegments > 0 and first.from.continent == first.to.continent then
        segments[1].from, view = first.from, nil
    end
end

-- The points a leg is drawn through: its real path, else its two ends.
local function Through(leg)
    if type(leg.path) == "table" and #leg.path >= 2 then return leg.path end
    return { leg.from, leg.to }
end

local function Between(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function Length(points)
    local length = 0
    for index = 2, #points do length = length + Between(points[index - 1], points[index]) end
    return length
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
    pcall(HideLines)
    MiniStop()
    usedSegments, wanted, view, rim = 0, nil, nil, nil
    if overlay then overlay:Hide() end
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

-- Where the trip ends: what a failed line is remembered by, however far
-- the player has walked since.
local function Goal(legs)
    local to = legs[#legs].to
    return ("%d:%d:%d"):format(to.continent, math.floor(to.x), math.floor(to.y))
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
        -- A real path: which one, and how many of its turns are still ahead.
        if leg.path then parts[#parts] = parts[#parts] .. ("~%d.%d"):format(leg.pathId or 0, #leg.path) end
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
    if signature == drawn and not stale then
        Lines()
        -- The world map came since, and the line with it: the dots go.
        if not (dotted and usedSegments > 0 and not lineState.error) then
            Follow(legs)
            return
        end
    end
    Trail.Clear()
    if type(CreateFrame) ~= "function" then return end

    -- The line: one stretch per leg that stays on one continent, and one
    -- from each turn to the next along a real path. A trip whose line failed
    -- is not tried again: it keeps its dots.
    wanted, laying = {}, Goal(legs)
    if laying ~= failed then lineState.error, failed = nil, nil end
    for index, leg in ipairs(legs) do
        if leg.from.continent == leg.to.continent then
            local points = Through(leg)
            for at = 2, #points do
                wanted[#wanted + 1] = { points[at - 1], points[at], COLOUR[leg.kind] or COLOUR.ride,
                                        first = index == 1 }
            end
        end
    end
    MiniStart()
    Lines()
    dotted, stale = usedSegments == 0 or lineState.error ~= nil, nil

    local pins = Pins()
    if not pins then
        -- Nothing to lay markers or dots with: the trail is the line, if there is one.
        drawn = usedSegments > 0 and signature or nil
        return
    end
    drawn = signature

    -- Spread the dot budget: long trips get wider gaps.
    local stretch = 1
    if dotted then
        local dots = 0
        for _, leg in ipairs(legs) do
            if leg.from.continent == leg.to.continent then
                dots = dots + Length(Through(leg)) / (SPACING[leg.kind] or RIDE_SPACING)
            end
        end
        stretch = math.max(1, dots / MAX_DOTS)
    end

    for index, leg in ipairs(legs) do
        local from, to = leg.from, leg.to
        local colour = COLOUR[leg.kind] or COLOUR.ride
        if dotted and from.continent == to.continent then
            local points = Through(leg)
            local length = Length(points)
            local gap = (SPACING[leg.kind] or RIDE_SPACING) * stretch
            -- From the far end back toward the start, so the dots stay put
            -- while the player walks along them. `turn`: the point the dots
            -- are heading back to, `passed`: the yards from the far end to
            -- the point before it.
            local skip = index == 1 and NEAR_PLAYER or 0
            local at = gap
            local turn, passed = #points - 1, 0
            while at < length - skip do
                local span = Between(points[turn + 1], points[turn])
                while turn > 1 and passed + span < at do
                    passed = passed + span
                    turn = turn - 1
                    span = Between(points[turn + 1], points[turn])
                end
                local a, b = points[turn + 1], points[turn]
                local t = span > 0 and math.min(1, (at - passed) / span) or 0
                local point = { continent = to.continent, x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
                local dot = Dot("world")
                Style(dot, leg.kind == "walk" and 5 or 4, colour)
                OnWorldMap(pins, dot, point)
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
            local stop = Dot("minimap")
            if leg.final then Style(stop, 14, nil, ICON_HAND_IN) else Style(stop, 9, colour) end
            OnMinimap(pins, stop, to, true)
            rim = { dot = stop, point = to }
        end
    end
end

-- Where the pin library put the marker of the next stop on the minimap, and
-- where this file's own rule puts the same point: the two agree when the
-- minimap's line is drawn to the right scale and the right way round.
local function RimCheck()
    miniState.pin, miniState.own = nil, nil
    if not rim or not miniView.set or rim.point.continent ~= miniView.continent then return end
    local x, y = OnMini(rim.point)
    local far = math.sqrt(x * x + y * y) / MINI_RIM
    if far > 1 then x, y = x / far, y / far end   -- kept on the rim, as the library does
    miniState.own = { x * miniView.half, y * miniView.tall }
    local ok, _, _, _, px, py = pcall(rim.dot.GetPoint, rim.dot)
    if ok and Number(px) and Number(py) then miniState.pin = { px, py } end
end

-- For the debug snapshot and the tests.
function Trail.State()
    pcall(RimCheck)
    return { drawn = drawn ~= nil, dotted = dotted or false, world = used.world, minimap = used.minimap,
             lines = usedSegments, line = lineState, miniLine = miniState }
end
