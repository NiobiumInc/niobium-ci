#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Turn clang-tidy diagnostics into GitHub-native reports.

Three output modes, all reading clang-tidy's standard text diagnostics from a file
or stdin:

  annotations  emit `::warning file=...,line=...::` workflow commands so each
               finding shows inline on the changed line in a PR (used by the
               diff-only gate).

  summary      emit a Markdown table for $GITHUB_STEP_SUMMARY where the check
               links to its documentation and the location links to the exact
               source line at the analyzed commit (used by the whole-repo
               nightly).

  count        emit the number of findings, for a workflow output.

Diagnostics are deduplicated by (file, line, col, check): run-clang-tidy reports
the same header finding once per TU that includes it.
"""
import argparse
import os
import re
import sys
from collections import Counter

# <path>:<line>:<col>: <warning|error>: <message> [<check>(,<check>)*]
DIAG = re.compile(
    r"^(?P<file>/[^:]+):(?P<line>\d+):(?P<col>\d+):\s+"
    r"(?:warning|error):\s+(?P<msg>.*?)\s+\[(?P<checks>[^\]]+)\]\s*$"
)

# Code owned by other projects, which each analyse their own. A .clang-tidy
# ExcludeHeaderFilterRegex already keeps such directories out of header
# diagnostics, but a check comparing a declaration against its definition reports
# the pair through the main file — whose diagnostics clang-tidy always shows — and
# prints the header's location, so the path is the last word on whether a finding
# belongs to this repository. The default matches the conventional directory names;
# consumers that vendor elsewhere override it with --third-party-regex.
DEFAULT_THIRD_PARTY = r"/(vendor|deps|examples)/"


def check_docs_url(check):
    """Return the clang-tidy documentation URL for a check name.

    A check name is `<module>-<rest>`; the docs live at
    `.../checks/<module>/<rest>.html`. The module is a single token except
    `clang-analyzer`, whose name itself carries a hyphen, so it is split off
    explicitly.

    Args:
        check: A check name, e.g. "performance-avoid-endl" or
            "clang-analyzer-core.DivideZero".

    Returns:
        The documentation URL, or None if `check` has no `-` separator.
    """
    if check.startswith("clang-analyzer-"):
        cat, rest = "clang-analyzer", check[len("clang-analyzer-"):]
    else:
        cat, _, rest = check.partition("-")
    if not rest:
        return None
    return f"https://clang.llvm.org/extra/clang-tidy/checks/{cat}/{rest}.html"


def disabled_checks(config_path):
    """Return the checks explicitly turned off in a .clang-tidy Checks: block.

    Reads the folded `Checks:` scalar (from the key up to the next top-level
    key), splits it on commas/whitespace, and collects every entry that starts
    with `-`, minus the leading dash. The blanket `-*` is skipped so only the
    named opt-outs are returned.

    Args:
        config_path: Path to a .clang-tidy file.

    Returns:
        A list of disabled check names (e.g. ["misc-include-cleaner", ...]),
        or an empty list if the file cannot be read.
    """
    try:
        with open(config_path, errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    block, in_block = [], False
    for ln in lines:
        if not in_block:
            if ln.startswith("Checks:"):
                in_block = True
                rest = ln.split(":", 1)[1].strip().lstrip(">|").strip()
                if rest:
                    block.append(rest)
            continue
        if ln and not ln[0].isspace():  # next top-level key ends the folded scalar
            break
        block.append(ln)
    out = []
    for tok in re.split(r"[,\s]+", " ".join(block)):
        if tok.startswith("-") and tok != "-*":
            out.append(tok[1:])
    return out


def parse(stream, third_party=DEFAULT_THIRD_PARTY):
    """Parse clang-tidy text diagnostics into finding records.

    Matches the standard `path:line:col: warning|error: message [check]` lines
    and ignores everything else (note lines, source context, progress output).
    The synthetic `-warnings-as-errors` tag that WarningsAsErrors appends is
    dropped, and the first remaining check name is used. Paths are normalized
    lexically, then findings are deduplicated by (file, line, col, check) because
    run-clang-tidy reports the same header finding once per translation unit that
    includes it. Findings in third-party and submodule trees are dropped: they
    belong to the projects that own them.

    Args:
        stream: An iterable of text lines (an open file or sys.stdin).
        third_party: Regex matched against the normalized path; matches are
            discarded.

    Yields:
        A dict per unique finding with keys: file, line, col, msg, check.
    """
    third_party_re = re.compile(third_party) if third_party else None
    seen = set()
    for raw in stream:
        m = DIAG.match(raw.rstrip("\n"))
        if not m:
            continue
        # clang-tidy prints the path as the compiler resolved it from the
        # translation unit's own directory, so one header arrives spelled several
        # ways: `driver/../include/x.h` and `include/x.h` are the same file.
        # Collapse `..` before anything keys off the path. Unnormalized, the dedup
        # below compares distinct strings and keeps every copy, the third-party
        # regex matches a `..` segment that merely passes through such a directory,
        # and `emit_annotations` prints a path GitHub cannot line up against the
        # diff. Lexical rather than `realpath`: this parses text that may come from
        # another machine, so it must not touch the filesystem.
        path = os.path.normpath(m["file"])
        if third_party_re and third_party_re.search(path):
            continue
        checks = [c for c in m["checks"].split(",") if c != "-warnings-as-errors"]
        if not checks:
            continue
        check = checks[0]
        key = (path, m["line"], m["col"], check)
        if key in seen:
            continue
        seen.add(key)
        yield {
            "file": path,
            "line": m["line"],
            "col": m["col"],
            "msg": m["msg"],
            "check": check,
        }


def rel(path, root):
    """Return `path` relative to `root`, or unchanged if it is not under it.

    Args:
        path: An absolute path from the compile database.
        root: The repository root (GITHUB_WORKSPACE).

    Returns:
        The repo-relative path (e.g. "src/Compiler.cpp").
    """
    root = root.rstrip("/") + "/"
    return path[len(root):] if path.startswith(root) else path


def emit_annotations(findings, root):
    """Print a GitHub `::warning` workflow command for each finding.

    GitHub renders these inline on the finding's line in a PR's Files-changed
    view, so paths must be repo-relative.

    Args:
        findings: An iterable of finding dicts from `parse`.
        root: The repository root, used to make paths repo-relative.
    """
    for f in findings:
        path = rel(f["file"], root)
        msg = f"{f['check']}: {f['msg']}"
        print(f"::warning file={path},line={f['line']},col={f['col']}::{msg}")


def emit_summary(findings, root, server, repo, sha, top, disabled, scope="whole repo"):
    """Print a Markdown report to stdout for $GITHUB_STEP_SUMMARY.

    The report has the disabled checks, counts by check and by directory, and a
    findings table capped at `top` rows. When server/repo/sha are all given,
    each check links to its documentation and each location links to the source
    line at the analyzed commit.

    Args:
        findings: An iterable of finding dicts from `parse`.
        root: The repository root, used to make paths repo-relative.
        server: GitHub server URL (GITHUB_SERVER_URL) for source links.
        repo: "owner/name" (GITHUB_REPOSITORY) for source links.
        sha: Commit SHA (GITHUB_SHA) the source links point at.
        top: Maximum number of rows in the findings table.
        disabled: Disabled check names to list (from `disabled_checks`).
        scope: What was analyzed, for the heading — the whole repo for the
            nightly survey, the changed lines for the diff gate.
    """
    findings = list(findings)
    if not findings:
        # Empty count/location tables render as bare headers, which reads as a
        # broken report rather than a clean one.
        print(f"# clang-tidy — {scope} (0 findings)\n\nNo findings.")
        return
    by_check = Counter(f["check"] for f in findings)
    by_dir = Counter()
    for f in findings:
        parts = rel(f["file"], root).split("/")
        by_dir["/".join(parts[:3]) if len(parts) > 3 else "/".join(parts[:-1])] += 1

    out = []
    out.append(f"# clang-tidy — {scope} ({len(findings)} findings)\n")
    if disabled:
        out.append("## Disabled checks (not enforced)\n")
        for check in disabled:
            url = check_docs_url(check)
            label = f"[{check}]({url})" if url else check
            out.append(f"- {label}")
        out.append("")
    out.append("## By check\n")
    out.append("| count | check |")
    out.append("|------:|-------|")
    for check, n in by_check.most_common():
        url = check_docs_url(check)
        label = f"[{check}]({url})" if url else check
        out.append(f"| {n} | {label} |")
    out.append("\n## By directory\n")
    out.append("| count | directory |")
    out.append("|------:|-----------|")
    for d, n in by_dir.most_common():
        out.append(f"| {n} | {d} |")

    out.append(f"\n## Findings (first {top})\n")
    out.append("| check | location | message |")
    out.append("|-------|----------|---------|")
    for f in findings[:top]:
        path = rel(f["file"], root)
        loc = f"{path}:{f['line']}"
        if server and repo and sha:
            loc = f"[{loc}]({server}/{repo}/blob/{sha}/{path}#L{f['line']})"
        url = check_docs_url(f["check"])
        check = f"[{f['check']}]({url})" if url else f["check"]
        msg = f["msg"].replace("|", "\\|")
        out.append(f"| {check} | {loc} | {msg} |")
    if len(findings) > top:
        out.append(f"\n_…and {len(findings) - top} more — see the uploaded artifact._")
    print("\n".join(out))


def main():
    """Parse CLI arguments and emit the requested report to stdout.

    Reads diagnostics from `--input` (or stdin) and dispatches on the `mode`
    positional: `annotations` for the diff-only gate, `summary` for the nightly,
    `count` for the action's findings-count output.
    The GitHub context defaults come from the standard Actions environment
    variables so the workflows can call this with no extra flags.
    """
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["annotations", "summary", "count"])
    ap.add_argument("-i", "--input", default="-", help="diagnostics file or - for stdin")
    ap.add_argument("--repo-root", default=os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    ap.add_argument("--server", default=os.environ.get("GITHUB_SERVER_URL", ""))
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    ap.add_argument("--top", type=int, default=200, help="max rows in the findings table")
    ap.add_argument("--config", default=None,
                    help="path to .clang-tidy for the disabled-checks section "
                         "(default: <repo-root>/.clang-tidy)")
    ap.add_argument("--scope", default="whole repo",
                    help="what was analyzed, shown in the summary heading "
                         "(e.g. 'changed lines' for the diff gate)")
    ap.add_argument("--third-party-regex", default=DEFAULT_THIRD_PARTY,
                    help="paths matching this are not this repository's findings; "
                         "pass an empty string to keep everything")
    args = ap.parse_args()

    stream = sys.stdin if args.input == "-" else open(args.input, errors="replace")
    findings = parse(stream, args.third_party_regex)
    if args.mode == "annotations":
        emit_annotations(findings, args.repo_root)
    elif args.mode == "count":
        print(sum(1 for _ in findings))
    else:
        config = args.config or os.path.join(args.repo_root, ".clang-tidy")
        emit_summary(findings, args.repo_root, args.server, args.repo, args.sha,
                     args.top, disabled_checks(config), args.scope)


if __name__ == "__main__":
    main()
