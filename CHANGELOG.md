# Changelog

## 0.6.0

- Real walking paths. When Polestar's walking router is loaded (Polestar with its "Polestar Nav" part and the walking maps of your continent enabled), DropOff asks it for the way on foot and draws that path on the world map and the minimap, round the mountains and along the roads. The step shows the path's real distance and time.
- With a real path, the walk to a zone border is no longer a step of its own: the trip says one walk, to where it ends.
- The arrow follows the path from turn to turn. The hand-in keeps its own pin on the map.
- Without the router every walk is still a straight line, and a line under the steps now says so: "Walking distances are as the crow flies." A plain walk to a hand-in nearby now shows its step and that line too, in both window sizes.
- The order of the list still compares straight lines: only the trip the arrow is on is searched. The choice between walking and flying does not use real walking distances yet.
- DropOff contains nothing of Polestar and never loads it: it calls the router when it is already there. The router loads its own maps of a continent at the first search there. `/dropoff debug` records whether a router was found, what it answered, the straight and the real yards, and how long the search took.
- Not yet checked in game. The first search takes a few seconds, more the first time on a continent.
- This release adds a file: quit the game and start it again, `/reload` is not enough. After a `/reload` alone the walks stay straight lines.

## 0.5.1

- The small window now warns when collapsed quest-log headers hide quests, as the whole list does. Before, it said there was nothing to turn in.
- The size button is a minus (shrink) or a plus (expand).

## 0.5.0

- An icon on the minimap. A click opens or closes DropOff, a right-click switches between the small window and the whole list, and the icon can be dragged round the rim. `/dropoff minimap` hides it or brings it back.
- A small window: the button left of the cross shrinks DropOff to the next hand-in and what to do now. The same button brings the whole list back. The arrow and the line on the map keep running in both sizes, and the size is remembered per character. `/dropoff mini` does the same.
- The cross still closes DropOff and stops the guidance. The minimap icon is the way back in.
- The window now grows and shrinks downwards from its title, which stays where it is.

## 0.4.1

- The passes between zones are now entered by hand, as points of the zone maps that the game places when the routes are built. Nothing in the addon comes from Polestar any more, and `LICENSES/Polestar.txt` is gone.
- They are approximate and not yet checked in game: one pass per road, bridge or tunnel.
- Mulgore to Desolace goes through the plateau between them, at its airship mooring.
- Thirteen links of the old table are no longer walked, because they are a swim along a coast, a climb, or a link I cannot vouch for: Durotar to Azshara, Mulgore to Stonetalon, Thousand Needles to Dustwallow, Dustwallow to Tanaris, Alterac to Silverpine, Arathi to the Hinterlands, Tirisfal to the Eastern Plaguelands, the Eastern Plaguelands to the Hinterlands, Dun Morogh to the Searing Gorge, Dun Morogh to the Wetlands, the Burning Steppes to Elwynn, Redridge to the Swamp of Sorrows, Stranglethorn to Westfall. If WoW Forever joins two of these on foot, tell me and the pass goes in.
- A pass the game cannot place yet is left out and asked for again; the two zones stay apart meanwhile. `/dropoff debug` records how many passes were placed, are still waiting, or landed on the wrong continent.

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
