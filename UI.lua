local _, ns = ...
local L = ns.L

-- The turn-in window: a short list, nearest first. Showing it starts the
-- guidance, hiding it stops it. It has two sizes: the whole list, or only
-- the next hand-in and what to do now. The guidance runs the same in both.
local UI = {}
ns.UI = UI

local WIDTH, PAD = 330, 12
local ROW_HEIGHT, HEADER_HEIGHT, NOTE_HEIGHT = 36, 20, 16
local INNER = WIDTH - 2 * PAD            -- usable width inside the padding
local MAP_BUTTON, MAP_GAP = 20, 6        -- "show on the map" button at the right of a row
local RIGHT_INSET = MAP_BUTTON + MAP_GAP
-- Row text: minus icon, gap, the right column and the map button.
local TEXT_WIDTH = INNER - 28 - 8 - 62 - RIGHT_INSET
local ICON_QUEST = "Interface\\Icons\\INV_Misc_Note_01"
local ICON_UNKNOWN = "Interface\\Icons\\INV_Misc_QuestionMark"
local ICON_MAP = "Interface\\Icons\\INV_Misc_Map_01"

-- How many rows each section may show before collapsing into "+N more".
local LIMIT = { ready = 8, readyNoItems = 4, progress = 4, orphans = 4 }

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local GREY = { 0.6, 0.6, 0.6 }
local GREEN = { 0.35, 0.9, 0.45 }
local SOFT = { 0.82, 0.82, 0.82 }
local DISABLED = { 0.5, 0.5, 0.5 }
local MAX_STEPS = 8                      -- route steps listed under the current quest
local TOP_FULL, TOP_COMPACT = 36, 20     -- from the title down to the first line
local SHRINK = "Interface\\Buttons\\UI-MinusButton-"    -- the size button: minus shrinks,
local EXPAND = "Interface\\Buttons\\UI-PlusButton-"     -- plus brings the list back
local SIZE_BUTTON = 16

local frame
local rows, labels = {}, {}

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    if point and type(DropOffDB) == "table" then
        DropOffDB.pos = { point, relativePoint, x, y }
    end
end

-- Holds the window by its top-left corner, so it grows and shrinks downwards
-- and the buttons of its title stay under the pointer.
local function AnchorTop()
    local left, top = frame:GetLeft(), frame:GetTop()
    if type(left) ~= "number" or type(top) ~= "number" then return end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

local function RestorePosition()
    frame:ClearAllPoints()
    local pos = type(DropOffDB) == "table" and DropOffDB.pos
    if type(pos) == "table" and pos[1] then
        frame:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -140, 60)
    end
end

local function ShowTooltip(row)
    local data = row.data
    if not data or not GameTooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(data.title, 1, 0.82, 0)
    if data.where then GameTooltip:AddLine(data.where, 1, 1, 1, true) end
    if data.items and #data.items > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.TIP_ITEMS, 0.6, 0.6, 0.6)
        for _, item in ipairs(data.items) do
            GameTooltip:AddLine(L.TIP_ITEM_LINE:format(item.name, item.count, item.slots), 1, 1, 1)
        end
    end
    if data.hint then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(data.hint, 0.35, 0.9, 0.45)
    end
    GameTooltip:Show()
end

local function NewRow()
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(INNER, ROW_HEIGHT)

    row.marker = row:CreateTexture(nil, "BACKGROUND")
    row.marker:SetPoint("TOPLEFT", row, "TOPLEFT", -4, 0)
    row.marker:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 4, 0)
    row.marker:SetColorTexture(1, 0.82, 0, 0.12)

    row.hover = row:CreateTexture(nil, "HIGHLIGHT")
    row.hover:SetAllPoints(row.marker)
    row.hover:SetColorTexture(1, 1, 1, 0.06)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", -RIGHT_INSET, -5)
    row.right:SetJustifyH("RIGHT")

    row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.badge:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -RIGHT_INSET, 5)
    row.badge:SetJustifyH("RIGHT")

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.title:SetWidth(TEXT_WIDTH)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
    row.sub:SetWidth(TEXT_WIDTH)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    -- Map button: makes this quest the target and opens the world map on it.
    local map = CreateFrame("Button", nil, row)
    row.map = map
    map:SetSize(MAP_BUTTON, MAP_BUTTON)
    map:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    map.icon = map:CreateTexture(nil, "ARTWORK")
    map.icon:SetAllPoints(map)
    map.icon:SetTexture(ICON_MAP)
    map.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    map.glow = map:CreateTexture(nil, "HIGHLIGHT")
    map.glow:SetAllPoints(map)
    map.glow:SetColorTexture(1, 1, 1, 0.25)
    map:SetScript("OnClick", function()
        -- The rows are redrawn by the click: do not leave the tooltip behind.
        if GameTooltip then GameTooltip:Hide() end
        if row.data and row.data.questID and row.data.canPin then ns.ShowOnMap(row.data.questID) end
    end)
    map:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.TIP_SHOW, 1, 1, 1)
        GameTooltip:Show()
    end)
    map:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    row:SetScript("OnEnter", ShowTooltip)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnClick", function(self)
        if self.data and self.data.questID and self.data.canPin then ns.Pin(self.data.questID) end
    end)
    return row
