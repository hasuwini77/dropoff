local _, ns = ...

-- The lifts a character rides on foot. The walking maps (DropOff_Paths_*)
-- hold the ground at both ends of a lift but not the ride: Walk.lua joins a
-- path to one end with a path from the other.
--
-- The positions are the lift docks of Shortest Path Forever v1.43.2 (its
-- Data/Transports.lua, docks 1001 to 1014; GPL-3.0-or-later, see
-- LICENSES/ShortestPathForever.txt), which took them from the game client's
-- tables and CMaNGOS classic-db.
--
-- { continent, x, y, height of the top, height of the bottom }, in the game's
-- world yards. Both ends of a lift share x and y.
ns.TravelLifts = {
    { 1, -4668.1, -1838.64, 85.407, -44.019 },      -- the Great Lift, the Barrens - Thousand Needles
    { 1, -5390.845, -2497.02, 89.023, -40.404 },    -- Freewind Post, Thousand Needles
    { 1, -1297.31, 187.505, 130.082, 68.711 },      -- Thunder Bluff, west lift
    { 1, -1032.655, -38.796, 140.497, 69.148 },     -- Thunder Bluff, north lift
    { 0, 1596.15, 291.8, 55.718, -40.784 },         -- Undercity, west lift
    { 0, 1595.26, 188.644, 55.718, -40.783 },       -- Undercity, east lift
    { 0, 1544.24, 240.773, 55.718, -40.783 },       -- Undercity, south lift
}
