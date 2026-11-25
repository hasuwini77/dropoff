# Publishing DropOff on CurseForge

The project exists: https://www.curseforge.com/wow/addons/dropoff (ID 1823494, created 2026-11-22, GPLv3, source linked to GitHub, logo `docs/media/logo.png`, painted icon since 2026-11-25). It shows up once a moderator approves it.

Publishing is free. It needs a CurseForge author account, which is why the project itself has to be created by hand.

## Before you start

- Check the addon in game first: `/dropoff`, follow the steps to one hand-in, watch everything move to the next quest.
- Make the GitHub repo public, otherwise the source and issue links below lead nowhere:
  `gh repo edit hasuwini77/dropoff --visibility public --accept-visibility-change-consequences`
- Have a square logo ready, 400x400 or larger.

## Create the project

1. Open https://authors.curseforge.com/ and start a new project. Game: World of Warcraft. Type: Addons.
2. Name: `DropOff`
3. Summary: paste the English summary below.
4. Description: switch the editor to Markdown, paste the English block of `docs/curseforge-description.md`, then the French one under it.
5. Categories: Quests & Leveling as the main one, Bags & Inventory as the second.
6. License: GNU General Public License version 3 (GPLv3). From 0.7.0 on DropOff embeds GPL code and data (`LICENSES/ShortestPathForever.txt`).
7. Source: `https://github.com/hasuwini77/dropoff`. Issues: `https://github.com/hasuwini77/dropoff/issues`.
8. Upload the logo and submit. CurseForge reviews new projects before they show up in search.

## Wire up automatic uploads

1. Copy the numeric Project ID from the project page and add it to `DropOff.toc`:
   `## X-Curse-Project-ID: <id>`
2. Create an API token at https://authors.curseforge.com/#/settings/api-tokens and store it as a repo secret:
   `gh secret set CF_API_TOKEN --repo hasuwini77/dropoff`
3. Set the next version in the same file (`## Version: x.y.z`) and add its entry to `CHANGELOG.md`. The version shown in game comes from the TOC, not from the tag.
4. Commit, then tag and push:
   `git tag vx.y.z && git push origin vx.y.z`

The release workflow runs the tests, builds `DropOff-<tag>.zip`, attaches it to a GitHub release and uploads it to CurseForge. The packager reads `## Interface: 16001` and files the upload under WoW Forever.

Tags pushed before the workflows existed have no zip. The first file on CurseForge is the first tag pushed once the release workflow is on `main`.

The zip holds four folders: `DropOff` and the three map addons (`move-folders` in `.pkgmeta`), about 23 MB of maps. Check the first zip the packager builds: each `DropOff_Paths_*` folder must sit beside `DropOff`, not inside it.

Before making the repository public:

- The tags `v0.3.1` and `v0.4.0` hold a `Passes.lua` whose positions came from Polestar's chokepoint list, which is under the GNU GPL version 3. From `v0.4.1` to `v0.6.0` the table is entered by hand and the addon is MIT. The old table stays in the history of those two tags: they carry `LICENSES/Polestar.txt` for it. Publish no file built from them.
- From `v0.7.0` on the addon is GPL-3.0-or-later: it embeds the walking router and maps of Shortest Path Forever (Cillian Berragan). The licence allows it, with the credit that is in `LICENSES/ShortestPathForever.txt` and on top of each file. Telling its author before publishing is a courtesy, not a condition.

## Summary (English)

```
Lists your finished quests and the bag slots each frees, then gives you the whole trip to the turn-in.
```

## Summary (French)

```
Liste tes quêtes terminées, les emplacements que chacune libère, et te donne tout le trajet pour les rendre.
```

## Description

The English and French descriptions, in Markdown, are in `docs/curseforge-description.md`.
