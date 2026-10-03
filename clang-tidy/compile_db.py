#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Keep only the paths the build actually compiles.

Reads candidate paths on stdin and prints those that appear in the build's
`compile_commands.json`, repo-relative and sorted.

clang-tidy replays the compiler flags the build recorded, so a file with no entry in
that database cannot be analysed at all — asking anyway yields an error rather than a
finding. Without this filter that has to be handled by hand, by excluding such files
from the pathspec that selects what to analyse. That mixes two questions which are
better kept apart — "is this our product code?" and "can it be analysed today?" — and
the exclusion goes stale, silently, the day the build starts compiling that directory.

Filtering here leaves the pathspec answering only the first question, and answers the
second on every run.

With `--dedupe-to DIR` it instead writes a copy of the database holding one entry per
source file, the first, to DIR/compile_commands.json. clang-tidy analyzes a file once
for every entry naming it, so a source compiled into several targets would otherwise
be analyzed, and reported, that many times over.
"""
import argparse
import json
import os
import sys


def db_translation_units(db_path, root):
    """Yield the repo-relative path of every entry in a compile database.

    Entries whose `file` is relative are resolved against their own `directory`, as
    the JSON Compilation Database spec allows; entries resolving outside `root`
    (submodules built in place, vendored dependencies, absolute system paths) are
    skipped, since they are never first-party code.

    Args:
        db_path: Path to a compile_commands.json.
        root: Repository root the results are made relative to.

    Yields:
        Repo-relative paths, possibly with duplicates (one entry per compilation).
    """
    with open(db_path, errors="replace") as fh:
        entries = json.load(fh)
    root = os.path.normpath(root)
    for entry in entries:
        f = entry.get("file")
        if not f:
            continue
        if not os.path.isabs(f):
            f = os.path.join(entry.get("directory", root), f)
        rel = os.path.relpath(os.path.normpath(f), root)
        if not rel.startswith(".."):
            yield rel


def dedupe(db_path, out_dir):
    """Write the database to out_dir/compile_commands.json, one entry per source file.

    The first entry for a file is kept, so the result depends only on the database's
    own order. Files are compared once resolved, as in db_translation_units, so one
    source named two ways is still one file.

    Args:
        db_path: Path to a compile_commands.json.
        out_dir: Directory to write the deduplicated compile_commands.json into.
    """
    with open(db_path, errors="replace") as fh:
        entries = json.load(fh)
    seen = set()
    kept = []
    for entry in entries:
        f = entry.get("file")
        if f and not os.path.isabs(f):
            f = os.path.join(entry.get("directory", ""), f)
        key = os.path.normpath(f) if f else None
        if key in seen:
            continue
        if key:
            seen.add(key)
        kept.append(entry)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "compile_commands.json"), "w") as fh:
        json.dump(kept, fh, indent=1)


def main():
    """Print the candidates from stdin that the compile database knows how to build."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="path to compile_commands.json")
    ap.add_argument("--root", default=os.getcwd(),
                    help="repository root the paths are relative to")
    ap.add_argument("--absolute", action="store_true",
                    help="print absolute paths instead of repo-relative ones")
    ap.add_argument("--dedupe-to", metavar="DIR",
                    help="write a copy of the database with one entry per file to DIR")
    args = ap.parse_args()

    if args.dedupe_to is not None:
        # An empty DIR is a caller's failure, not a request for the filter below.
        if not args.dedupe_to:
            ap.error("--dedupe-to needs a directory")
        dedupe(args.db, args.dedupe_to)
        return

    candidates = {ln.strip() for ln in sys.stdin if ln.strip()}
    if not candidates:
        return
    known = set(db_translation_units(args.db, args.root))
    root = os.path.normpath(args.root)
    for path in sorted(candidates & known):
        print(os.path.join(root, path) if args.absolute else path)


if __name__ == "__main__":
    main()
