# Changelog

## 0.4.1

- The passes between zones are now entered by hand, as points of the zone maps that the game places when the routes are built. Nothing in the addon comes from Polestar any more, and `LICENSES/Polestar.txt` is gone.
- They are approximate: one pass per road, bridge or tunnel, a few hundred yards off at worst.
- Mulgore to Desolace goes through the plateau between them, at its airship mooring.
- Thirteen links of the old table are no longer walked, because they are a swim along a coast, a climb, or a link I cannot vouch for: Durotar to Azshara, Mulgore to Stonetalon, Thousand Needles to Dustwallow, Dustwallow to Tanaris, Alterac to Silverpine, Arathi to the Hinterlands, Tirisfal to the Eastern Plaguelands, the Eastern Plaguelands to the Hinterlands, Dun Morogh to the Searing Gorge, Dun Morogh to the Wetlands, the Burning Steppes to Elwynn, Redridge to the Swamp of Sorrows, Stranglethorn to Westfall. If WoW Forever joins two of these on foot, tell me and the pass goes in.
- A pass the game cannot place yet is left out and asked for again; the two zones stay apart meanwhile. `/dropoff debug` records how many passes were placed.

## 0.4.0

- The trip is drawn as a solid line on the world map, on OpenMap's stitched map and on the game's own. The line keeps its width at any zoom.
- The dots stay under the line on the world map for now, so the trip still shows if the line cannot be drawn. The minimap keeps its dots.

## 0.3.1

- A walk now changes zone only where the zones join. Before, a trip could end with a walk in a straight line across a mountain range. The pass shows as a step of its own ("Walk on into the next zone: Desolace") and the line on the map goes through it.
- Zones the pass table does not know (Riverglades, Mount Hyjal, Zephras Isle) keep the straight-line estimate.
- Pass positions come from the chokepoint list of Polestar's walking maps (GNU GPL version 3, `LICENSES/Polestar.txt`).

## 0.3.0

- The whole trip to a hand-in: flight paths, zeppelins, boats, then the walk. The steps are listed under the current quest with a time estimate.
- The arrow points at the next stop of the trip (a flight master, a dock), then at the hand-in.
- The trip is drawn as a dotted line on the world map and the minimap.
- Finished quests are sorted by travel time. A hand-in on another continent shows minutes instead of "far".
- DropOff learns your flight paths when you open a flight map. Until then it takes them as known and says so.
- Flight master and dock positions come from OpenMap's data tables (MIT).

## 0.2.2

- With the OpenMap addon, the map button now moves the map onto the hand-in. Before, a hand-in near the edge of a zone could be outside the part of the map on screen.

## 0.2.1

- The window now sits below the world map, so it no longer hides a map pin near the edge.

## 0.2.0

- Map button on each finished quest: heads there first and opens the world map on the hand-in zone.

## 0.1.0

First version.

- Lists finished quests, holding bag items first, nearest hand-in first.
- Points the way with TomTom, or the game's map pin without it.
- Lists quests in progress that hold items, and quest items tied to no quest.
- Chat hint when bags are nearly full and finished quests hold slots.
- Says how many quests it cannot read because their quest log header is collapsed.
- English and French.
