# Publishing DropOff on CurseForge

Publishing is free. It needs a CurseForge author account, which is why the project itself has to be created by hand.

## Before you start

- Check the addon in game first: `/dropoff`, hand in one quest, watch the arrow move to the next.
- Make the GitHub repo public, otherwise the source and issue links below lead nowhere:
  `gh repo edit hasuwini77/dropoff --visibility public --accept-visibility-change-consequences`
- Have a square logo ready, 400x400 or larger.

## Create the project

1. Open https://authors.curseforge.com/ and start a new project. Game: World of Warcraft. Type: Addons.
2. Name: `DropOff`
3. Summary: paste the English summary below.
4. Description: paste the English description, then the French one under it.
5. Categories: Quests & Leveling as the main one, Bags & Inventory as the second.
6. License: MIT.
7. Source: `https://github.com/hasuwini77/dropoff`. Issues: `https://github.com/hasuwini77/dropoff/issues`.
8. Upload the logo and submit. CurseForge reviews new projects before they show up in search.

## Wire up automatic uploads

1. Copy the numeric Project ID from the project page and add it to `DropOff.toc`:
   `## X-Curse-Project-ID: <id>`
2. Create an API token at https://authors.curseforge.com/#/settings/api-tokens and store it as a repo secret:
   `gh secret set CF_API_TOKEN --repo hasuwini77/dropoff`
3. Set `## Version: 0.2.1` in the same file and add a `0.2.1` entry to `CHANGELOG.md`. The version shown in game comes from the TOC, not from the tag.
4. Commit, then tag and push:
   `git tag v0.2.1 && git push origin v0.2.1`

The release workflow runs the tests, builds `DropOff-<tag>.zip`, attaches it to a GitHub release and uploads it to CurseForge. The packager reads `## Interface: 16001` and files the upload under WoW Forever.

The `v0.1.0` and `v0.2.0` tags were pushed before the workflows existed, so they have no zip. The first file on CurseForge is `v0.2.1`.

## Summary (English)

```
Lists your finished quests, shows the bag slots each one frees, and points you to the nearest turn-in.
```

## Summary (French)

```
Liste tes quêtes terminées, les emplacements de sac que chacune libère, et te guide vers la plus proche.
```

## Description (English)

```
DropOff is for the moment your bags are full and half of what is in them is quest items.

It reads your bags and your quest log, finds the quests you have already finished, and tells you how many bag slots each one gives back when you hand it in. Quests holding items come first, and among those the nearest hand-in comes first. Open the window and an arrow points to the first one. Hand it in and the arrow moves to the next.

What you get

- A list of finished quests, with the slots each one frees and the distance to the hand-in.
- An arrow to the next one. It uses TomTom if you have it and the game's own map pin if you don't.
- Click a quest to go there first. Click it again to go back to nearest first.
- The map icon next to a quest opens the world map on its hand-in.
- Two more lists, without directions for now: quests in progress that hold items, and quest items that belong to no quest in your log.
- One chat line when your bags are nearly full and finished quests are holding slots. Type /dropoff alert to turn it off.

Requirements

- Questie, for the hand-in locations. Without it you still get the list and the slot counts, but no directions.
- TomTom is optional.

Commands

- /dropoff or /dof opens and closes the window. DropOff guides you while it is open.
- /dropoff list prints the route in chat.
- /dropoff alert switches the bag hint on or off.
- /dropoff debug saves a snapshot you can attach to a bug report.

Made for WoW Forever, in English and French. Directions for quests still in progress are planned for a later version.

Found a wrong list or a missing hand-in? Open an issue: https://github.com/hasuwini77/dropoff/issues
```

## Description (French)

```
DropOff sert au moment où tes sacs sont pleins et que la moitié du contenu, ce sont des objets de quête.

L'addon lit tes sacs et ton journal de quêtes, repère les quêtes déjà terminées et t'indique combien d'emplacements chacune libère quand tu la rends. Les quêtes qui occupent des emplacements passent en premier, et parmi elles la plus proche d'abord. Ouvre la fenêtre : une flèche pointe vers la première. Rends-la et la flèche passe à la suivante.

Ce que tu as

- La liste des quêtes terminées, avec les emplacements libérés et la distance jusqu'au PNJ.
- Une flèche vers la prochaine. Elle passe par TomTom si tu l'as, sinon par le repère de carte du jeu.
- Clique sur une quête pour y aller en premier. Clique à nouveau pour revenir à la plus proche d'abord.
- L'icône de carte à côté d'une quête ouvre la carte du monde sur l'endroit où la rendre.
- Deux autres listes, sans guidage pour l'instant : les quêtes en cours qui occupent des emplacements, et les objets de quête liés à aucune quête de ton journal.
- Une ligne dans le chat quand tes sacs sont presque pleins et que des quêtes terminées occupent des emplacements. Tape /dropoff alert pour la couper.

Prérequis

- Questie, pour savoir où rendre chaque quête. Sans lui tu gardes la liste et le nombre d'emplacements, mais pas le chemin.
- TomTom est facultatif.

Commandes

- /dropoff ou /dof ouvre et ferme la fenêtre. DropOff te guide tant qu'elle est ouverte.
- /dropoff list affiche l'itinéraire dans le chat.
- /dropoff alert active ou coupe l'alerte de sacs.
- /dropoff debug enregistre un instantané à joindre à un rapport de bug.

Conçu pour WoW Forever, en français et en anglais. Le guidage des quêtes encore en cours est prévu pour une prochaine version.

Une liste fausse ou un PNJ introuvable ? Ouvre un ticket : https://github.com/hasuwini77/dropoff/issues
```
