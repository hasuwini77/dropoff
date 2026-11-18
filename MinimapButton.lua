local _, ns = ...
local L = ns.L

-- The icon on the rim of the minimap. A click opens or closes the window, a
-- right-click switches between the small window and the whole list, and it
-- can be dragged round the rim. /dropoff minimap hides it.
local MinimapButton = {}
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Misc_Bag_08"
local DEFAULT_ANGLE = 210   -- degrees, counter-clockwise from the right of the minimap
local RIM = 5               -- how far outside the minimap's edge the middle of the icon sits
local MINIMAP_WIDTH = 140   -- when the minimap does not give its width

local button

local function Settings()
    local db = type(DropOffDB) == "table" and DropOffDB.minimap
    return type(db) == "table" and db or nil
end

local function Place()
    local db = Settings()
    local angle = math.rad(db and tonumber(db.angle) or DEFAULT_ANGLE)
    local width = Minimap:GetWidth()
    if type(width) ~= "number" or width <= 0 then width = MINIMAP_WIDTH end
    local radius = width / 2 + RIM
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragged: the icon goes where the pointer is, round the rim.
local function Follow()
    local db = Settings()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cx, cy
    if type(GetCursorPosition) == "function" then cx, cy = GetCursorPosition() end
    if not db or type(mx) ~= "number" or type(my) ~= "number" or type(cx) ~= "number" or type(cy) ~= "number"
        or type(scale) ~= "number" or scale <= 0 then
        return
    end
    db.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
    Place()
end

local function Tooltip(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(L.TITLE, 1, 0.82, 0)
    GameTooltip:AddLine(L.TIP_MINIMAP_CLICK, 1, 1, 1)
    GameTooltip:AddLine(L.TIP_MINIMAP_RIGHT, 1, 1, 1)
    GameTooltip:AddLine(L.TIP_MINIMAP_DRAG, 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function Build()
    button = CreateFrame("Button", "DropOffMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetPoint("CENTER", button, "CENTER", 0, 1)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("CENTER", button, "CENTER", 0, 1)
    button.icon:SetTexture(ICON)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnClick", function(_, mouseButton)
        if GameTooltip then GameTooltip:Hide() end
        if mouseButton == "RightButton" then ns.ToggleCompact() else ns.Toggle() end
    end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", Follow) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", Tooltip)
    button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
end

-- For the debug snapshot: was the icon made, is it shown, and where.
function MinimapButton.State()
    local db = Settings()
    return {
        minimap = type(Minimap) == "table",
        made = button ~= nil,
        shown = button ~= nil and button:IsShown() and true or false,
        hide = db and db.hide or nil,
        angle = db and db.angle or nil,
    }
end

-- Shows the icon where the settings put it, or hides it. Makes it on first use.
function MinimapButton.Refresh()
    if type(Minimap) ~= "table" then return end
    local db = Settings()
    if db and db.hide then
        if button then button:Hide() end
        return
    end
    if not button then Build() end
    Place()
    button:Show()
end
