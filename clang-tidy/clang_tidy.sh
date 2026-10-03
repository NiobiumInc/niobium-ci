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
#
# CLANG_TIDY_BLOCK_ON says which findings count as a failure in `diff` mode:
#   findings  all of them. The default, and what a project with a single tier wants.
#   errors    only a diagnostic clang-tidy printed as `error:`, which is what the
#             project's own .clang-tidy escalated under WarningsAsErrors. The
#             blocking tier is named there, so this script needs no list of checks
#             and cannot disagree with the configuration a developer reads.
#   none      none of them; the caller reports findings without acting on them.
#
# CLANG_TIDY_TIER says which of the project's checks run, again read from its own
# .clang-tidy rather than listed here:
#   all       every check it enables. The default.
#   blocking  only those it escalates under WarningsAsErrors: the checks that can
#             fail a pull request, so a gate need not wait for the rest.
#   advisory  every check it enables but those, so that a blocking and an advisory
#             run together cover what one `all` run does, without analyzing twice.
set -uo pipefail

MODE="${1:?usage: clang_tidy.sh check-tool|diff|all}"
HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CLANG_TIDY_VERSION:?}"
: "${CLANG_TIDY_SCOPE:?}"
: "${CLANG_TIDY_BUILD_DIR:=build}"
: "${CLANG_TIDY_BIN:=clang-tidy}"
: "${CLANG_TIDY_COMMITTED:=0}"
: "${CLANG_TIDY_BLOCK_ON:=findings}"
: "${CLANG_TIDY_TIER:=all}"
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

case "$CLANG_TIDY_BLOCK_ON" in
    findings|errors|none) ;;
    *) err "CLANG_TIDY_BLOCK_ON must be findings, errors or none, not '$CLANG_TIDY_BLOCK_ON'."
       exit "$EX_NOVERDICT" ;;
esac
case "$CLANG_TIDY_TIER" in
    all|blocking|advisory) ;;
    *) err "CLANG_TIDY_TIER must be all, blocking or advisory, not '$CLANG_TIDY_TIER'."
       exit "$EX_NOVERDICT" ;;
esac

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

# --------------------------------------------------------------------------
# The --checks value that narrows the project's configuration to CLANG_TIDY_TIER,
# empty for `all`: everything off, then the tier's checks by name. The checks the
# configuration enables (--list-checks) are split by WarningsAsErrors, read with
# clang-tidy's own rule that the last glob matching a name decides it:
#   blocking  the enabled checks it escalates.
#   advisory  every other enabled check, a negated escalation included.
# So the two partition what `all` runs, and both are read from the configuration
# clang-tidy itself resolves, so the tiers cannot drift from .clang-tidy.
# --list-checks never names the compiler's own warnings, so advisory carries the
# clang-diagnostic-* globs of Checks as globs, and escalating any of them has no tier.
# --------------------------------------------------------------------------
tier_checks() {
    [ "$CLANG_TIDY_TIER" = all ] && return 0
    local enabled
    enabled="$("$CLANG_TIDY_BIN" --list-checks)" || return 1
    "$CLANG_TIDY_BIN" --dump-config | ENABLED="$enabled" TIER="$CLANG_TIDY_TIER" python3 -c '
import json, os, re, sys
# A value is a YAML scalar. A block scalar in .clang-tidy (> or |) keeps its
# final newline, which --dump-config writes as a backslash-n escape inside
# double quotes: decoded, it is whitespace, and stripping a glob drops it.
def scalar(value):
    value = value.strip()
    if value.startswith("\""):
        return json.loads(value)
    if value.startswith("\x27"):
        return value[1:-1].replace("\x27\x27", "\x27")
    return value
# Globs are separated by commas or newlines, as clang-tidy reads them.
def globs(value):
    return [g.strip() for g in re.split(r"[,\n]", scalar(value)) if g.strip()]
config = {"Checks": [], "WarningsAsErrors": []}
for line in sys.stdin:
    m = re.match(r"^(Checks|WarningsAsErrors):\s*(.*)$", line)
    if m:
        config[m.group(1)] = globs(m.group(2))
escalated = config["WarningsAsErrors"]
def escalates(name):
    decided = False
    for glob in escalated:
        negated = glob.startswith("-")
        pattern = ".*".join(map(re.escape, glob.lstrip("-").split("*")))
        if re.fullmatch(pattern, name):
            decided = not negated
    return decided
# The globs that reach a compiler warning, those like -* written in its terms, from
# the last that switches every one off: what is left is what the list enables.
DIAGNOSTIC = "clang-diagnostic-"
def diagnostics(globs):
    kept = []
    for glob in globs:
        sign, pattern = ("-", glob[1:]) if glob.startswith("-") else ("", glob)
        if pattern.endswith("*") and DIAGNOSTIC.startswith(pattern[:-1]):
            pattern = DIAGNOSTIC + "*"
        elif not pattern.startswith(DIAGNOSTIC):
            continue
        kept = [] if sign + pattern == "-" + DIAGNOSTIC + "*" else kept + [sign + pattern]
    return kept if any(not g.startswith("-") for g in kept) else []
warnings = diagnostics(config["Checks"])
if warnings and diagnostics(escalated):
    sys.exit("WarningsAsErrors escalates compiler warnings, which --list-checks cannot name, so they have no tier: run all")
enabled = [ln.strip() for ln in os.environ["ENABLED"].splitlines() if ln.startswith(" ") and ln.strip()]
blocking = [name for name in enabled if escalates(name)]
if not blocking:
    sys.exit("no enabled check is escalated under WarningsAsErrors, so there is no blocking tier")
blocked = set(blocking)
tier = blocking if os.environ["TIER"] == "blocking" else [n for n in enabled if n not in blocked] + warnings
print(",".join(["-*"] + tier))
'
}

