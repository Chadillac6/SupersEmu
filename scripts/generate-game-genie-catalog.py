#!/usr/bin/env python3
import argparse
from collections import defaultdict
import io
import json
import os
from pathlib import Path, PurePosixPath
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


def dat_names(data):
    names = defaultdict(set)
    for game in re.findall(r"^game \(\n(.*?)^\)", data.decode("utf-8"), re.M | re.S):
        title = re.search(r'^\s*name "([^"\n]+)"', game, re.M)
        if title:
            names[title[1]].update(re.findall(r'^\s*rom \(.*?\bsha1 ([0-9A-Fa-f]{40})\b', game, re.M))
    return {name: {sha.upper() for sha in hashes} for name, hashes in names.items() if hashes}


def cheats(data, pattern):
    fields = defaultdict(dict)
    for index, field, quoted, number in FIELDS.findall(data.decode("utf-8-sig", errors="replace")):
        fields[int(index)][field] = quoted or number
    for index in sorted(fields):
        row = fields[index]
        label = row.get("desc", "").strip()
        codes = tuple(code.strip().upper() for code in row.get("code", "").split("+"))
        if label and row.get("handler", "0") == "0" and all(re.fullmatch(pattern, code) for code in codes):
            yield label, codes


def build_system(files, system, folder, pattern):
    names = dat_names(files[PurePosixPath("metadat/no-intro", folder + ".dat")])
    rows = defaultdict(dict)
    directory = PurePosixPath("cht", folder)
    for path in sorted(path for path in files if path.parent == directory and path.suffix == ".cht"):
        name = GENIE_SUFFIX.sub("", path.stem)
        if len(names.get(name, ())) == 1:
            for label, codes in cheats(files[path], pattern):
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


def pinned_files(git, env):
    paths = [path for folder, _ in SYSTEMS.values()
             for path in ("cht/" + folder, "metadat/no-intro/" + folder + ".dat")]
    tree = subprocess.check_output(git + ["ls-tree", "-rz", PIN, "--", *paths], env=env)
    entries = []
    for row in tree.rstrip(b"\0").split(b"\0"):
        metadata, path = row.split(b"\t", 1)
        mode, _, oid = metadata.split()
        if mode in (b"100644", b"100755"):
            entries.append((PurePosixPath(path.decode("utf-8")), oid))
    requested = b"".join(oid + b"\n" for _, oid in entries)
    packed = subprocess.check_output(git + ["cat-file", "--batch"], input=requested, env=env)
    stream = io.BytesIO(packed)
    files = {}
    for path, oid in entries:
        header = stream.readline().split()
        if header[:2] != [oid, b"blob"] or len(header) != 3:
            raise ValueError(f"invalid pinned blob for {path}")
        files[path] = stream.read(int(header[2]))
        if stream.read(1) != b"\n":
            raise ValueError(f"truncated pinned blob for {path}")
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path, help=f"libretro-database checkout at {PIN}")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "App" / "Resources" /
                        "GameGenieCatalog.json")
    args = parser.parse_args()
    git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", args.database]
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1")
    revision = subprocess.check_output(git + ["rev-parse", "--verify", "HEAD^{commit}"],
                                       env=env, text=True).strip()
    if revision != PIN:
        parser.error(f"expected libretro-database at {PIN}")
    files = pinned_files(git, env)
    catalog = {system: build_system(files, system, *source) for system, source in SYSTEMS.items()}
    data = json.dumps({"version": 1, "systems": catalog}, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    args.output.write_bytes((data + "\n").encode("utf-8"))
    for system, source in catalog.items():
        counts = [len(row.get("cheats", ())) for row in source["revisions"].values()]
        print(f"{system}: {sum(count > 0 for count in counts)} exact ROMs, {sum(counts)} cheats, "
              f"{counts.count(0)} fallback-only ROMs")
    print(f"{args.output.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
