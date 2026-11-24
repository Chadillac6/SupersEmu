#!/usr/bin/env python3
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
import subprocess


PIN = "f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029"
SNES = r"[DF4709156BC8A23E]{4}-[DF4709156BC8A23E]{4}"
SEGA = r"[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}-[ABCDEFGHJKLMNPRSTVWXYZ0123456789]{4}"
GB = r"[0-9A-F]{3}-[0-9A-F]{3}(?:-[0-9A-F]{3})?"
SYSTEMS = {
    "snes": ("Nintendo - Super Nintendo Entertainment System", SNES),
    "genesis": ("Sega - Mega Drive - Genesis", SEGA),
    "gb": ("Nintendo - Game Boy", GB),
    "gbc": ("Nintendo - Game Boy Color", GB),
    "sega32x": ("Sega - 32X", SEGA),
}
GENIE_SUFFIX = re.compile(r" \(Game Genie\)$", re.I)
REVISION = re.compile(r" \((?:Rev [\w.]+|v\d+(?:\.\d+)+)\)", re.I)
FIELDS = re.compile(r'^\s*cheat(\d+)_(desc|code|handler)\s*=\s*(?:"([^"\r\n]*)"|([0-9]+))\s*$', re.M)


def dat_names(path):
    names = defaultdict(set)
    for game in re.findall(r"^game \(\n(.*?)^\)", path.read_text(encoding="utf-8"), re.M | re.S):
        title = re.search(r'^\s*name "([^"\n]+)"', game, re.M)
        if title:
            names[title[1]].update(re.findall(r'^\s*rom \(.*?\bsha1 ([0-9A-Fa-f]{40})\b', game, re.M))
    return {name: {sha.upper() for sha in hashes} for name, hashes in names.items() if hashes}


def cheats(path, pattern):
    fields = defaultdict(dict)
    for index, field, quoted, number in FIELDS.findall(path.read_text(encoding="utf-8-sig", errors="replace")):
        fields[int(index)][field] = quoted or number
    for index in sorted(fields):
        row = fields[index]
        label = row.get("desc", "").strip()
        codes = tuple(code.strip().upper() for code in row.get("code", "").split("+"))
        if label and row.get("handler", "0") == "0" and all(re.fullmatch(pattern, code) for code in codes):
            yield label, codes


def build_system(root, system, folder, pattern):
    names = dat_names(root / "metadat" / "no-intro" / (folder + ".dat"))
    rows = defaultdict(dict)
    for path in sorted((root / "cht" / folder).glob("*.cht")):
        name = GENIE_SUFFIX.sub("", path.stem)
        if len(names.get(name, ())) == 1:
            for label, codes in cheats(path, pattern):
                rows[name].setdefault(codes, label)
    rows = {name: codes for name, codes in rows.items() if codes}

    # Only compare-encoded Game Boy code sets can supply a different revision.
    families = defaultdict(list)
    if system in ("gb", "gbc"):
        for name, codes in sorted(rows.items()):
            if any(all(len(code) == 11 for code in group) for group in codes):
                family = REVISION.sub("", name)
                families[family].append(next(iter(names[name])))

    revisions = {}
    for name, hashes in sorted(names.items()):
        family = REVISION.sub("", name)
        exact = rows.get(name)
        candidates = families.get(family)
        if not exact and not candidates:
            continue
        for sha in sorted(hashes):
            revision = {}
            if exact:
                revision["cheats"] = [[label, *codes] for codes, label in exact.items()]
            if candidates:
                revision["family"] = family
            if sha in revisions and revision != revisions[sha]:
                revisions[sha] = None
            else:
                revisions[sha] = revision
    revisions = {sha: data for sha, data in revisions.items() if data is not None}
    families = {name: list(dict.fromkeys(sha for sha in hashes if sha in revisions))
                for name, hashes in families.items()}
    return {"revisions": revisions, "families": families}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path, help=f"libretro-database checkout at {PIN}")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "App" / "Resources" /
                        "GameGenieCatalog.json")
    args = parser.parse_args()
    revision = subprocess.check_output(["git", "-C", args.database, "rev-parse", "HEAD"], text=True).strip()
    changes = subprocess.check_output(
        ["git", "-C", args.database, "status", "--porcelain", "--", "cht", "metadat/no-intro"], text=True)
    if revision != PIN or changes:
        parser.error(f"expected a clean libretro-database data checkout at {PIN}")
    catalog = {system: build_system(args.database, system, *source) for system, source in SYSTEMS.items()}
    data = json.dumps({"version": 1, "systems": catalog}, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    args.output.write_bytes((data + "\n").encode("utf-8"))
    for system, source in catalog.items():
        counts = [len(row.get("cheats", ())) for row in source["revisions"].values()]
        print(f"{system}: {sum(count > 0 for count in counts)} exact ROMs, {sum(counts)} cheats, "
              f"{counts.count(0)} fallback-only ROMs")
    print(f"{args.output.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