end

local function NewLabel()
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetWidth(INNER)
    return label
end

local function Build()
    frame = CreateFrame("Frame", "DropOffFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, 100)
    -- Below the world map and the other panels, like the quest tracker: a pin
    -- at the edge of the map must not end up hidden behind this window.
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        AnchorTop()
        SavePosition()
    end)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0.04, 0.04, 0.05, 0.92)
        frame:SetBackdropBorderColor(0.4, 0.4, 0.42, 1)
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
    frame.title:SetText(L.TITLE)

    frame.summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summary:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -4)
    frame.summary:SetWidth(INNER - 20)
    frame.summary:SetJustifyH("LEFT")
    frame.summary:SetWordWrap(false)

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    frame.close:SetScript("OnClick", function() frame:Hide() end)

    -- Size button, left of the cross: the small window, or the whole list.
    local size = CreateFrame("Button", nil, frame)
    frame.size = size
    size:SetSize(SIZE_BUTTON, SIZE_BUTTON)
    size:SetPoint("RIGHT", frame.close, "LEFT", 0, 0)
    size:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    local function sizeTip(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(UI.IsCompact() and L.TIP_EXPAND or L.TIP_COMPACT, 1, 1, 1)
        GameTooltip:Show()
    end
    size:SetScript("OnClick", function(self)
        if GameTooltip then GameTooltip:Hide() end
        UI.SetCompact(not UI.IsCompact())
        -- The pointer is still on the button: it now says what the next click does.
        if self:IsMouseOver() then sizeTip(self) end
    end)
    size:SetScript("OnEnter", sizeTip)
    size:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- Hide before wiring the scripts: frames are born shown, and this first
    -- Hide must not count as the player leaving turn-in mode.
    frame:Hide()
    RestorePosition()
    frame:SetScript("OnShow", function() ns.OnShown() end)
    frame:SetScript("OnHide", function(self)
        -- OnHide also fires when the whole UI hides (Alt+Z, cinematics) while
        -- the window itself stays shown: that is not leaving turn-in mode.
        if self:IsShown() then return end
        ns.OnHidden()
    end)
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function Colour(fontString, colour)
    fontString:SetTextColor(colour[1], colour[2], colour[3])
end

local function Where(quest, plan)
    local target = quest.target
    if not target then return plan.hasDB and L.UNKNOWN_PLACE or L.NEED_QUESTIE end
    local zone = target.zone or L.UNKNOWN_PLACE
    if target.dungeon then zone = zone .. ", " .. L.DUNGEON end
    if target.name then return L.NPC_AT:format(target.name, zone) end
    return zone
end

local function DistanceLabel(target)
    if not target then return "" end
    -- A trip with a flight or a crossing is told in minutes, like the order
    -- of the list; a plain walk in yards.
    local trip = target.eta and target.legs and #target.legs > 1
    if target.dist and not trip then return L.DIST_YARDS:format(math.floor(target.dist + 0.5)) end
    if target.eta then return L.ETA:format(math.max(1, math.floor(target.eta / 60 + 0.5))) end
    return target.far and L.DIST_FAR or ""
end

local function QuestIcon(quest)
    local first = quest.items[1]
    return first and first.icon or ICON_QUEST
end

-- Flattens the plan into the lines the window draws, top to bottom.
-- `compact`: only the hand-in the arrow points at and what to do now.
function UI.Lines(plan, compact)
    local lines = {}
    local function header(text) lines[#lines + 1] = { kind = "label", text = text, height = HEADER_HEIGHT } end
    local function note(text, colour)
        lines[#lines + 1] = { kind = "label", text = text, height = NOTE_HEIGHT, colour = colour }
    end

    -- The trip to the current quest, one line per leg, when it is more than a walk.
    local function route(quest)
        local target = quest.target
        local legs = target and target.legs
        if not legs or #legs < 2 then return end
        note(L.ROUTE:format(ns.Route.TimeText(target.eta)), WHITE)
        -- On a flight or a crossing, the legs before it are behind the player.
        local first = ns.Route.FirstLeg(legs, plan.carried) or 1
        local assumed = false
        for index = first, math.min(#legs, first + MAX_STEPS - 1) do
            local text = ns.Route.StepText(legs, index, target.name)
            note("  " .. L.STEP:format(index - first + 1, text), index == first and GOLD or SOFT)
            assumed = assumed or legs[index].assumed
        end
        if assumed then note("  " .. L.ROUTE_ASSUMED) end
    end

    local function readyRow(quest)
        local pinned = ns.state.pinned == quest.id
        lines[#lines + 1] = {
            kind = "row", height = ROW_HEIGHT,
            questID = quest.id, canPin = quest.target ~= nil,
            current = plan.current == quest.id,
            icon = QuestIcon(quest), title = quest.title, titleColour = GOLD,
            sub = Where(quest, plan), where = Where(quest, plan),
            right = DistanceLabel(quest.target),
            badge = quest.slots > 0 and L.SLOTS:format(quest.slots) or "", badgeColour = GREEN,
            items = quest.items,
            hint = quest.target and (pinned and L.TIP_PINNED or L.TIP_CLICK) or nil,
        }
    end

    if compact then
        -- Quests the log hides are said in both sizes: without it the small
        -- window would claim there is nothing to turn in.
        if (plan.hidden or 0) > 0 then note(L.HIDDEN_QUESTS:format(plan.hidden)) end
        local shown = plan.ready[1]
        for _, quest in ipairs(plan.ready) do
            if quest.id == plan.current then shown = quest end
        end
        if not shown then
            note(L.SUMMARY_NONE:format(plan.free), SOFT)
            return lines
        end
        readyRow(shown)
        local target = shown.target
        local legs = target and target.legs
        if legs and #legs > 1 then
            local first = ns.Route.FirstLeg(legs, plan.carried) or 1
            note(L.COMPACT_STEP:format(ns.Route.StepText(legs, first, target.name)), GOLD)
            -- A flight taken on trust is said so here too, whichever step it is.
            for index = first, #legs do
                if legs[index].assumed then
                    note(L.ROUTE_ASSUMED)
                    break
                end
            end
        end
        if not plan.hasDB then note(L.NEED_QUESTIE) end
        if #plan.ready > 1 then note(L.MORE:format(#plan.ready - 1)) end
        return lines
    end

    if (plan.hidden or 0) > 0 then note(L.HIDDEN_QUESTS:format(plan.hidden)) end

    local withItems, withoutItems = {}, {}
    for _, quest in ipairs(plan.ready) do
        local bucket = quest.slots > 0 and withItems or withoutItems
        bucket[#bucket + 1] = quest
    end

    local function readySection(list, title, limit)
        if #list == 0 then return end
        header(title)
        for index = 1, math.min(#list, limit) do
            local quest = list[index]
            readyRow(quest)
            if plan.current == quest.id then route(quest) end
        end
        if #list > limit then note(L.MORE:format(#list - limit)) end
    end
    readySection(withItems, L.SECTION_READY, LIMIT.ready)
    readySection(withoutItems, L.SECTION_READY_NOITEMS, LIMIT.readyNoItems)

    if #plan.progress > 0 then
        header(L.SECTION_PROGRESS)
        for index = 1, math.min(#plan.progress, LIMIT.progress) do
            local quest = plan.progress[index]
            lines[#lines + 1] = {
                kind = "row", height = ROW_HEIGHT, dim = true,
                icon = QuestIcon(quest), title = quest.title, titleColour = WHITE,
                sub = L.PROGRESS:format(quest.done, quest.need),
                right = "", badge = tostring(quest.slots), badgeColour = GREY,
                items = quest.items,
            }
        end
        if #plan.progress > LIMIT.progress then note(L.MORE:format(#plan.progress - LIMIT.progress)) end
    end

    if #plan.orphans > 0 then
        header(L.SECTION_ORPHANS)
        for index = 1, math.min(#plan.orphans, LIMIT.orphans) do
            local item = plan.orphans[index]
            lines[#lines + 1] = {
                kind = "row", height = ROW_HEIGHT, dim = true,
                icon = item.icon or ICON_UNKNOWN, title = item.name, titleColour = WHITE,
                sub = item.starts and L.ORPHAN_STARTS or L.ORPHAN_LEFTOVER,
                right = "", badge = "x" .. item.count, badgeColour = GREY,
            }
        end
        if #plan.orphans > LIMIT.orphans then note(L.MORE:format(#plan.orphans - LIMIT.orphans)) end
    end

    -- Footer: how the way is shown, or what is missing to show it.
    local mode = ns.Nav.Mode()
    if not plan.hasDB then
        note(L.NEED_QUESTIE)
    elseif #plan.ready > 0 then
        note(mode == "tomtom" and L.NAV_TOMTOM or mode == "native" and L.NAV_NATIVE or L.NAV_NONE)
    end
    return lines
end

function UI.Render(plan)
    if not frame then return end

    if #plan.ready > 0 then
        frame.summary:SetText(L.SUMMARY:format(#plan.ready, plan.readySlots, plan.free))
    else
        frame.summary:SetText(L.SUMMARY_NONE:format(plan.free))
    end
    local compact = UI.IsCompact()
    frame.summary:SetShown(not compact)
    -- The button shows what a click gives: the other size.
    local art = compact and EXPAND or SHRINK
    frame.size:SetNormalTexture(art .. "Up")
    frame.size:SetPushedTexture(art .. "Down")
    frame.size.compact = compact

    local lines = UI.Lines(plan, compact)
    local usedRows, usedLabels = 0, 0
    local y = -(PAD + (compact and TOP_COMPACT or TOP_FULL))

    for _, line in ipairs(lines) do
        if line.kind == "row" then
            usedRows = usedRows + 1
            local row = rows[usedRows]
            if not row then
                row = NewRow()
                rows[usedRows] = row
            end
            row.data = line
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
            row.icon:SetTexture(line.icon)
            row.icon:SetAlpha(line.dim and 0.6 or 1)
            row.title:SetText(line.title)
            Colour(row.title, line.titleColour)
            row.sub:SetText(line.sub)
            Colour(row.sub, line.dim and GREY or WHITE)
            row.right:SetText(line.right)
            row.badge:SetText(line.badge)
            Colour(row.badge, line.badgeColour)
            row.marker:SetShown(line.current and true or false)
            row.map:SetShown(line.canPin and true or false)
            row:Show()
        else
            usedLabels = usedLabels + 1
            local label = labels[usedLabels]
            if not label then
                label = NewLabel()
                labels[usedLabels] = label
            end
            label:ClearAllPoints()
            label:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", PAD, y - line.height + 4)
            label:SetText(line.text)
            Colour(label, line.colour or DISABLED)
            label:Show()
        end
        y = y - line.height
    end

    for index = usedRows + 1, #rows do rows[index]:Hide() end
    for index = usedLabels + 1, #labels do labels[index]:Hide() end

    frame:SetHeight(-y + PAD)
end

---------------------------------------------------------------------------
-- Visibility
---------------------------------------------------------------------------

-- For the tests: the row widgets currently drawn, top to bottom.
function UI.Rows()
    local drawn = {}
    for _, row in ipairs(rows) do
        if row:IsShown() then drawn[#drawn + 1] = row end
    end
    return drawn
end

function UI.IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

function UI.Show()
    if not frame then Build() end
    frame:Show()
end

-- The small window: only the next hand-in. Kept per character.
function UI.IsCompact()
    return type(DropOffCharDB) == "table" and DropOffCharDB.compact == true
end

function UI.SetCompact(compact)
    if type(DropOffCharDB) ~= "table" then return end
    DropOffCharDB.compact = compact and true or false
    if frame and frame:IsShown() and ns.state.plan then
        AnchorTop()
        SavePosition()
        UI.Render(ns.state.plan)
    end
end

function UI.Hide()
    if frame then frame:Hide() end
end
