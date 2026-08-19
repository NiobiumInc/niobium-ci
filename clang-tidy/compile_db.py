#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Intersect a list of candidate paths with the translation units in a compile database.

Reads repository-relative candidate paths on stdin and prints those that appear as
entries in `compile_commands.json`, repo-relative and sorted.

This is what lets `scope` stay a statement of policy rather than a list of tool
workarounds: product code that carries no compile command — not built yet, headers,
generated-but-unbuilt sources — drops out here instead of being hand-excluded from
the pathspec, and returns to coverage on its own once the build compiles it.
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
