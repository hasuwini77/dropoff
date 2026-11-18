# DropOff

Bags full of quest items? DropOff lists the quests you have already finished, tells you how many bag slots each one frees, and takes you to the quickest hand-in first: which flight to take, which zeppelin or boat, then the walk.

Built for **WoW Forever** (interface 16001). English and French.

## What it does

- Scans your bags and your quest log.
- Finds the finished quests, including deliveries that are ready the moment you accept them.
- Sorts them: quests holding bag items first, quickest to reach first.
- Plans the trip to the first one and lists it step by step: go to the flight master, fly, take the zeppelin or the boat, walk to the hand-in. Each trip comes with a time estimate.
- Points the arrow at the next stop of the trip, and draws the trip as a line on the world map and as dots on the minimap.
- Hand the quest in and everything moves to the next one.
- Also lists, without guidance for now:
  - quests in progress that hold items,
  - quest items tied to no quest in your log (leftovers, or items that start a quest).
- When your bags are nearly full and finished quests are holding slots, a single chat line reminds you.

## Requirements

| Addon | Needed for |
|---|---|
| [Questie](https://www.curseforge.com/wow/addons/questie) | Where each quest is handed in. Without it you still get the list and the slot counts, but no directions. |
| [TomTom](https://www.curseforge.com/wow/addons/tomtom) (optional) | The arrow. Without it DropOff places the game's own map pin. |
| [OpenMap](https://github.com/openmap-world/openmap) (optional) | Nothing. If you use it, the map button moves its view onto the hand-in. |

DropOff comes as four folders: `DropOff`, and one folder of walking maps per continent (`DropOff_Paths_EasternKingdoms`, `DropOff_Paths_Kalimdor`, `DropOff_Paths_Zephras`, about 23 MB together). The maps show in the addon list as addons of their own. Leave them enabled: the game reads one only when a trip has a walk on that continent.

## How the trip is planned

The trip is an estimate. DropOff knows where every flight master and every boat, zeppelin and airship dock is, and how long each flight path is. It picks the fastest chain of those, with walks in between. To choose, it counts a walk as a straight line inside a zone, changing zone only where the zones join.

For the trip the arrow is on, DropOff then finds the real way on foot: along the roads, round the mountains and the cliffs, down or up a lift (Thunder Bluff, the Undercity, the Great Lift, Freewind Post). The line, the dots, the arrow and the distance follow that path a few seconds after the trip first shows, and a line under the steps says when the way takes a lift. The first walk on a continent reads that continent's maps, which takes a moment, and never during a fight. Until the path is there, or where there is none, the walk is a straight line and the window says the distances are as the crow flies.

The walking router and its maps are those of [Shortest Path Forever](https://github.com/cjber/shortest-path-forever) by Cillian Berragan, embedded with their licence. No other addon is needed for them.

What it does not do yet: the choice between walking and flying, and the order of the list, still use straight lines. A walk takes one lift at most. The game does not tell an addon how high the player stands, so where two floors lie over each other the walk can start on the wrong one; in the Undercity it starts on the city's floor.

It learns which flight paths your character knows the first time you open a flight map on each continent. Before that it takes them all as known and says so under the steps.

## Commands

- `/dropoff` (or `/dof`), or a click on the minimap icon: open or close the window. Open means guiding, closed means off.
- `/dropoff mini`, the button left of the cross, or a right-click on the minimap icon: the small window (the next hand-in and what to do now) or the whole list. It guides the same in both sizes.
- `/dropoff minimap`: hide the minimap icon or bring it back. Drag it to move it round the minimap.
- `/dropoff list`: print the route in chat.
- `/dropoff alert`: switch the "bags nearly full" hint on or off.
- `/dropoff debug`: save a snapshot for bug reports (see below).

Click a row to head there first. Click it again to go back to nearest first. The map icon at the right of a row heads there too and opens the world map on the hand-in zone; it never unpins. Drag the window to move it.

## Reporting a wrong list

1. Type `/dropoff debug`, then `/reload`.
2. Attach `WTF/Account/<account>/SavedVariables/DropOff.lua` to your issue.

The snapshot holds your quest log, the quest items in your bags and where DropOff thinks each quest is handed in. Nothing else.

## En français

DropOff liste les quêtes déjà terminées, indique combien d'emplacements de sac chacune libère, et te guide vers la plus rapide à rendre d'abord. Sous la quête en cours, il affiche tout le trajet, étape par étape : rejoindre le maître de vol, prendre le vol, le zeppelin ou le bateau, puis finir à pied, avec une durée estimée. Le trajet est aussi tracé d'un trait sur la carte du monde et en pointillés sur la minicarte. Tape `/dropoff` ou clique sur l'icône de la minicarte pour ouvrir la fenêtre : tant qu'elle est ouverte, la flèche pointe vers la prochaine étape. Le bouton à gauche de la croix la réduit à la prochaine quête à rendre, sans arrêter le guidage. Questie donne les lieux, TomTom affiche la flèche (sinon c'est le repère de carte du jeu). Pour le trajet en cours, DropOff calcule lui-même le vrai chemin à pied : par les routes, en contournant les montagnes, en prenant l'ascenseur quand il le faut. Aucun autre addon n'est nécessaire. Les cartes de marche sont dans trois dossiers à part (`DropOff_Paths_*`), à laisser activés. Tant que le chemin n'est pas calculé, le trajet est une ligne droite, et la fenêtre le dit : « à vol d'oiseau ».

## Development

```sh
luajit tests/run.lua     # offline tests against a mocked WoW API
./tools/install.sh       # copy the addon and its map folders into _forever_/Interface/AddOns
tools/vendor-router.sh --check <Shortest Path Forever checkout>   # Router/ and the maps are upstream's, byte for byte
tools/build_travel_data.py <OpenMap folder>   # regenerate TravelData.lua
```

DropOff reads Questie's data through the public `LibQuestieDB` API at run time. `Router/` and the `DropOff_Paths_*` folders are Shortest Path Forever's files, taken by `tools/vendor-router.sh` and never edited by hand; `Walk.lua` is the only file that calls the router. Pushing a `v*` tag builds the zip with the BigWigs packager.

## License

GNU General Public License, version 3 or later (`LICENSE`), from 0.7.0 on. Versions up to 0.6.0 were MIT.

- The walking router (`Router/`), the walking maps (`DropOff_Paths_*`), the spawn heights and the lift positions come from [Shortest Path Forever](https://github.com/cjber/shortest-path-forever) by Cillian Berragan, GPL-3.0-or-later: `LICENSES/ShortestPathForever.txt` says what was taken, from which version, and what was changed.
- `TravelData.lua` is generated from the data tables of [OpenMap](https://github.com/openmap-world/openmap), MIT: see `LICENSES/OpenMap.txt`.
- `Passes.lua` was entered by hand.
