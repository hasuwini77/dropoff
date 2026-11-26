# CurseForge description

Paste each block into the project description (Markdown editor). English first, French under it.
Replace each `[capture N]` line with the screenshot uploaded to the project's Images tab.

## English

```markdown
# DropOff

**Your bags are full and half of it is quest items. DropOff shows which finished quests free the most slots, then walks you to the turn-in, step by step.**

Made for WoW Forever, in English and French.

[capture 1: the window with the finished quests and the slots each frees]

**At a glance**

- **Finished quests first**: every quest you can hand in now, with the bag slots it frees.
- **Quickest first**: among those, the closest hand-in comes first.
- **The whole trip**: flight master, flight, zeppelin or boat, then the walk, with a time estimate.
- **Real walking paths**: along the roads, round the mountains, down a lift when that is the way.
- **Drawn on your maps**: a line on the world map, a yellow line on the minimap.
- **An arrow**: TomTom's if you have it, the game's map pin if you don't.
- **Stays out of the way**: a compact mode, and a long list stops above your chat and scrolls.
- **Optional auto-flight**: off by default. Open the right flight master's map and DropOff takes the suggested flight. Hold Shift to choose yourself.
- **A bag hint**: one chat line when your bags are nearly full and finished quests hold slots.

## Open it

Type `/dropoff` (or `/dof`), or click the minimap button. DropOff guides you while the window is open. Hand the quest in and the window moves to the next one.

Click a quest to go there first. Click it again to go back to quickest first. The map icon next to a quest opens the world map on its hand-in.

## The trip, step by step

[capture 2: the world map with the trip drawn as a line]

Each step is a line in the window: walk to the flight master, fly to Orgrimmar, take the zeppelin, walk to the quest giver. DropOff learns your flight paths when you open a flight map and only uses the ones you know. Until you open one, it takes them all as known.

The walk follows the terrain. While the path is being worked out the window says "as the crow flies", then the line follows the road.

[capture 3: the minimap with the yellow line]

## Two more lists

- **Quests in progress** that hold items, so you see what takes space before it is done.
- **Quest items with no quest** in your log. DropOff says an item can go only when every quest that uses it is handed in. Rewards you keep, like a membership card, never show up.

These two have no directions yet.

## Commands

| Command | What it does |
|---|---|
| `/dropoff` or `/dof` | Opens and closes the window |
| `/dropoff list` | Prints the route in chat |
| `/dropoff alert` | Turns the bag hint on or off |
| `/dropoff debug` | Saves a snapshot to attach to a bug report |

## Good to know

- **Questie**: needed for the hand-in locations. Without it you keep the list and the slot counts, but get no directions.
- **TomTom**: optional. The arrow and the minimap line work without it.
- **The three DropOff_Paths folders**: leave them enabled, they hold the walking maps.
- **Credits**: walking router and maps from Shortest Path Forever by Cillian Berragan (GPLv3). Travel data from OpenMap (MIT). Hand-in locations from Questie.

## Bugs and ideas

Wrong list, missing NPC, odd path? Open an issue with your `/dropoff debug` snapshot: https://github.com/hasuwini77/dropoff/issues

Made by **Hasuwini77** (Team Baguette, WoW Forever EU).
```

## French

```markdown
# DropOff

**Tes sacs sont pleins et la moitié, ce sont des objets de quête. DropOff te montre quelles quêtes terminées libèrent le plus d'emplacements, puis te guide jusqu'au PNJ, étape par étape.**

Conçu pour WoW Forever, en français et en anglais.

[capture 1 : la fenêtre avec les quêtes terminées et les emplacements libérés]

**En bref**

- **Les quêtes terminées d'abord** : chaque quête à rendre maintenant, avec les emplacements qu'elle libère.
- **La plus rapide d'abord** : parmi elles, le PNJ le plus proche passe en premier.
- **Tout le trajet** : maître de vol, vol, zeppelin ou bateau, puis la marche, avec une durée estimée.
- **De vrais chemins à pied** : par les routes, autour des montagnes, par l'ascenseur quand il le faut.
- **Tracé sur tes cartes** : une ligne sur la carte du monde, une ligne jaune sur la minicarte.
- **Une flèche** : celle de TomTom si tu l'as, sinon le repère de carte du jeu.
- **Discret** : un mode compact, et une longue liste s'arrête au-dessus du chat et défile.
- **Vol automatique, en option** : désactivé par défaut. Ouvre la carte du bon maître de vol et DropOff prend le vol conseillé. Garde Maj pour choisir toi-même.
- **Une alerte de sacs** : une ligne dans le chat quand tes sacs sont presque pleins et que des quêtes terminées occupent des emplacements.

## L'ouvrir

Tape `/dropoff` (ou `/dof`), ou clique sur le bouton de la minicarte. DropOff te guide tant que la fenêtre est ouverte. Rends la quête et la fenêtre passe à la suivante.

Clique sur une quête pour y aller en premier. Clique à nouveau pour revenir à la plus rapide d'abord. L'icône de carte à côté d'une quête ouvre la carte du monde sur l'endroit où la rendre.

## Le trajet, étape par étape

[capture 2 : la carte du monde avec le trajet tracé]

Chaque étape est une ligne de la fenêtre : rejoindre le maître de vol, voler jusqu'à Orgrimmar, prendre le zeppelin, finir à pied. DropOff apprend tes trajets de vol quand tu ouvres une carte de vol et n'utilise que ceux que tu connais. En attendant, il les considère tous comme connus.

La marche suit le terrain. Tant que le chemin se calcule, la fenêtre affiche « à vol d'oiseau », puis la ligne suit la route.

[capture 3 : la minicarte avec la ligne jaune]

## Deux autres listes

- **Les quêtes en cours** qui occupent des emplacements, pour voir ce qui prend de la place avant de les finir.
- **Les objets de quête sans quête** dans ton journal. DropOff ne dit qu'un objet peut partir que si toutes les quêtes qui l'utilisent sont rendues. Les récompenses à garder, comme une carte de membre, n'y apparaissent jamais.

Ces deux listes n'ont pas encore de guidage.

## Commandes

| Commande | Ce qu'elle fait |
|---|---|
| `/dropoff` ou `/dof` | Ouvre et ferme la fenêtre |
| `/dropoff list` | Affiche l'itinéraire dans le chat |
| `/dropoff alert` | Active ou coupe l'alerte de sacs |
| `/dropoff debug` | Enregistre un instantané à joindre à un rapport de bug |

## Bon à savoir

- **Questie** : nécessaire pour savoir où rendre chaque quête. Sans lui tu gardes la liste et le nombre d'emplacements, mais pas le chemin.
- **TomTom** : facultatif. La flèche et la ligne de la minicarte marchent sans lui.
- **Les trois dossiers DropOff_Paths** : laisse-les activés, ils contiennent les cartes des chemins à pied.
- **Crédits** : routeur et cartes de Shortest Path Forever par Cillian Berragan (GPLv3). Données de voyage d'OpenMap (MIT). Emplacements des PNJ par Questie.

## Bugs et idées

Liste fausse, PNJ introuvable, chemin bizarre ? Ouvre un ticket avec ton instantané `/dropoff debug` : https://github.com/hasuwini77/dropoff/issues

Fait par **Hasuwini77** (Team Baguette, WoW Forever EU).
```
