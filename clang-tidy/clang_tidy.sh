#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Runs clang-tidy the one way a project runs it. Developers reach it through
# `make clang-tidy`; CI reaches it through the same target, supplying only what is
# unique to a pull request. Keeping a single implementation is the point: a local
# check and the gate cannot report different things if they are the same command.
#
# ---------------------------------------------------------------------------
# This file is maintained in NiobiumInc/niobium-ci and reaches a consuming repository
# as a submodule pinned by commit SHA. Edit it upstream: a change made inside the
# submodule is not what the pin names, so it would not survive a fresh checkout.
# ---------------------------------------------------------------------------
#
# Modes:
#   check-tool  assert the analyzer on PATH is the expected version
#   diff        analyze the lines changed against CLANG_TIDY_BASE
#   all         analyze every in-scope translation unit
#
# Configuration arrives in the environment; the consumer's Makefile owns the values.
# No secrets are read, written or required.
set -uo pipefail

MODE="${1:?usage: clang_tidy.sh check-tool|diff|all}"
HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLANG_TIDY_VERSION:?}"
: "${CLANG_TIDY_SCOPE:?}"
: "${CLANG_TIDY_BUILD_DIR:=build}"
: "${CLANG_TIDY_BIN:=clang-tidy}"
: "${CLANG_TIDY_COMMITTED:=0}"
CLANG_TIDY_BASE="${CLANG_TIDY_BASE:-}"
DB="$CLANG_TIDY_BUILD_DIR/compile_commands.json"
STATUS_FILE="clang-tidy-status.txt"

# GitHub renders ::error:: as an annotation; elsewhere it is just a prefix, so the
# same message reads correctly in a terminal.
err() { echo "::error::$*" >&2; }

# --------------------------------------------------------------------------
# Exit codes are a contract, so a caller can be lenient about findings without
# also swallowing an analysis that never happened:
#
#   0  ran, nothing found
#   1  ran, and reported findings
#   2  produced no trustworthy verdict — a crash, the wrong analyzer, an empty
#      scope, a missing compile database
#
# Only 1 is safe to downgrade. Treating 2 as a pass would report green over an
# analysis that did not run, which is worse than no gate at all.
# --------------------------------------------------------------------------
readonly EX_FINDINGS=1 EX_NOVERDICT=2

# --------------------------------------------------------------------------
# CLANG_TIDY_SCOPE is a git pathspec and answers one question: is this product
# code? It must not encode what the build happens to compile — that is decided at
# runtime by intersecting with the compile database, so a scope carries no tool
# workarounds and uncompiled trees return to coverage on their own once built.
#
# noglob keeps the ** and :(exclude) tokens literal for git; losing it does not
# error, it silently selects the wrong set. The subshell confines it.
# --------------------------------------------------------------------------
scope_files() {
    # shellcheck disable=SC2086  # deliberate word splitting: a pathspec list
    ( set -f; git ls-files -- $CLANG_TIDY_SCOPE )
}

# --------------------------------------------------------------------------
# A scope that matches nothing is a configuration error, never a clean run. Both
# modes would otherwise succeed while analyzing zero files: the gate reports
# "nothing in scope changed" and passes, the survey reports zero debt. A gate that
# analyzes nothing and approves is worse than one that fails.
#
# This is a live hazard rather than a hypothetical, because the pathspec relies on
# word splitting: invoked from a shell that does not split unquoted expansions —
# zsh, for one — the whole scope arrives as a single pathspec and matches nothing.
# --------------------------------------------------------------------------
check_scope() {
    if [ -z "$(scope_files | head -1)" ]; then
        err "CLANG_TIDY_SCOPE matches no tracked file — the scope is wrong, so nothing would be analyzed."
        echo "  scope: $CLANG_TIDY_SCOPE" >&2
        echo "  Check the pathspec, and that it is passed to a shell that word-splits it (bash, not zsh)." >&2
        return 1
    fi
}

# Reads candidate paths on stdin, prints those the compile database can build.
db_filter() { python3 "$HELPERS/compile_db.py" --db "$DB" "$@"; }

