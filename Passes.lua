-- Where a character can walk from one zone into the next in WoW Forever.
-- The route planner lets a walk change zone only at one of these points, so
-- a trip never ends with a walk across a mountain range or a stretch of sea.
--
--   cities[uiMapID] = the zone a city stands in: it counts as that zone
--   zones[uiMapID]  = continent (0 Eastern Kingdoms, 1 Kalimdor). A zone with
--                     no pass is an island: Teldrassil
--   names[name]     = the zone, as the flight masters' names spell it
--   docks[key]      = the zone of a dock with no flight master near it,
--                     key: "continent:x:y" as the travel data gives them
--   passes[i]       = { zone, zone, map, x, y }: a point of `map` (one of the
--                     two zones), x and y in percent as the world map shows
--                     them. The game turns it into world yards when the
--                     routes are built. With `map` false, x and y are world
--                     yards already (x north, y west).
--
-- A zone that is not listed (Riverglades, Mount Hyjal, Zephras Isle) is not
-- checked: walks to and from it are straight lines, as before.
--
-- Every pass was entered by hand, from where the road crosses on the zone
-- maps. They are approximate: a few hundred yards off at worst, which moves
-- the line on the map and the walking estimate, not the choice of zones.
-- Only links walked on a road, a bridge or through a tunnel are listed: no
-- swim along a coast, no climb.

local _, ns = ...

