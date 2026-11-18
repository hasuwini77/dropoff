#!/usr/bin/env bash
# Rebuilds the embedded walking router (Router/) and the walking map addons
# (DropOff_Paths_*) from a checkout of Shortest Path Forever, then checks
# that every file is that checkout's, changed by nothing but the notice on
# top and the name of the maps' global.
#   tools/vendor-router.sh <checkout>           rebuild, then check
#   tools/vendor-router.sh --check <checkout>   check only
# The checkout: git clone --depth 1 --branch v1.43.2 https://github.com/cjber/shortest-path-forever
# After a new version: set TAG, COMMIT and DATE below, update
# LICENSES/ShortestPathForever.txt, and list any new map part in the TOC of
# its folder (the tests compare the TOCs with the folders).
set -euo pipefail

TAG="v1.43.2"
COMMIT="834cc7c"
DATE="2026-11-18"
NOTICE_LINES=4

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
SRC="${1:?path to a checkout of cjber/shortest-path-forever at $TAG}"
cd "$(dirname "$0")/.."

[ "$(git -C "$SRC" rev-parse --short=7 HEAD)" = "$COMMIT" ] || { echo "$SRC is not at $COMMIT ($TAG)"; exit 1; }

# upstream path -> our path, one pair per line
pairs() {
    echo "Routing/PathGrid.lua Router/PathGrid.lua"
    echo "Routing/Path.lua Router/Path.lua"
    echo "Routing/PathJobs.lua Router/PathJobs.lua"
    echo "Data/Heights.lua Router/Heights.lua"
    local file
    for file in "$SRC"/Nav/Nav0.lua "$SRC"/Nav/Nav0_*.lua; do
        echo "Nav/$(basename "$file") DropOff_Paths_EasternKingdoms/$(basename "$file")"
    done
    for file in "$SRC"/Nav/Nav1.lua "$SRC"/Nav/Nav1_*.lua; do
        echo "Nav/$(basename "$file") DropOff_Paths_Kalimdor/$(basename "$file")"
    done
    for file in "$SRC"/Nav/Nav2991.lua "$SRC"/Nav/Nav2991_*.lua; do
        echo "Nav/$(basename "$file") DropOff_Paths_Zephras/$(basename "$file")"
    done
}

notice() {
    echo "-- From Shortest Path Forever $TAG (commit $COMMIT), by Cillian Berragan:"
    echo "-- https://github.com/cjber/shortest-path-forever, file $1."
    echo "-- GNU General Public License, version 3 or later: see LICENSE and LICENSES/ShortestPathForever.txt."
    echo "-- Changed for DropOff on $DATE: this notice; the global ShortestPathForeverPathData is named DropOffPathData."
}

if [ "$CHECK_ONLY" = 0 ]; then
    mkdir -p Router DropOff_Paths_EasternKingdoms DropOff_Paths_Kalimdor DropOff_Paths_Zephras
    rm -f Router/PathGrid.lua Router/Path.lua Router/PathJobs.lua Router/Heights.lua DropOff_Paths_*/Nav*.lua
    pairs | while read -r from to; do
        { notice "$from"; sed 's/ShortestPathForeverPathData/DropOffPathData/g' "$SRC/$from"; } > "$to"
    done
fi

count=0
while read -r from to; do
    [ -f "$to" ] || { echo "missing: $to"; exit 1; }
    tail -n "+$((NOTICE_LINES + 1))" "$to" | sed 's/DropOffPathData/ShortestPathForeverPathData/g' | cmp -s - "$SRC/$from" \
        || { echo "differs from upstream: $to"; exit 1; }
    if grep -q "ShortestPathForever[A-Za-z]" <(tail -n "+$((NOTICE_LINES + 1))" "$to"); then
        echo "still names an upstream global: $to"; exit 1
    fi
    count=$((count + 1))
done < <(pairs)
echo "$count files are upstream's $TAG ($COMMIT) with the notice and the global's name"