# --------------------------------------------------------------------------
# The analyzer must be the expected version, not whatever the host happens to
# offer. A mismatch changes which checks exist and how they behave, so it fails
# here rather than producing a verdict nobody can reproduce.
# --------------------------------------------------------------------------
check_tool() {
    if ! command -v "$CLANG_TIDY_BIN" >/dev/null 2>&1; then
        err "$CLANG_TIDY_BIN is not installed."
        echo "  Install clang-tools-extra ${CLANG_TIDY_VERSION%.*}.x, or point CLANG_TIDY_BIN at a build of it." >&2
        return 1
    fi
    local found
    found=$("$CLANG_TIDY_BIN" --version | sed -n 's/.*LLVM version \([0-9.]*\).*/\1/p' | head -1)
    if [ "$found" != "$CLANG_TIDY_VERSION" ]; then
        err "expected clang-tidy $CLANG_TIDY_VERSION, found ${found:-unknown} ($(command -v "$CLANG_TIDY_BIN"))."
        echo "  Findings differ between releases, so this is a hard mismatch rather than a warning." >&2
        return 1
    fi
    echo "clang-tidy $found ($(command -v "$CLANG_TIDY_BIN"))"
}

# --------------------------------------------------------------------------
# The compile database drives everything: a unit missing from it is not analyzed
# at all. One older than the sources it describes silently omits whatever was
# added since, so say so rather than report a clean run over a stale picture.
# Only tracked in-scope files are considered, so build trees and other untracked
# output cannot raise a false alarm.
# --------------------------------------------------------------------------
check_compile_db() {
    if [ ! -f "$DB" ]; then
        err "no compile database at $DB — configure the build first."
        return 1
    fi
    # Only translation units: a newer CMakeLists.txt or README says nothing about a
    # source being absent from the database, and would make this fire constantly.
    local f
    while IFS= read -r f; do
        case "$f" in
            *.cpp|*.cc|*.cxx|*.c) ;;
            *) continue ;;
        esac
        if [ -f "$f" ] && [ "$f" -nt "$DB" ]; then
            echo "note: $DB is older than $f; sources added since are not analyzed." >&2
            break
        fi
    done < <(scope_files)
}

# --------------------------------------------------------------------------
# The compile database records GCC command lines while the analyzer is clang, so
# hand it this host's GCC: -idirafter ranks GCC's internal include dir below
# clang's own headers, which resolves the omp.h that -fopenmp units need without
# displacing clang's intrinsics, and --gcc-install-dir is what finds libstdc++.
# Both are queried locally because the paths differ per distribution. A clang
# built by the host's own distribution needs neither and is unharmed by them.
#
# Note this is also why pinning the analyzer version is necessary but not
# sufficient for reproducibility: these paths come from the host, so a survey is
# comparable across runs on one runner family rather than across all of them.
# --------------------------------------------------------------------------
toolchain_args() {
    local inc dir
    inc=$(gcc -print-file-name=include 2>/dev/null || true)
    dir=$(dirname "$(gcc -print-libgcc-file-name 2>/dev/null)" 2>/dev/null || true)
    [ -n "$inc" ] && printf '%s\n' "-idirafter$inc"
    [ -n "$dir" ] && printf '%s\n' "--gcc-install-dir=$dir"
}

