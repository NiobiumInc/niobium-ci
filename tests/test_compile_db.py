#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tests for compile_db.py — the intersection that lets a scope state policy alone."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, os.pardir, "clang-tidy", "compile_db.py")
sys.path.insert(0, os.path.join(HERE, os.pardir, "clang-tidy"))
import compile_db  # noqa: E402


class TranslationUnits(unittest.TestCase):
    """db_translation_units resolves entries the way the JSON database spec allows."""

    def setUp(self):
        self.root = tempfile.mkdtemp()

    def db(self, entries):
        path = os.path.join(self.root, "compile_commands.json")
        with open(path, "w") as fh:
            json.dump(entries, fh)
        return path

    def test_absolute_file_is_made_relative(self):
        db = self.db([{"directory": self.root, "file": f"{self.root}/src/a.cpp"}])
        self.assertEqual(list(compile_db.db_translation_units(db, self.root)), ["src/a.cpp"])

    def test_relative_file_resolves_against_its_directory(self):
        # The spec allows a relative `file`, and it is relative to `directory` — not to
        # the process's working directory, which is a different place entirely.
        db = self.db([{"directory": self.root, "file": "src/b.cpp"}])
        self.assertEqual(list(compile_db.db_translation_units(db, self.root)), ["src/b.cpp"])

    def test_relative_file_against_a_nested_directory(self):
        db = self.db([{"directory": os.path.join(self.root, "build"), "file": "../src/c.cpp"}])
        self.assertEqual(list(compile_db.db_translation_units(db, self.root)), ["src/c.cpp"])

    def test_entries_outside_the_root_are_dropped(self):
        # Vendored dependencies built in place, and system paths, are not this
        # repository's code and must not reach the analysis.
        db = self.db([
            {"directory": self.root, "file": "/usr/include/other.cpp"},
            {"directory": self.root, "file": f"{self.root}/src/a.cpp"},
        ])
        self.assertEqual(list(compile_db.db_translation_units(db, self.root)), ["src/a.cpp"])

    def test_entry_without_a_file_key_is_skipped(self):
        db = self.db([{"directory": self.root}, {"directory": self.root, "file": "src/a.cpp"}])
        self.assertEqual(list(compile_db.db_translation_units(db, self.root)), ["src/a.cpp"])


class CommandLine(unittest.TestCase):
    """The CLI intersects stdin with the database and nothing else."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.dbpath = os.path.join(self.root, "compile_commands.json")
        with open(self.dbpath, "w") as fh:
            json.dump([
                {"directory": self.root, "file": f"{self.root}/src/a.cpp"},
                {"directory": self.root, "file": f"{self.root}/src/b.cpp"},
                {"directory": self.root, "file": f"{self.root}/tools/t.cpp"},
            ], fh)

    def run_cli(self, candidates, *args):
        out = subprocess.run(
            [sys.executable, SCRIPT, "--db", self.dbpath, "--root", self.root, *args],
            input="\n".join(candidates), capture_output=True, text=True, check=True)
        return out.stdout.split()

    def test_keeps_only_candidates_the_database_can_build(self):
        got = self.run_cli(["src/a.cpp", "src/Backend/uncompiled.cpp", "include/h.h"])
        self.assertEqual(got, ["src/a.cpp"])

    def test_candidates_absent_from_the_database_are_dropped_silently(self):
        # This is what removes the need to hand-exclude uncompiled product code from
        # the scope: it disappears here, and returns on its own once it is built.
        self.assertEqual(self.run_cli(["src/Backend/uncompiled.cpp"]), [])

    def test_output_is_sorted_and_deduplicated(self):
        got = self.run_cli(["src/b.cpp", "src/a.cpp", "src/a.cpp"])
        self.assertEqual(got, ["src/a.cpp", "src/b.cpp"])

    def test_absolute_flag_prefixes_the_root(self):
        got = self.run_cli(["src/a.cpp"], "--absolute")
        self.assertEqual(got, [os.path.join(self.root, "src/a.cpp")])

    def test_empty_input_produces_nothing(self):
        self.assertEqual(self.run_cli([]), [])


if __name__ == "__main__":
    unittest.main()
