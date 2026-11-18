#!/usr/bin/env bash
# Copies the addon into the WoW Forever AddOns folder.
# Override the game path with WOW_DIR=/path/to/World\ of\ Warcraft
set -euo pipefail

cd "$(dirname "$0")/.."
WOW_DIR="${WOW_DIR:-/Volumes/Hasu-Gaming/Blizzard/World of Warcraft}"
DEST="$WOW_DIR/_forever_/Interface/AddOns/DropOff"

[ -d "$WOW_DIR/_forever_" ] || { echo "No _forever_ folder in $WOW_DIR"; exit 1; }
mkdir -p "$DEST"
rsync -a --delete --include '*.lua' --include '*.toc' --include 'LICENSE' --include 'LICENSES/' --include 'LICENSES/*.txt' --exclude '*' ./ "$DEST/"
echo "Installed to $DEST"
