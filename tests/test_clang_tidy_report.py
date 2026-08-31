#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tests for clang_tidy_report.py — parsing, filtering and the rendered reports."""
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, os.pardir, "clang-tidy"))
import clang_tidy_report as ctr  # noqa: E402

ROOT = "/w"


def diag(path, line=1, col=1, msg="msg", check="modernize-use-auto", severity="warning"):
    return f"{path}:{line}:{col}: {severity}: {msg} [{check}]"


class Parse(unittest.TestCase):
    def parse(self, lines, **kw):
        return list(ctr.parse(iter(lines), **kw))

    def test_matches_the_standard_diagnostic_shape(self):
        got = self.parse([diag(f"{ROOT}/src/a.cpp", 12, 5, "avoid endl", "performance-avoid-endl")])
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["file"], f"{ROOT}/src/a.cpp")
        self.assertEqual((got[0]["line"], got[0]["col"]), ("12", "5"))
        self.assertEqual(got[0]["check"], "performance-avoid-endl")

    def test_ignores_notes_context_and_progress_output(self):
        noise = ["1 warning generated.", "  int x = 0;", "      ^", f"{ROOT}/src/a.cpp:1:1: note: expanded from"]
        self.assertEqual(self.parse(noise), [])

    def test_errors_are_parsed_as_well_as_warnings(self):
        # WarningsAsErrors makes findings print as "error:", so dropping them would
        # silently empty the report of exactly the repositories that enforce most.
        got = self.parse([diag(f"{ROOT}/src/a.cpp", severity="error")])
        self.assertEqual(len(got), 1)

    def test_deduplicates_by_file_line_col_and_check(self):
        # A header finding is reported once per translation unit that includes it.
        line = diag(f"{ROOT}/include/h.h", 3, 7)
        self.assertEqual(len(self.parse([line, line, line])), 1)

    def test_one_header_reached_through_different_paths_is_one_finding(self):
        # The path is resolved from each translation unit's own directory, so a
        # header included from several places arrives spelled several ways.
        got = self.parse([diag(f"{ROOT}/replay/../include/h.h", 3, 7),
                          diag(f"{ROOT}/formal/../include/h.h", 3, 7),
                          diag(f"{ROOT}/include/h.h", 3, 7)])
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["file"], f"{ROOT}/include/h.h")

    def test_same_line_different_check_is_two_findings(self):
        got = self.parse([diag(f"{ROOT}/src/a.cpp", 3, 7, check="a-one"),
                          diag(f"{ROOT}/src/a.cpp", 3, 7, check="b-two")])
        self.assertEqual(len(got), 2)

    def test_warnings_as_errors_tag_is_stripped(self):
        got = self.parse([f"{ROOT}/src/a.cpp:1:1: error: m [modernize-use-auto,-warnings-as-errors]"])
        self.assertEqual(got[0]["check"], "modernize-use-auto")

    def test_third_party_paths_are_dropped_by_default(self):
        got = self.parse([diag(f"{ROOT}/src/a.cpp"), diag(f"{ROOT}/vendor/lib/x.h"),
                          diag(f"{ROOT}/deps/y/z.cpp"), diag(f"{ROOT}/examples/e.cpp")])
        self.assertEqual([f["file"] for f in got], [f"{ROOT}/src/a.cpp"])

    def test_third_party_filter_looks_at_the_normalized_path(self):
        # `src/../vendor/x.h` belongs to a vendored tree and `vendor/../src/a.cpp`
        # does not; the regex reads the second one as third-party on the raw
        # spelling and drops a file the repository owns.
        got = self.parse([diag(f"{ROOT}/src/../vendor/x.h"),
                          diag(f"{ROOT}/vendor/../src/a.cpp")])
        self.assertEqual([f["file"] for f in got], [f"{ROOT}/src/a.cpp"])

    def test_third_party_filter_is_configurable(self):
        got = self.parse([diag(f"{ROOT}/external/x.cpp"), diag(f"{ROOT}/src/a.cpp")],
                         third_party=r"/external/")
        self.assertEqual([f["file"] for f in got], [f"{ROOT}/src/a.cpp"])

    def test_empty_third_party_regex_keeps_everything(self):
        got = self.parse([diag(f"{ROOT}/vendor/x.cpp")], third_party="")
        self.assertEqual(len(got), 1)