lint_diff() {
    [ -n "$CLANG_TIDY_BASE" ] || { err "CLANG_TIDY_BASE is empty — no diff base to compare against."; return "$EX_NOVERDICT"; }
    # An explicit setting first, then the copy clang-tools-extra installs, then what
    # setup_clang_tidy.sh cached for this exact version. Nothing is fetched here: a
    # local lint should not depend on the network.
    local driver="${CLANG_TIDY_DIFF:-}" candidate
    if [ -z "$driver" ]; then
        for candidate in \
            /usr/share/clang/clang-tidy-diff.py \
            "${XDG_CACHE_HOME:-$HOME/.cache}/niobium-ci/clang-tidy-diff-${CLANG_TIDY_VERSION}.py"
        do
            if [ -f "$candidate" ]; then driver="$candidate"; break; fi
        done
    fi
    if [ ! -f "${driver:-}" ]; then
        err "clang-tidy-diff.py not found. Run setup_clang_tidy.sh, install clang-tools-extra, or set CLANG_TIDY_DIFF."
        return "$EX_NOVERDICT"
    fi

    # Committed state is what CI reviews; the working tree is what a developer is
    # about to commit. Both are useful, so the caller picks.
    local -a range=("$CLANG_TIDY_BASE")
    [ "$CLANG_TIDY_COMMITTED" = "1" ] && range+=("HEAD")

    # Restrict to changed files the build actually compiles. This replaces the
    # -iregex filter the driver would otherwise need: headers and uncompiled
    # sources cannot appear in a compile database, so they cannot reach clang-tidy
    # and cannot produce the "no compile command" errors that used to require
    # hand-written scope exclusions.
    local -a tus=()
    # shellcheck disable=SC2086
    mapfile -t tus < <( ( set -f; git diff --name-only --diff-filter=d "${range[@]}" -- $CLANG_TIDY_SCOPE ) | db_filter )
    : > clang-tidy-report.txt
    : > clang-tidy-stderr.txt
    if [ "${#tus[@]}" -eq 0 ]; then
        echo "No analyzable in-scope changes."
        return 0
    fi

    local -a extra=()
    local arg
    while IFS= read -r arg; do extra+=("-extra-arg-before=$arg"); done < <(toolchain_args)

    git diff -U0 "${range[@]}" -- "${tus[@]}" \
        | python3 "$driver" \
            -clang-tidy-binary "$CLANG_TIDY_BIN" \
            -p1 -path "$CLANG_TIDY_BUILD_DIR" -j "$(nproc)" \
            "${extra[@]}" \
            2> clang-tidy-stderr.txt \
        | tee clang-tidy-report.txt
    local rc=$?
    cat clang-tidy-stderr.txt >&2

    if grep -qE 'PLEASE submit a bug report|Stack dump:' clang-tidy-stderr.txt clang-tidy-report.txt 2>/dev/null; then
        local units
        units=$(grep -oE 'Program arguments: clang-tidy .*' clang-tidy-stderr.txt \
                | grep -oE '[^ ]+\.(cpp|cc|cxx|c)$' | sort -u | tr '\n' ' ')
        {
            echo "clang-tidy crashed; no analysis was produced."
            echo "Affected translation units: ${units:-unknown}"
        } >> clang-tidy-report.txt
        err "clang-tidy crashed — a toolchain failure, not a problem with these changes. Affected: ${units:-unknown}"
        return "$EX_NOVERDICT"
    fi
    if grep -nE ' (warning|error): ' clang-tidy-report.txt; then
        err "clang-tidy reported findings on changed lines. Fix them, or deviate a false positive inline with // NOLINT(check-name): <reason>."
        return "$EX_FINDINGS"
    fi
    if [ "$rc" -ne 0 ]; then
        err "clang-tidy exited with status $rc but reported no findings and no crash — check the output above."
        return "$EX_NOVERDICT"
    fi
    echo "clang-tidy: no findings on changed lines."
}

