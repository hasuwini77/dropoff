#!/usr/bin/env bash
# Copies the addon into the WoW Forever AddOns folder: DropOff itself, and
# the addons holding its walking maps (DropOff_Paths_*), each to a folder of
# its own. A new folder is seen by the game only when it is started again.
# Override the game path with WOW_DIR=/path/to/World\ of\ Warcraft
set -euo pipefail

cd "$(dirname "$0")/.."
WOW_DIR="${WOW_DIR:-/Volumes/Hasu-Gaming/Blizzard/World of Warcraft}"
ADDONS="$WOW_DIR/_forever_/Interface/AddOns"

[ -d "$WOW_DIR/_forever_" ] || { echo "No _forever_ folder in $WOW_DIR"; exit 1; }

# --delete only ever runs inside the folder of one addon.
mkdir -p "$ADDONS/DropOff"
rsync -a --delete \
    --include '/*.lua' --include '/*.toc' --include '/LICENSE' \
    --include '/LICENSES/' --include '/LICENSES/*.txt' \
    --include '/Router/' --include '/Router/*.lua' \
    --exclude '*' ./ "$ADDONS/DropOff/"
echo "Installed to $ADDONS/DropOff"

for maps in DropOff_Paths_*/; do
    maps="${maps%/}"
    [ -f "$maps/$maps.toc" ] || continue
    mkdir -p "$ADDONS/$maps"
    rsync -a --delete --include '/*.lua' --include '/*.toc' --exclude '*' "$maps/" "$ADDONS/$maps/"
    echo "Installed to $ADDONS/$maps"
done
