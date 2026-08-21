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


def main():
    """Print the candidates from stdin that the compile database knows how to build."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True, help="path to compile_commands.json")
    ap.add_argument("--root", default=os.getcwd(),
                    help="repository root the paths are relative to")
    ap.add_argument("--absolute", action="store_true",
                    help="print absolute paths instead of repo-relative ones")
    args = ap.parse_args()

    candidates = {ln.strip() for ln in sys.stdin if ln.strip()}
    if not candidates:
        return
    known = set(db_translation_units(args.db, args.root))
    root = os.path.normpath(args.root)
    for path in sorted(candidates & known):
        print(os.path.join(root, path) if args.absolute else path)


if __name__ == "__main__":
    main()