lint_all() {
    local outdir unitdir crashes
    outdir="${TMPDIR:-/tmp}/nb-clang-tidy-$$"
    # Per-unit output goes in its own directory. The bookkeeping files below are
    # also *.txt, and a flat directory would let the concatenation at the end sweep
    # them into the report.
    unitdir="$outdir/units"
    crashes="$outdir/crashes.txt"
    rm -rf "$outdir"; mkdir -p "$unitdir"; : > "$crashes"

    # Every other output below is rewritten on each run, but the crash list is only
    # written when there are crashes. On a persistent runner — or a developer's
    # machine — one left by an earlier run would otherwise survive a clean one, and a
    # caller checking for it would report units as unanalyzed and warn that the
    # totals understate the debt, both untrue.
    rm -f clang-tidy-crashes.txt

    scope_files | db_filter --absolute | sort > "$outdir/files.txt"
    local total
    total=$(wc -l < "$outdir/files.txt")

    # What the scope leaves out, among code that is tracked here and compiled by the
    # build. Both sets are already computed, so name the difference rather than leave
    # it to be noticed.
    #
    # A scope written as exclusions should keep this list small and recognisable — it
    # is how an over-broad exclusion shows up. A scope written as an allow-list should
    # expect anything newly added to product code to appear here until it is listed.
    git ls-files | db_filter --absolute | sort > "$outdir/tracked.txt"
    comm -23 "$outdir/tracked.txt" "$outdir/files.txt" > clang-tidy-unscoped.txt
    local unscoped
    unscoped=$(wc -l < clang-tidy-unscoped.txt)

    echo "analyzing $total translation units; $unscoped compiled tracked unit(s) outside scope"
    if [ "$unscoped" -gt 0 ]; then
        echo "note: $unscoped compiled tracked unit(s) are outside CLANG_TIDY_SCOPE — see clang-tidy-unscoped.txt" >&2
    fi
    [ "$total" -gt 0 ] || { : > clang-tidy-full.txt; rm -rf "$outdir"; return 0; }

    local arg1 arg2
    { read -r arg1; read -r arg2; } < <(toolchain_args)

    # One output file and one exit status per unit. An aggregated run cannot do
    # either: parallel children interleave their writes, and a child killed by a
    # signal is reported as the driver's own failure, losing which file it was.
    # A generated script rather than an exported function: arrays do not survive
    # the environment, so the toolchain arguments arrive as their own variables.
    cat > "$outdir/one.sh" <<'SH'
#!/usr/bin/env bash
f="$1"
out="$OUTDIR/$(printf '%s' "$f" | tr / _).txt"
"$CLANG_TIDY_BIN" -p "$CLANG_TIDY_BUILD_DIR" --quiet \
    ${ARG1:+"--extra-arg-before=$ARG1"} ${ARG2:+"--extra-arg-before=$ARG2"} \
    "$f" > "$out" 2>&1
rc=$?
if [ "$rc" -ge 128 ] || grep -qE 'PLEASE submit a bug report|Stack dump:' "$out"; then
    printf '%s\n' "$f" >> "$CRASHES"
fi
exit 0
SH
    chmod +x "$outdir/one.sh"
    OUTDIR="$unitdir" CRASHES="$crashes" ARG1="${arg1:-}" ARG2="${arg2:-}" \
    CLANG_TIDY_BIN="$CLANG_TIDY_BIN" CLANG_TIDY_BUILD_DIR="$CLANG_TIDY_BUILD_DIR" \
        xargs -a "$outdir/files.txt" -P "$(nproc)" -I{} "$outdir/one.sh" {} || true

    cat "$unitdir"/*.txt > clang-tidy-full.txt 2>/dev/null
    echo "$(wc -l < clang-tidy-full.txt) lines of output"

    # Findings are debt and do not fail this mode. A crash does: the unit was not
    # analyzed, so the totals understate the real figure and the trend improves as
    # more files crash.
    if [ -s "$crashes" ]; then
        local count
        count=$(sort -u "$crashes" | wc -l)
        # Leave the list where a caller can render it; the log alone is awkward to
        # quote from a run summary.
        sort -u "$crashes" > clang-tidy-crashes.txt
        sed 's/^/  - /' clang-tidy-crashes.txt >&2
        err "clang-tidy crashed on $count of $total translation units — the survey is incomplete and its totals understate the debt."
        rm -rf "$outdir"
        return "$EX_NOVERDICT"
    fi
    rm -rf "$outdir"
}

run_mode() {
    case "$MODE" in
        check-tool) check_tool || return "$EX_NOVERDICT" ;;
        # The pre-flight checks mean the analysis did not run, so they report 2 rather
        # than falling through as if the code were clean.
        diff)       check_tool && check_scope && check_compile_db || return "$EX_NOVERDICT"
                    lint_diff ;;
        all)        check_tool && check_scope && check_compile_db || return "$EX_NOVERDICT"
                    lint_all ;;
        *)          err "unknown mode: $MODE"; return "$EX_NOVERDICT" ;;
    esac
}

# Removed first, so a status left by an earlier run cannot be read as this one's.
rm -f "$STATUS_FILE"
run_mode
rc=$?

# --------------------------------------------------------------------------
# The contract above is worth nothing to a caller that reaches this through `make`:
# GNU make answers 2 for any failed recipe and does not propagate the recipe's own
# status, so findings and a broken analysis arrive identical. Publishing the status
# where it survives the wrapper is what lets a caller be lenient about one and not the
# other. A caller invoking this directly can keep using $?.
# --------------------------------------------------------------------------
printf '%s\n' "$rc" > "$STATUS_FILE"
exit "$rc"