# --------------------------------------------------------------------------
# clang-tidy analyzes a file once for every compile command naming it, so a source
# built into several targets is analyzed, and reported, that many times. Analysis
# reads a copy of the database with one entry per file instead.
# --------------------------------------------------------------------------
dedupe_db() {
    # Going on after a failed mktemp would hand clang-tidy an empty -p.
    ANALYSIS_DB="$(mktemp -d -t nb-clang-tidy-db.XXXXXX)" || return 1
    python3 "$HELPERS/compile_db.py" --db "$DB" --dedupe-to "$ANALYSIS_DB"
}

# --------------------------------------------------------------------------
# There are findings. What they mean is the caller's policy, so say it the way that
# caller will act on it rather than asserting one answer for every consumer.
#
# The ::error:: prefix that err() adds is reserved for the cases that actually fail:
# GitHub renders it red, and a red annotation over a check that passed tells a
# reader the opposite of what happened. That is why a lenient caller gets a plain
# line here, and why `none` still returns EX_FINDINGS -- the exit code answers "were
# there findings?", which is true regardless of what the caller does about them.
#
# Anchored to the diagnostic shape rather than matching " error: " anywhere, so a
# finding whose own message quotes the word cannot be read as one.
# --------------------------------------------------------------------------
findings_verdict() {
    local fix="Fix them, or deviate a false positive inline with // NOLINT(check-name): <reason>."
    case "$CLANG_TIDY_BLOCK_ON" in
        errors)
            if ! grep -qE '^.+:[0-9]+:[0-9]+: error: ' clang-tidy-report.txt; then
                echo "clang-tidy: findings on changed lines, none at error severity." >&2
                return 0
            fi
            err "clang-tidy reported blocking findings on changed lines. $fix"
            ;;
        none)
            echo "clang-tidy reported findings on changed lines." >&2
            ;;
        *)
            err "clang-tidy reported findings on changed lines. $fix"
            ;;
    esac
    return "$EX_FINDINGS"
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
    [ -n "$CHECKS" ] && extra+=("-checks=$CHECKS")

    git diff -U0 "${range[@]}" -- "${tus[@]}" \
        | python3 "$driver" \
            -clang-tidy-binary "$CLANG_TIDY_BIN" \
            -p1 -path "$ANALYSIS_DB" -j "$(nproc)" \
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
        findings_verdict
        return $?
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
"$CLANG_TIDY_BIN" -p "$ANALYSIS_DB" --quiet ${CHECKS:+"--checks=$CHECKS"} \
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
    CLANG_TIDY_BIN="$CLANG_TIDY_BIN" ANALYSIS_DB="$ANALYSIS_DB" CHECKS="$CHECKS" \
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

# What both analyzing modes need before they start: the tier's checks and the
# deduplicated database. Failing either means there is no verdict to give.
prepare() {
    if ! CHECKS="$(tier_checks)"; then
        err "cannot narrow the analysis to the $CLANG_TIDY_TIER tier."
        return 1
    fi
    dedupe_db || { err "cannot write a deduplicated copy of $DB."; return 1; }
    [ -n "$CHECKS" ] && echo "tier $CLANG_TIDY_TIER: -checks=$CHECKS"
    return 0
}

run_mode() {
    case "$MODE" in
        check-tool) check_tool || return "$EX_NOVERDICT" ;;
        # The pre-flight checks mean the analysis did not run, so they report 2 rather
        # than falling through as if the code were clean.
        diff)       check_tool && check_scope && check_compile_db && prepare || return "$EX_NOVERDICT"
                    lint_diff ;;
        all)        check_tool && check_scope && check_compile_db && prepare || return "$EX_NOVERDICT"
                    lint_all ;;
        *)          err "unknown mode: $MODE"; return "$EX_NOVERDICT" ;;
    esac
}

# Removed first, so a status left by an earlier run cannot be read as this one's.
rm -f "$STATUS_FILE"
CHECKS=""
ANALYSIS_DB=""
run_mode
rc=$?
[ -n "$ANALYSIS_DB" ] && rm -rf "$ANALYSIS_DB"

# --------------------------------------------------------------------------
# The contract above is worth nothing to a caller that reaches this through `make`:
# GNU make answers 2 for any failed recipe and does not propagate the recipe's own
# status, so findings and a broken analysis arrive identical. Publishing the status
# where it survives the wrapper is what lets a caller be lenient about one and not the
# other. A caller invoking this directly can keep using $?.
# --------------------------------------------------------------------------
printf '%s\n' "$rc" > "$STATUS_FILE"
exit "$rc"
