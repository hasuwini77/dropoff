local _, ns = ...
local Try, Secret = ns.Try, ns.Secret

-- Reads the game: bags, quest log, and (when installed) the QuestieDB library.
local Data = {}
ns.Data = Data

local QUEST_ITEM_CLASS = 12
local CONTRACT = 4  -- QuestieDB public contract this file was written against

---------------------------------------------------------------------------
-- QuestieDB (optional)
---------------------------------------------------------------------------

local contractChecked, contractOk = false, false

-- The public LibQuestieDB table, or nil when Questie's database is absent or
-- speaks a contract this addon does not know.
function Data.DB()
    local lib = rawget(_G, "LibQuestieDB")
    if type(lib) ~= "table" or type(lib.Quest) ~= "table" or type(lib.Npc) ~= "table" then return nil end
    if not contractChecked then
        contractChecked = true
        contractOk = type(lib.RequireContract) ~= "function" or Try(lib.RequireContract, CONTRACT) == true
        if not contractOk then ns.Log("QuestieDB contract %s not supported", tostring(lib.contractVersion)) end
    end
    return contractOk and lib or nil
end

local static = {}

-- What the database knows about a quest and never changes during a session:
-- the items it involves, who ends it, and whether it has objectives at all.
-- Returns nil when there is no database or the quest is unknown to it.
function Data.Static(questID)
    local cached = static[questID]
    if cached then return cached end
    local db = Data.DB()
    if not db then return nil end

    local Q = db.Quest
    if type(Q.Exists) == "function" and not Try(Q.Exists, questID) then return nil end

    local info = { items = {}, finishers = {}, hasObjectives = false, hasTrigger = false }

    local objectives = Try(Q.objectives, questID)
    if type(objectives) == "table" then
        for index = 1, 6 do
            local group = objectives[index]
            if type(group) == "table" and next(group) ~= nil then info.hasObjectives = true end
        end
        -- [3] items to collect: { itemID, text?, ... }
        if type(objectives[3]) == "table" then
            for _, entry in pairs(objectives[3]) do
                if type(entry) == "table" and type(entry[1]) == "number" then info.items[entry[1]] = true end
            end
        end
        -- [6] spell objectives carry the item that casts the spell: { spellID, text?, itemID }
        if type(objectives[6]) == "table" then
            for _, entry in pairs(objectives[6]) do
                if type(entry) == "table" and type(entry[3]) == "number" then info.items[entry[3]] = true end
            end
        end
    end

    local source = Try(Q.sourceItemId, questID)
    if type(source) == "number" and source > 0 then info.items[source] = true end

    local required = Try(Q.requiredSourceItems, questID)
    if type(required) == "table" then
        for _, itemID in pairs(required) do
            if type(itemID) == "number" then info.items[itemID] = true end
        end
    end

    local trigger = Try(Q.triggerEnd, questID)
    if type(trigger) == "table" and next(trigger) ~= nil then info.hasTrigger = true end

    local finishedBy = Try(Q.finishedBy, questID)
    if type(finishedBy) == "table" then
        for _, npcID in pairs(type(finishedBy[1]) == "table" and finishedBy[1] or {}) do
            info.finishers[#info.finishers + 1] = { kind = "npc", id = npcID }
        end
        for _, objectID in pairs(type(finishedBy[2]) == "table" and finishedBy[2] or {}) do
            info.finishers[#info.finishers + 1] = { kind = "object", id = objectID }
        end
    end

    -- Kept only once it names who ends the quest: a database that is still
    -- loading answers with nothing, and that must not stick for the session.
    if #info.finishers > 0 then static[questID] = info end
    return info
end

-- Name, spawn list and "will talk to my faction" for one quest finisher.
function Data.FinisherInfo(finisher)
    local db = Data.DB()
    if not db then return nil end
    local entity = finisher.kind == "npc" and db.Npc or db.Object
    if type(entity) ~= "table" then return nil end

    local name = Try(entity.name, finisher.id)
    local spawns = Try(entity.spawns, finisher.id)
    local friendly = true
    if finisher.kind == "npc" then
        local side = Try(db.Npc.friendlyToFaction, finisher.id)
        local faction = type(UnitFactionGroup) == "function" and UnitFactionGroup("player") or nil
        local letter = faction == "Horde" and "H" or faction == "Alliance" and "A" or nil
        if type(side) == "string" and letter and not side:find(letter, 1, true) then friendly = false end
    end
    return name, spawns, friendly
end

-- Quest started by using this item, when the database knows one.
function Data.ItemStartsQuest(itemID)
    local db = Data.DB()
    if not db or type(db.Item) ~= "table" then return nil end
    local questID = Try(db.Item.startQuest, itemID)
    if type(questID) == "number" and questID > 0 then return questID end
    return nil
end

-- What the database says about a quest item: the quests that use it (the one
-- it starts included), and whether some quest gives it as a reward. Returns
-- nil when there is no database or it knows nothing of the item.
function Data.ItemQuests(itemID)
    local db = Data.DB()
    if not db or type(db.Item) ~= "table" then return nil end
    local quests, seen = {}, {}
    local function add(questID)
        if type(questID) == "number" and questID > 0 and not seen[questID] then
            seen[questID] = true
            quests[#quests + 1] = questID
        end
    end
    add(Try(db.Item.startQuest, itemID))
    local related = db.Item.relatedQuests and Try(db.Item.relatedQuests, itemID)
    if type(related) == "table" then for _, questID in ipairs(related) do add(questID) end end
    local rewards = db.Item.questRewards and Try(db.Item.questRewards, itemID)
    local reward = type(rewards) == "table" and #rewards > 0
    if #quests == 0 and not reward then return nil end
    return quests, reward
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

-- name, icon, classID for an item. Any of them can be nil while uncached.
function Data.ItemInfo(itemID)
    local name = Try(C_Item and C_Item.GetItemNameByID, itemID)
    if type(name) ~= "string" then name = Try(rawget(_G, "GetItemInfo"), itemID) end
    if type(name) ~= "string" then
        local db = Data.DB()
        name = db and type(db.Item) == "table" and Try(db.Item.name, itemID) or nil
    end
    local instant = C_Item and C_Item.GetItemInfoInstant or rawget(_G, "GetItemInfoInstant")
    local _, _, _, _, icon, classID = Try(instant, itemID)
    return type(name) == "string" and name or nil, icon, classID
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

-- Returns items[itemID] = { id, slots, count, icon } and the number of free
-- slots in ordinary bags.
function Data.ScanBags()
    local items, free = {}, 0
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return items, free end

    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local slots = Try(C.GetContainerNumSlots, bag) or 0
        local empty = 0
        for slot = 1, slots do
            local info = Try(C.GetContainerItemInfo, bag, slot)
            local itemID = type(info) == "table" and info.itemID or nil
            if itemID and not Secret(itemID) then
                local entry = items[itemID]
                if not entry then
                    entry = { id = itemID, slots = 0, count = 0, icon = info.iconFileID }
                    items[itemID] = entry
                end
                entry.slots = entry.slots + 1
                -- The game knows when an item of any class starts a quest
                -- (a Tainted Globe of Water is not a "quest item").
                if not entry.startsQuest and C.GetContainerItemQuestInfo then
                    local quest = Try(C.GetContainerItemQuestInfo, bag, slot)
                    local questID = type(quest) == "table" and quest.questID or nil
                    if questID and not Secret(questID) and type(questID) == "number" and questID > 0
                        and not quest.isActive then
                        entry.startsQuest = questID
                    end
                end
                local stack = info.stackCount
                entry.count = entry.count + (not Secret(stack) and tonumber(stack) or 1)
            elseif not info then
                empty = empty + 1
            end
        end
        -- Only count general-purpose bags: a free quiver slot holds no quest item.
        local bagFree, family = Try(C.GetContainerNumFreeSlots, bag)
        if type(bagFree) == "number" then
            if not family or family == 0 then free = free + bagFree end
        else
            free = free + empty
        end
    end
    return items, free
end

---------------------------------------------------------------------------
-- Quest log
---------------------------------------------------------------------------

-- Quests the log API does not hand out: where the count covers only the
-- visible lines, everything under a collapsed zone header is missing.
local function HiddenCount(collapsed, total, seen)
    if collapsed and type(total) == "number" and not Secret(total) and total > seen then
        return total - seen
    end
    return 0
end

local function ModernLog()
    local quests = {}
    local shown, total = Try(C_QuestLog.GetNumQuestLogEntries)
    local collapsed, seen = false, 0
    for index = 1, type(shown) == "number" and shown or 0 do
        local info = Try(C_QuestLog.GetInfo, index)
        if type(info) == "table" then
            if info.isHeader then
                if info.isCollapsed then collapsed = true end
            else
                seen = seen + 1
            end
        end
        if type(info) == "table" and not info.isHeader and not info.isHidden
            and type(info.questID) == "number" and info.questID > 0 then
            local questID = info.questID
            local quest = {
                id = questID,
                title = info.title or ("#" .. questID),
                level = info.level,
                complete = Try(C_QuestLog.IsComplete, questID) and true or false,
                failed = Try(C_QuestLog.IsFailed, questID) and true or false,
                objectives = {},
            }
            local objectives = Try(C_QuestLog.GetQuestObjectives, questID)
            if type(objectives) == "table" then
                for _, objective in ipairs(objectives) do
                    if type(objective) == "table" then
                        quest.objectives[#quest.objectives + 1] = {
                            text = type(objective.text) == "string" and objective.text or "",
                            kind = objective.type,
                            finished = objective.finished and true or false,
                        }
                    end
                end
            end
            quests[#quests + 1] = quest
        end
    end
    return quests, HiddenCount(collapsed, total, seen)
end

local function LegacyLog()
    local quests = {}
    local getTitle = rawget(_G, "GetQuestLogTitle")
    local shown, total = Try(rawget(_G, "GetNumQuestLogEntries"))
    local collapsed, seen = false, 0
    for index = 1, type(shown) == "number" and shown or 0 do
        local title, level, _, isHeader, isCollapsed, isComplete, _, questID = Try(getTitle, index)
        if title and isHeader then
            if isCollapsed then collapsed = true end
        elseif title then
            seen = seen + 1
        end
        if title and not isHeader and type(questID) == "number" and questID > 0 then
            local quest = {
                id = questID, title = title, level = level,
                complete = isComplete == 1 or isComplete == true,
                failed = isComplete == -1,
                objectives = {},
            }
            local count = Try(rawget(_G, "GetNumQuestLeaderBoards"), index) or 0
            for line = 1, count do
                local text, kind, finished = Try(rawget(_G, "GetQuestLogLeaderBoard"), line, index)
                quest.objectives[#quest.objectives + 1] = {
                    text = type(text) == "string" and text or "",
                    kind = kind,
                    finished = finished and true or false,
                }
            end
            quests[#quests + 1] = quest
        end
    end
    return quests, HiddenCount(collapsed, total, seen)
end

-- Returns the quests, and how many more sit unread under collapsed headers.
function Data.ReadQuestLog()
    if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then return ModernLog() end
    if rawget(_G, "GetQuestLogTitle") then return LegacyLog() end
    return {}, 0
end

-- Can this quest be handed in right now?
function Data.IsReady(quest)
    if quest.failed then return false end
    if quest.complete then return true end

    local total = #quest.objectives
    if total > 0 then
        for _, objective in ipairs(quest.objectives) do
            if not objective.finished then return false end
        end
        return true
    end

    -- No objective lines: usually a delivery ("bring this to X"), which is ready
    -- the moment you accept it. The database tells apart the two other cases:
    -- objectives the client has not loaded yet, and a hidden "go there" trigger.
    local info = Data.Static(quest.id)
    if info and (info.hasObjectives or info.hasTrigger) then return false end
    return true
end

-- Where the game itself says to go next for a quest (map, x, y in 0..1).
function Data.NativeWaypoint(questID)
    if not (C_QuestLog and C_QuestLog.GetNextWaypoint) then return nil end
    local mapID, x, y = Try(C_QuestLog.GetNextWaypoint, questID)
    if type(mapID) == "number" and type(x) == "number" and type(y) == "number"
        and not Secret(x) and not Secret(y) then
        return mapID, x, y
    end
    return nil
end

---------------------------------------------------------------------------
-- Debug snapshot: everything needed to diagnose a wrong list from disk
---------------------------------------------------------------------------

local function Has(tbl, key)
    return type(tbl) == "table" and type(tbl[key]) == "function"
end

function Data.DebugDump()
    local dump = {
        version = ns.version,
        locale = type(GetLocale) == "function" and GetLocale() or nil,
        build = { Try(rawget(_G, "GetBuildInfo")) },
        faction = Try(rawget(_G, "UnitFactionGroup"), "player"),
        api = {
            questieDB = Data.DB() ~= nil,
            questieContract = type(rawget(_G, "LibQuestieDB")) == "table" and LibQuestieDB.contractVersion or nil,
            questie = rawget(_G, "QuestieLoader") ~= nil,
            tomtom = rawget(_G, "TomTom") ~= nil,
            hbd = ns.Geo.HasHBD(),
            modernQuestLog = Has(C_QuestLog, "GetInfo"),
            getNextWaypoint = Has(C_QuestLog, "GetNextWaypoint"),
            userWaypoint = Has(C_Map, "SetUserWaypoint"),
            superTrack = type(C_SuperTrack) == "table" and Has(C_SuperTrack, "SetSuperTrackedUserWaypoint"),
            containerQuestInfo = Has(C_Container, "GetContainerItemQuestInfo"),
            readyForTurnIn = Has(C_QuestLog, "ReadyForTurnIn"),
        },
        nav = ns.Nav.State(),
        windowOpen = ns.IsOpen(),
        quests = {},
        bagItems = {},
    }

    local plan = ns.Plan.Build()
    dump.free = plan.free
    dump.readySlots = plan.readySlots
    -- Quest items no quest in the log wants, and why each is listed or kept.
    dump.leftovers = {}
    for _, list in ipairs({ plan.orphans, plan.kept or {} }) do
        for _, item in ipairs(list) do
            dump.leftovers[#dump.leftovers + 1] = {
                id = item.id, name = item.name, status = item.status,
                quests = item.quests, reward = item.reward or nil,
            }
        end
    end
    dump.hiddenQuests = plan.hidden

    for _, quest in ipairs(plan.all) do
        local info = Data.Static(quest.id)
        local entry = {
            id = quest.id, title = quest.title, complete = quest.complete, failed = quest.failed,
            ready = quest.ready, slots = quest.slots, objectives = quest.objectives,
            inDB = info ~= nil,
            dbHasObjectives = info and info.hasObjectives or nil,
            dbHasTrigger = info and info.hasTrigger or nil,
            finishers = info and info.finishers or nil,
            nativeWaypoint = { Data.NativeWaypoint(quest.id) },
            -- What the client itself says, to check the "ready" rule against.
            readyForTurnIn = C_QuestLog and Try(C_QuestLog.ReadyForTurnIn, quest.id),
            items = {},
        }
        for _, item in ipairs(quest.items) do
            entry.items[#entry.items + 1] = { id = item.id, name = item.name, slots = item.slots, count = item.count }
        end
        if quest.target then
            local t = quest.target
            entry.target = {
                name = t.name, mapId = t.mapId, x = t.x, y = t.y, dist = t.dist, zone = t.zone,
                areaId = t.areaId, dungeon = t.dungeon, friendly = t.friendly, native = t.native,
                corrected = t.corrected,
                eta = t.eta, legs = t.legs,
            }
        end
        dump.quests[#dump.quests + 1] = entry
    end

    -- The quest the arrow points at right now (set by the open window, not by
    -- the plan rebuilt above).
    local live = ns.IsOpen() and ns.state.plan or nil
    dump.current = live and live.current or nil
    dump.player = ns.Geo.PlayerDebug()
    dump.trail = ns.Trail.State()
    dump.flights = {
        known = type(DropOffCharDB) == "table" and DropOffCharDB.flights or nil,
        seen = type(DropOffCharDB) == "table" and DropOffCharDB.flightsSeen or nil,
        nodesForMap = Has(rawget(_G, "C_TaxiMap"), "GetTaxiNodesForMap"),
        allTaxiNodes = Has(rawget(_G, "C_TaxiMap"), "GetAllTaxiNodes"),
        openMap = type(rawget(_G, "OpenMapAPI")) == "table" and OpenMapAPI.version or nil,
    }
    dump.passes = ns.Route.PassState()
    dump.walk = ns.Walk and ns.Walk.State() or nil
    dump.window = {
        compact = ns.UI.IsCompact(),
        minimapIcon = ns.MinimapButton.State(),
    }

    local bags = Data.ScanBags()
    for itemID, item in pairs(bags) do
        local name, _, classID = Data.ItemInfo(itemID)
        local startsQuest = Data.ItemStartsQuest(itemID)
        if classID == QUEST_ITEM_CLASS or plan.tied[itemID] or startsQuest or item.startsQuest then
            dump.bagItems[#dump.bagItems + 1] = {
                id = itemID, name = name, classID = classID, slots = item.slots, count = item.count,
                tied = plan.tied[itemID] and true or false,
                startsQuest = startsQuest,
                gameStartsQuest = item.startsQuest,
            }
        end
    end
    return dump
end

Data.QUEST_ITEM_CLASS = QUEST_ITEM_CLASS
