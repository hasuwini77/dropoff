local _, ns = ...
local Data, Geo, Route = ns.Data, ns.Geo, ns.Route

-- Builds the list the window shows: finished quests to hand in (holding bag
-- items first, quickest to reach first), quests in progress that hold items, and quest
-- items tied to nothing in the log.
local Plan = {}
ns.Plan = Plan

-- Is location `a` a better place to hand in than `b`?
local function Better(a, b)
    if not b then return true end
    if a.friendly ~= b.friendly then return a.friendly end
    -- Travel time knows about flights and boats; yards do not.
    if a.eta and b.eta then return a.eta < b.eta end
    if a.eta or b.eta then return a.eta ~= nil end
    if a.dist and b.dist then return a.dist < b.dist end
    if a.dist or b.dist then return a.dist ~= nil end
    return b.far and not a.far
end

-- The trip to a place: seconds and legs, when the travel network reaches it.
local function Trip(place)
    local gx, gy, continent = Geo.World(place.mapId, place.x, place.y)
    if gx then place.eta, place.legs = Route.To(gx, gy, continent) end
end

local function ResolveTarget(quest)
    local info = Data.Static(quest.id)
    local best
    if info then
        for _, finisher in ipairs(info.finishers) do
            local name, spawns, friendly = Data.FinisherInfo(finisher)
            if type(spawns) == "table" then
                local place = Geo.NearestSpawn(spawns)
                if place then
                    place.name, place.friendly, place.kind = name, friendly, finisher.kind
                    Trip(place)
                    if Better(place, best) then best = place end
                end
            end
        end
    end
    if not best then
        local mapId, x, y = Data.NativeWaypoint(quest.id)
        if mapId then
            local dist, far = Geo.Distance(mapId, x, y)
            best = { mapId = mapId, x = x, y = y, dist = dist, far = far or false,
                     dungeon = false, friendly = true, native = true }
            Trip(best)
        end
    end
    if best then best.zone = Geo.MapName(best.mapId) end
    return best
end

local function ByRoute(a, b)
    local aItems, bItems = a.slots > 0, b.slots > 0
    if aItems ~= bItems then return aItems end
    -- By travel time first: every quest with one comes before those without,
    -- which fall back to yards. One rule per pair keeps the order consistent.
    local ae, be = a.target and a.target.eta, b.target and b.target.eta
    if ae and be then
        if ae ~= be then return ae < be end
    elseif ae or be then
        return ae ~= nil
    else
        local ad, bd = a.target and a.target.dist, b.target and b.target.dist
        if ad and bd then
            if ad ~= bd then return ad < bd end
        elseif ad or bd then
            return ad ~= nil
        end
    end
    local aPlace, bPlace = a.target ~= nil, b.target ~= nil
    if aPlace ~= bPlace then return aPlace end
    if a.slots ~= b.slots then return a.slots > b.slots end
    return a.id < b.id
end

local function BySlots(a, b)
    if a.slots ~= b.slots then return a.slots > b.slots end
    return a.id < b.id
end

local function AddItem(quest, bagItem, tied)
    for _, existing in ipairs(quest.items) do
        if existing.id == bagItem.id then return end
    end
    local name, icon = Data.ItemInfo(bagItem.id)
    quest.items[#quest.items + 1] = {
        id = bagItem.id, name = name or ("#" .. bagItem.id), icon = bagItem.icon or icon,
        slots = bagItem.slots, count = bagItem.count,
    }
    quest.slots = quest.slots + bagItem.slots
    tied[bagItem.id] = true
end

function Plan.Build()
    local bags, free = Data.ScanBags()
    local quests, hidden = Data.ReadQuestLog()
    local tied = {}
    Geo.BeginPass()
    Route.Begin(Geo.PlayerWorld())

    -- 1. Items the database ties to each quest.
    for _, quest in ipairs(quests) do
        quest.items, quest.slots = {}, 0
        local info = Data.Static(quest.id)
        if info then
            for itemID in pairs(info.items) do
                if bags[itemID] then AddItem(quest, bags[itemID], tied) end
            end
        end
    end

    -- 2. Quest-class items the database did not tie: match by objective text
    --    ("Wolf Pelt: 5/5" contains the item name).
    local loose = {}
    for itemID, bagItem in pairs(bags) do
        if not tied[itemID] then
            local name, icon, classID = Data.ItemInfo(itemID)
            if classID == Data.QUEST_ITEM_CLASS then
                local matched = false
                if name then
                    for _, quest in ipairs(quests) do
                        for _, objective in ipairs(quest.objectives) do
                            if objective.text:find(name, 1, true) then
                                AddItem(quest, bagItem, tied)
                                matched = true
                                break
                            end
                        end
                    end
                end
                if not matched then
                    loose[#loose + 1] = {
                        id = itemID, name = name or ("#" .. itemID), icon = bagItem.icon or icon,
                        slots = bagItem.slots, count = bagItem.count,
                    }
                end
            end
        end
    end

    -- 3. Sort quests into finished / in progress.
    local ready, progress = {}, {}
    local readyItems, readyWithItems = {}, 0
    for _, quest in ipairs(quests) do
        quest.done, quest.need = 0, #quest.objectives
        for _, objective in ipairs(quest.objectives) do
            if objective.finished then quest.done = quest.done + 1 end
        end
        quest.ready = Data.IsReady(quest)
        if quest.ready then
            quest.target = ResolveTarget(quest)
            ready[#ready + 1] = quest
            if quest.slots > 0 then readyWithItems = readyWithItems + 1 end
            for _, item in ipairs(quest.items) do readyItems[item.id] = item.slots end
        elseif quest.slots > 0 and not quest.failed then
            progress[#progress + 1] = quest
        end
    end
    table.sort(ready, ByRoute)
    table.sort(progress, BySlots)

    -- 4. Leftovers: quest items no quest in the log wants.
    for _, item in ipairs(loose) do
        local startsQuest = Data.ItemStartsQuest(item.id)
        if startsQuest then
            local done = C_QuestLog and ns.Try(C_QuestLog.IsQuestFlaggedCompleted, startsQuest)
            item.starts = not done
        end
    end
    table.sort(loose, BySlots)

    -- An item shared by two finished quests still frees its slots only once.
    local readySlots = 0
    for _, slots in pairs(readyItems) do readySlots = readySlots + slots end

    return {
        all = quests,
        ready = ready,
        progress = progress,
        orphans = loose,
        tied = tied,
        free = free,
        readySlots = readySlots,
        readyWithItems = readyWithItems,
        hidden = hidden or 0,
        hasDB = Data.DB() ~= nil,
    }
end
