#!/usr/bin/env python3
"""Lists the quests whose finisher differs between the two quest databases
installed in the game: QuestieDB's Forever build (what DropOff reads at run
time) and Polestar's QuestDB (generated from Forever data).

A difference is a lead, not a fact: neither database is the game. A quest
goes into FOREVER_FINISHERS (Plan.lua) once the right finisher is known, with
where that knowledge comes from. Nothing of either database is copied here.

    tools/compare_finishers.py            # WOW_DIR overrides the game folder
"""
import base64
import os
import re
import sys

WOW_DIR = os.environ.get("WOW_DIR", "/Volumes/Hasu-Gaming/Blizzard/World of Warcraft")
ADDONS = os.path.join(WOW_DIR, "_forever_", "Interface", "AddOns")
QUESTIE = os.path.join(ADDONS, "QuestieDB", "QuestieDB_Forever.toc")
POLESTAR = os.path.join(ADDONS, "Polestar_QuestDB", "Quests.lua")


def cbor(data, at=0):
    """The value at `at` of a CBOR string, and where the next one starts."""
    major, small = data[at] >> 5, data[at] & 31
    at += 1
    if small < 24:
        number = small
    elif small in (24, 25, 26, 27):
        size = 1 << (small - 24)
        number = int.from_bytes(data[at:at + size], "big")
        at += size
    else:
        number = None
    if major == 0:
        return number, at
    if major == 1:
        return -1 - number, at
    if major in (2, 3):
        return data[at:at + number], at + number
    if major == 4:
        items = []
        for _ in range(number):
            item, at = cbor(data, at)
            items.append(item)
        return items, at
    if major == 5:
        pairs = {}
        for _ in range(number):
            key, at = cbor(data, at)
            pairs[key], at = cbor(data, at)
        return pairs, at
    if major == 7:
        return None, at + (0 if small < 24 else 1 << (small - 24))
    raise ValueError("CBOR major type %d" % major)


def ids(value):
    return {item for item in (value or []) if isinstance(item, int)}


def questie():
    """quest -> the NPC and object ids of QuestieDB's finishedBy (field 3)."""
    finishers = {}
    for line in open(QUESTIE, encoding="utf-8", errors="replace"):
        found = re.match(r"## X-Quest-(\d+)-3: (\S+)", line)
        if not found:
            continue
        try:
            value, _ = cbor(base64.b64decode(found.group(2)))
        except (ValueError, IndexError):
            continue
        if isinstance(value, dict):
            value = [value.get(1), value.get(2)]
        if isinstance(value, list):
            finishers[int(found.group(1))] = ids(value[0] if value else None) | ids(value[1] if len(value) > 1 else None)
    return finishers


def polestar():
    """quest -> (title, the ids of its `finish` field, the eighth)."""
    quests = {}
    for line in open(POLESTAR, encoding="utf-8", errors="replace"):
        found = re.match(r"(\d+)\t'(.*)$", line.rstrip("\n"))
        if found:
            fields = found.group(2).split(";")
            finish = fields[7] if len(fields) > 7 else ""
            quests[int(found.group(1))] = (fields[0], {int(number) for number in re.findall(r"\d+", finish)})
    return quests


def main():
    for path in (QUESTIE, POLESTAR):
        if not os.path.isfile(path):
            sys.exit("not found: " + path)
    mine, theirs = questie(), polestar()
    narrowed, other = [], []
    for quest, finishers in sorted(mine.items()):
        if quest not in theirs:
            continue
        title, forever = theirs[quest]
        if not forever or forever == finishers:
            continue
        (narrowed if forever < finishers else other).append((quest, title, sorted(finishers), sorted(forever)))
    print("%d quests in QuestieDB, %d in Polestar's" % (len(mine), len(theirs)))
    print("\nQuestieDB names more finishers than the Forever data (%d):" % len(narrowed))
    for row in narrowed:
        print("  %d %s: %s -> %s" % row)
    print("\nThe two name different finishers (%d):" % len(other))
    for row in other:
        print("  %d %s: %s -> %s" % row)


if __name__ == "__main__":
    main()
