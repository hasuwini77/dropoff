# DropOff

Bags full of quest items? DropOff lists the quests you have already finished, tells you how many bag slots each one frees, and points you to the nearest hand-in first.

Built for **WoW Forever** (interface 16001). English and French.

## What it does

- Scans your bags and your quest log.
- Finds the finished quests, including deliveries that are ready the moment you accept them.
- Sorts them: quests holding bag items first, nearest hand-in first.
- Points the way to the first one. Hand it in and the arrow moves to the next.
- Also lists, without guidance for now:
  - quests in progress that hold items,
  - quest items tied to no quest in your log (leftovers, or items that start a quest).
- When your bags are nearly full and finished quests are holding slots, a single chat line reminds you.

## Requirements

| Addon | Needed for |
|---|---|
| [Questie](https://www.curseforge.com/wow/addons/questie) | Where each quest is handed in. Without it you still get the list and the slot counts, but no directions. |
| [TomTom](https://www.curseforge.com/wow/addons/tomtom) (optional) | The arrow. Without it DropOff places the game's own map pin. |

## Commands

- `/dropoff` (or `/dof`): open or close the window. Open means guiding, closed means off.
- `/dropoff list`: print the route in chat.
- `/dropoff alert`: switch the "bags nearly full" hint on or off.
- `/dropoff debug`: save a snapshot for bug reports (see below).

Click a row to head there first. Click it again to go back to nearest first. The map icon at the right of a row heads there too and opens the world map on the hand-in zone; it never unpins. Drag the window to move it.

## Reporting a wrong list

1. Type `/dropoff debug`, then `/reload`.
2. Attach `WTF/Account/<account>/SavedVariables/DropOff.lua` to your issue.

The snapshot holds your quest log, the quest items in your bags and where DropOff thinks each quest is handed in. Nothing else.

## En français

DropOff liste les quêtes déjà terminées, indique combien d'emplacements de sac chacune libère, et te guide vers le PNJ le plus proche d'abord. Tape `/dropoff` pour ouvrir la fenêtre : tant qu'elle est ouverte, la flèche pointe vers la prochaine quête à rendre. Questie donne les lieux, TomTom affiche la flèche (sinon c'est le repère de carte du jeu).

## Development

```sh
luajit tests/run.lua     # offline tests against a mocked WoW API
./tools/install.sh       # copy the addon into _forever_/Interface/AddOns
```

DropOff reads Questie's data through the public `LibQuestieDB` API at run time and embeds no library. Pushing a `v*` tag builds the zip with the BigWigs packager.

## License

MIT