ns.TravelPasses = {
    cities = {
        [1453] = 1429,   -- Stormwind, Elwynn Forest
        [1454] = 1411,   -- Orgrimmar, Durotar
        [1455] = 1426,   -- Ironforge, Dun Morogh
        [1456] = 1412,   -- Thunder Bluff, Mulgore
        [1457] = 1438,   -- Darnassus, Teldrassil
        [1458] = 1420,   -- Undercity, Tirisfal Glades
    },
    zones = {
        [1411] = 1, [1412] = 1, [1413] = 1, [1416] = 0, [1417] = 0, [1418] = 0, [1419] = 0, [1420] = 0,
        [1421] = 0, [1422] = 0, [1423] = 0, [1424] = 0, [1425] = 0, [1426] = 0, [1427] = 0, [1428] = 0,
        [1429] = 0, [1430] = 0, [1431] = 0, [1432] = 0, [1433] = 0, [1434] = 0, [1435] = 0, [1436] = 0,
        [1437] = 0, [1438] = 1, [1439] = 1, [1440] = 1, [1441] = 1, [1442] = 1, [1443] = 1, [1444] = 1,
        [1445] = 1, [1446] = 1, [1447] = 1, [1448] = 1, [1449] = 1, [1450] = 1, [1451] = 1, [1452] = 1,
    },
    names = {
        ["Durotar"] = 1411, ["Mulgore"] = 1412, ["The Barrens"] = 1413, ["Arathi"] = 1417,
        ["Badlands"] = 1418, ["Blasted Lands"] = 1419, ["Tirisfal"] = 1420, ["Silverpine Forest"] = 1421,
        ["Western Plaguelands"] = 1422, ["Eastern Plaguelands"] = 1423, ["Hillsbrad"] = 1424,
        ["The Hinterlands"] = 1425, ["Dun Morogh"] = 1426, ["Searing Gorge"] = 1427,
        ["Burning Steppes"] = 1428, ["Elwynn"] = 1429, ["Duskwood"] = 1431, ["Loch Modan"] = 1432,
        ["Redridge"] = 1433, ["Stranglethorn"] = 1434, ["Swamp of Sorrows"] = 1435, ["Westfall"] = 1436,
        ["Wetlands"] = 1437, ["Teldrassil"] = 1438, ["Darkshore"] = 1439, ["Ashenvale"] = 1440,
        ["Thousand Needles"] = 1441, ["Stonetalon Mountains"] = 1442, ["Desolace"] = 1443,
        ["Feralas"] = 1444, ["Dustwallow Marsh"] = 1445, ["Tanaris"] = 1446, ["Azshara"] = 1447,
        ["Felwood"] = 1448, ["Un'Goro Crater"] = 1449, ["Moonglade"] = 1450, ["Silithus"] = 1451,
        ["Winterspring"] = 1452,
    },
    docks = {
        ["0:544.8:424.2"] = 1416,   -- the airship tower in the Alterac Mountains
    },
    passes = {
        -- Kalimdor
        { 1411, 1413, 1411, 34.5, 42.5 },   -- the bridge over the Southfury River, west of Razor Hill
        { 1412, 1413, 1412, 68.5, 60.5 },   -- the road out of Mulgore, to Camp Taurajo
        { 1412, 1443, false, -802, 366.5 }, -- WoW Forever: the plateau between them, at its airship mooring
        { 1413, 1440, 1440, 68.5, 87 },     -- the Mor'shan Rampart
        { 1413, 1442, 1413, 35.5, 27.5 },   -- Honor's Stand
        { 1413, 1445, 1413, 50, 78.5 },     -- the road east into the marsh
        { 1413, 1441, 1441, 32, 22 },       -- the Great Lift
        { 1440, 1442, 1440, 42.5, 71 },     -- the Talondeep Path
        { 1442, 1443, 1443, 54, 5 },        -- the road south out of the Charred Vale
        { 1443, 1444, 1444, 44.5, 6 },      -- the road south, to the Twin Colossals
        { 1441, 1444, 1444, 89, 45.5 },     -- the road east out of Feralas
        { 1441, 1446, 1446, 51.5, 20.5 },   -- the pass north of Gadgetzan
        { 1446, 1449, 1449, 70.5, 77.5 },   -- the ramp down into the crater
        { 1449, 1451, 1449, 29.5, 22.5 },   -- the ramp up to Silithus
        { 1439, 1440, 1439, 43.5, 93 },     -- the road south along the coast
        { 1440, 1448, 1440, 55.5, 29 },     -- the road north into Felwood
        { 1440, 1447, 1440, 93.5, 47.5 },   -- the road east into Azshara
        { 1448, 1452, 1448, 65, 8 },        -- Timbermaw Hold
        { 1448, 1450, 1448, 65, 8 },        -- Timbermaw Hold
        -- Eastern Kingdoms
        { 1420, 1421, 1421, 67, 5 },        -- the road south into Silverpine
        { 1420, 1422, 1422, 28, 57 },       -- the Bulwark
        { 1421, 1424, 1424, 13.5, 46.5 },   -- the road east into Hillsbrad
        { 1416, 1424, 1424, 55, 12 },       -- the road north of Tarren Mill
        { 1416, 1422, 1422, 44.5, 86.5 },   -- the road south of Chillwind Camp
        { 1417, 1424, 1417, 20.5, 30 },     -- the road west out of Arathi
        { 1424, 1425, 1425, 7, 48.5 },      -- the path up into the Hinterlands
        { 1422, 1425, 1425, 24, 30 },       -- the path north of Aerie Peak
        { 1422, 1423, 1422, 69.5, 50 },     -- the bridge over the Thondroril River
        { 1417, 1437, 1437, 51.5, 9.5 },    -- the Thandol Span
        { 1432, 1437, 1437, 53, 71 },       -- Dun Algaz
        { 1426, 1432, 1426, 86, 51 },       -- the gate passes east of Dun Morogh
        { 1418, 1432, 1432, 47, 78 },       -- the road south out of Loch Modan
        { 1418, 1427, 1418, 5.5, 61 },      -- the pass west out of the Badlands
        { 1427, 1428, 1427, 34.5, 85 },     -- Blackrock Mountain
        { 1428, 1433, 1433, 33, 7.5 },      -- the road north out of Redridge
        { 1429, 1433, 1429, 93, 72.5 },     -- the Three Corners
        { 1431, 1433, 1431, 93.5, 10.5 },   -- the bridge at the Three Corners
        { 1429, 1431, 1431, 20, 14 },       -- the bridges over the river north of Duskwood
        { 1429, 1431, 1431, 45, 9 },
        { 1429, 1431, 1431, 75, 16 },
        { 1431, 1436, 1431, 8, 35 },        -- the river west of Duskwood
        { 1431, 1436, 1431, 8, 64 },
        { 1430, 1431, 1431, 92.5, 41 },     -- the road east into Deadwind Pass
        { 1429, 1436, 1429, 21, 80 },       -- the bridge to Westfall
        { 1431, 1434, 1434, 39, 3.5 },      -- the road south into Stranglethorn
        { 1430, 1435, 1435, 4, 36 },        -- the road east out of Deadwind Pass
        { 1419, 1435, 1419, 51, 6.5 },      -- the road south into the Blasted Lands
    },
}