class DocsUrl(unittest.TestCase):
    def test_ordinary_check_splits_on_the_first_hyphen(self):
        self.assertEqual(ctr.check_docs_url("performance-avoid-endl"),
                         "https://clang.llvm.org/extra/clang-tidy/checks/performance/avoid-endl.html")

    def test_clang_analyzer_keeps_its_hyphenated_module(self):
        self.assertEqual(ctr.check_docs_url("clang-analyzer-core.DivideZero"),
                         "https://clang.llvm.org/extra/clang-tidy/checks/clang-analyzer/core.DivideZero.html")

    def test_check_without_a_separator_has_no_url(self):
        self.assertIsNone(ctr.check_docs_url("bare"))


class DisabledChecks(unittest.TestCase):
    def write(self, text):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        return path

    def test_reads_the_folded_scalar_and_keeps_only_opt_outs(self):
        path = self.write(
            "Checks: >\n"
            "  -*,\n"
            "  bugprone-*,\n"
            "  -bugprone-easily-swappable-parameters,\n"
            "  -modernize-use-trailing-return-type\n"
            "WarningsAsErrors: '*'\n")
        self.assertEqual(ctr.disabled_checks(path),
                         ["bugprone-easily-swappable-parameters",
                          "modernize-use-trailing-return-type"])

    def test_stops_at_the_next_top_level_key(self):
        path = self.write("Checks: >\n  -a-one\nHeaderFilterRegex: '-not-a-check'\n")
        self.assertEqual(ctr.disabled_checks(path), ["a-one"])

    def test_missing_file_is_not_an_error(self):
        self.assertEqual(ctr.disabled_checks("/nonexistent/.clang-tidy"), [])


class Rendering(unittest.TestCase):
    def render(self, fn, *args, **kw):
        buf = io.StringIO()
        with redirect_stdout(buf):
            fn(*args, **kw)
        return buf.getvalue()

    def test_annotations_are_repo_relative_and_warnings(self):
        out = self.render(ctr.emit_annotations,
                          ctr.parse(iter([diag(f"{ROOT}/src/a.cpp", 4, 2)])), ROOT)
        self.assertIn("::warning file=src/a.cpp,line=4,col=2::", out)
        self.assertNotIn(ROOT + "/src", out)

    def test_summary_of_nothing_says_so_instead_of_rendering_bare_headers(self):
        out = self.render(ctr.emit_summary, iter([]), ROOT, "", "", "", 10, [], "changed lines")
        self.assertIn("changed lines (0 findings)", out)
        self.assertIn("No findings.", out)
        self.assertNotIn("| count |", out)

    def test_summary_scope_appears_in_the_heading(self):
        out = self.render(ctr.emit_summary, ctr.parse(iter([diag(f"{ROOT}/src/a.cpp")])),
                          ROOT, "", "", "", 10, [], "whole repo")
        self.assertIn("# clang-tidy — whole repo (1 findings)", out)

    def test_summary_links_locations_when_the_github_context_is_present(self):
        out = self.render(ctr.emit_summary, ctr.parse(iter([diag(f"{ROOT}/src/a.cpp", 9)])),
                          ROOT, "https://github.com", "o/r", "abc123", 10, [], "whole repo")
        self.assertIn("(https://github.com/o/r/blob/abc123/src/a.cpp#L9)", out)

    def test_summary_caps_the_table_and_says_how_many_were_left_out(self):
        many = [diag(f"{ROOT}/src/a.cpp", n) for n in range(1, 8)]
        out = self.render(ctr.emit_summary, ctr.parse(iter(many)), ROOT, "", "", "", 3, [], "whole repo")
        self.assertIn("…and 4 more", out)

    def test_pipes_in_a_message_do_not_break_the_table(self):
        out = self.render(ctr.emit_summary,
                          ctr.parse(iter([diag(f"{ROOT}/src/a.cpp", msg="a | b")])),
                          ROOT, "", "", "", 10, [], "whole repo")
        self.assertIn(r"a \| b", out)


if __name__ == "__main__":
    unittest.main()
