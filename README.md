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
| [Polestar](https://github.com/fitzforge/polestar) (optional) | Real walking paths. With Polestar, its "Polestar Nav" part and the walking maps of your continent enabled, the walks follow the roads and go round the mountains. Without it they are straight lines. |

## How the trip is planned

The trip is an estimate. DropOff knows where every flight master and every boat, zeppelin and airship dock is, and how long each flight path is. It picks the fastest chain of those, with walks in between. A walk is a straight line inside a zone and changes zone only where the zones join, so it does not cross a mountain range between two zones. It does not follow roads, and it cannot see a cliff inside a zone. The window then says the walking distances are as the crow flies.

When Polestar's walking router is loaded, DropOff asks it for the real way on foot of the trip the arrow is on. The line, the dots, the arrow and the distance then follow that path, a few seconds after the trip first shows. DropOff holds none of Polestar's code or maps and does not load it: it calls the router only when Polestar has already loaded it. The router loads its own maps of a continent at the first search there. The choice between walking and flying, and the order of the list, still use straight lines.

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

DropOff liste les quêtes déjà terminées, indique combien d'emplacements de sac chacune libère, et te guide vers la plus rapide à rendre d'abord. Sous la quête en cours, il affiche tout le trajet, étape par étape : rejoindre le maître de vol, prendre le vol, le zeppelin ou le bateau, puis finir à pied, avec une durée estimée. Le trajet est aussi tracé d'un trait sur la carte du monde et en pointillés sur la minicarte. Tape `/dropoff` ou clique sur l'icône de la minicarte pour ouvrir la fenêtre : tant qu'elle est ouverte, la flèche pointe vers la prochaine étape. Le bouton à gauche de la croix la réduit à la prochaine quête à rendre, sans arrêter le guidage. Questie donne les lieux, TomTom affiche la flèche (sinon c'est le repère de carte du jeu). Avec Polestar et ses cartes de marche activés, les trajets à pied suivent le vrai chemin ; sans lui, ce sont des lignes droites, et la fenêtre le dit : « à vol d'oiseau ».

## Development

```sh
luajit tests/run.lua     # offline tests against a mocked WoW API
./tools/install.sh       # copy the addon into _forever_/Interface/AddOns
tools/build_travel_data.py <OpenMap folder>   # regenerate TravelData.lua
```

DropOff reads Questie's data through the public `LibQuestieDB` API at run time and embeds no library. Pushing a `v*` tag builds the zip with the BigWigs packager.

## License

MIT. `TravelData.lua` is generated from the data tables of [OpenMap](https://github.com/openmap-world/openmap), also MIT: see `LICENSES/OpenMap.txt`. `Passes.lua` was entered by hand.
