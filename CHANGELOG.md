# Changelog

## Unreleased

- A welcome window on the first login, in four short steps: what DropOff solves, what it needs (Questie, TomTom, the three map addons, each checked live), two settings (minimap button, bag alert in chat), and how to open it. Skip, Close or finishing it sets a flag and it does not come back. It waits for the end of a fight.
- `/dropoff welcome` opens it again at step 1.
- New file `Welcome.lua`: the game must be fully restarted once, a /reload is not enough.
- Not yet checked in game.
- The "quest items without a quest" list no longer tells you to drop things you need. An item now says it can go only when QuestieDB shows every quest that uses it is handed in. Items for quests you have not taken yet, and items a quest gives as a reward (an engineers' membership card), are left off the list. Items the database does not know say "check before you drop it".
- `/dropoff debug` now records each of those items and why it is listed or kept.

## 0.8.3

- With the Combat Log tab picked, the window now stops above its filter bar ("My actions / What happened to me?") and the tabs, instead of covering them.
- The minimap line now shows without TomTom too. It needed HereBeDragons, which comes with TomTom, to read where you stand; it now falls back to the game's own map calls.
- The shrink / expand button is bigger, closer to the size of the close button.

## 0.8.2

- The full window no longer runs over the chat. A long list stops just above the chat box (or the screen edge) and scrolls with the mouse wheel. A line at the bottom says how much is below or above, in French "+N en dessous (molette)".
- A thin scroll marker on the right edge shows where you are in the list. Faint at rest, gold while the wheel turns.
- The wheel only scrolls the window while the list is too long, and never in the small window: over a short list it still zooms the camera.
- Also works with the Combat Log tab picked.
- Checked in game, except the Combat Log case.

## 0.8.1

- First release on CurseForge. Same addon as 0.8.0: no change in game.
- Author shown in the addon list: Hasuwini77 (Team Baguette).

## 0.8.0

- A line on the minimap. The trip is drawn there as on the world map: a plain line from you to the next stop, yellow for a walk, following the real path turn by turn, cut at the rim of the minimap. No dots. It moves with you at every frame and turns with a minimap set to rotate.
- The marker of the next stop stays on the rim of the minimap.
- If the minimap line cannot be drawn, it is left out: the marker stays, and the world map keeps its line.
- `/dropoff debug` records how far the minimap shows and where that figure comes from, how many lines are on it, and where DropOff and the pin library each place the next stop, to compare.
- Not yet checked in game.

## 0.7.1

- Wrong hand-in fixed: Elemental Aid (Soutien élémentaire) sent a Horde shaman to Bath'rah in the Alterac Mountains. In WoW Forever it ends at Rau Cliffrunner, Freewind Post. Questie's Forever database names both, and DropOff took the nearest. DropOff now keeps a short list of Forever corrections for such quests: this one, seen in game, and Storm, Earth, and Fire of the same chain, from Forever data only.
- DropOff has no quest database of its own: it reads Questie's Forever one. A hand-in that is wrong there is wrong here until it is added to that list. `tools/compare_finishers.py` lists the quests where the two Forever databases installed in the game disagree (65 today); none of the others is settled.
- No more dots. The trip is the line on the world map, with a marker at each change of transport and at the hand-in. Dots come back only on a map that cannot take a line. The minimap keeps the marker of the next stop and has no dots.
- `/dropoff debug` records whether a hand-in was corrected, and whether the trip is drawn as a line or as dots.
- Not yet checked in game.

## 0.7.0

- DropOff finds the real way on foot itself. No other addon is needed: Polestar is no longer used. The walking router and its maps are those of Shortest Path Forever by Cillian Berragan, embedded with their licence.
- Lifts. The way goes down or up a lift when that is shorter, or the only way: Thunder Bluff, the Undercity, the Great Lift, Freewind Post. A line under the steps says "On the way: take the lift." The arrow stops at the lift until you reach it. One lift at most per walk.
- A hand-in standing over or under another floor (a mine under a hill, the Undercity under its ruins) is reached on its own floor. In the Undercity the walk starts on the city's floor.
- The walks on the other continent of a trip are real paths too.
- New folders: the walking maps come as three addons of their own, `DropOff_Paths_EasternKingdoms`, `DropOff_Paths_Kalimdor` and `DropOff_Paths_Zephras` (about 23 MB together). The game reads one only at the first walk on that continent, which takes a moment, and never during a fight. Quit the game and start it again after installing: `/reload` is not enough, and the walks stay straight lines until then. If the three show as disabled in the addon list, enable them.
- Licence: DropOff is under the GNU General Public License, version 3 or later, from this version on, because it embeds GPL code and data. 0.6.0 is the last MIT version. See `LICENSES/ShortestPathForever.txt`.
- `/dropoff debug` records, per continent, whether the maps are in memory, what the game answered when they were asked for, how many searches a walk took, the way straight there beside the way kept, and whether it takes a lift.
- The order of the list and the choice between walking and flying still compare straight lines.
- The way on foot is the shortest one: it does not keep away from the other faction's towns, as 0.6.0 did through Polestar.
- Not yet checked in game. Outside it, the router finds about three kilometres from the Thunder Bluff flight master to Ghost Walker Post, down a lift, where the straight line is 1 700 yards through the cliff.

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
