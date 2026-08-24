#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests for clang_tidy.sh, over a synthetic repository and stub analyzers.
#
# The stubs matter more than they look: they let every branch be exercised without a
# real toolchain, including the ones that only appear when clang-tidy crashes or is
# the wrong version — the branches whose whole purpose is to keep a broken analysis
# from reporting green.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../clang-tidy" && pwd)/clang_tidy.sh"
VERSION=21.1.6
pass=0; fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL %s\n       %s\n' "$1" "$2"; fail=$((fail + 1)); }

# Asserts the exit status of a run. The contract is the point: 1 may be downgraded by
# a caller, anything else may not, so confusing the two would let an advisory gate
# swallow a crash.
expect_rc() {
    local want="$1" desc="$2"; shift 2
    local got; "$@" >/dev/null 2>&1; got=$?
    if [ "$got" = "$want" ]; then ok "$desc"; else no "$desc" "expected rc=$want, got rc=$got"; fi
}

expect_out() {
    local pattern="$1" desc="$2"; shift 2
    local out; out="$("$@" 2>&1)"
    if grep -qE "$pattern" <<<"$out"; then ok "$desc"; else no "$desc" "no match for /$pattern/ in: $out"; fi
}

# --------------------------------------------------------------------------
# A repository with: two compiled sources, one product source the build skips, a
# test under a product directory, tooling, and a header. Enough for scope selection,
# the compile-database intersection and drift to have something to say.
# --------------------------------------------------------------------------
setup() {
    REPO="$(mktemp -d)"; cd "$REPO" || exit 1
    mkdir -p src/Backend replay/tests tools bin
    for f in src/a.cpp src/b.cpp src/Backend/skipped.cpp replay/tests/t.cpp tools/u.cpp include/h.h; do
        mkdir -p "$(dirname "$f")"; echo "int x;" > "$f"
    done
    git init -q .; git config user.email t@t; git config user.name t
    git add -A; git commit -qm init

    mkdir -p build
    cat > build/compile_commands.json <<JSON
[
 {"directory": "$REPO/build", "file": "$REPO/src/a.cpp", "command": "c++ -c a"},
 {"directory": "$REPO", "file": "src/b.cpp", "command": "c++ -c b"},
 {"directory": "$REPO/build", "file": "$REPO/replay/tests/t.cpp", "command": "c++ -c t"},
 {"directory": "$REPO/build", "file": "$REPO/tools/u.cpp", "command": "c++ -c u"}
]
JSON

    stub clean  'exit 0'
    stub find   "echo \"\$REPO/src/a.cpp:2:1: warning: found [modernize-use-auto]\"; exit 1"
    stub crash  'echo "PLEASE submit a bug report" >&2; exit 139'
    stub oldver 'exit 0' 19.9.9

    export CLANG_TIDY_VERSION="$VERSION" CLANG_TIDY_BUILD_DIR=build
    export CLANG_TIDY_SCOPE="src/** replay/** :(exclude)**/tests/**"
    export CLANG_TIDY_COMMITTED=1
    unset CLANG_TIDY_DIFF CLANG_TIDY_BASE
}

stub() {
    local name="$1" body="$2" ver="${3:-$VERSION}"
    cat > "bin/ct-$name" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "LLVM version $ver"; exit 0; fi
$body
STUB
    chmod +x "bin/ct-$name"
}

# A stand-in for clang-tidy-diff.py that reports whatever the analyzer prints, so the
# tests do not depend on a copy of the real driver being installed.
fake_driver() {
    cat > "$REPO/driver.py" <<'PY'
import subprocess, sys
binary = sys.argv[sys.argv.index("-clang-tidy-binary") + 1]
files = [ln[4:].strip() for ln in sys.stdin if ln.startswith("+++ ")]
rc = 0
for f in files:
    p = subprocess.run([binary, f.lstrip("b/")], capture_output=True, text=True)
    sys.stdout.write(p.stdout); sys.stderr.write(p.stderr)
    rc = rc or p.returncode
sys.exit(rc)
PY
    export CLANG_TIDY_DIFF="$REPO/driver.py"
}

change_a_compiled_source() {
    CLANG_TIDY_BASE="$(git rev-parse HEAD)"; export CLANG_TIDY_BASE
    echo "int y;" >> src/a.cpp; git commit -qam change
}

echo "clang_tidy.sh"

# --- the exit-code contract ------------------------------------------------
setup; fake_driver; change_a_compiled_source
CLANG_TIDY_BIN="$REPO/bin/ct-clean"  expect_rc 0 "diff: clean run exits 0" bash "$SUT" diff
CLANG_TIDY_BIN="$REPO/bin/ct-find"   expect_rc 1 "diff: findings exit 1, the only downgradable status" bash "$SUT" diff
CLANG_TIDY_BIN="$REPO/bin/ct-crash"  expect_rc 2 "diff: a crash exits 2, never 1" bash "$SUT" diff
CLANG_TIDY_BIN="$REPO/bin/ct-oldver" expect_rc 2 "diff: wrong analyzer version exits 2" bash "$SUT" diff
CLANG_TIDY_BIN="$REPO/bin/ct-oldver" expect_rc 2 "check-tool: wrong version exits 2, not 1" bash "$SUT" check-tool
CLANG_TIDY_BIN="$REPO/bin/ct-clean"  expect_rc 0 "check-tool: right version exits 0" bash "$SUT" check-tool

export CLANG_TIDY_BIN="$REPO/bin/ct-clean"
# Overrides go through `env` rather than a subshell: a subshell cannot report a
# failure back to the counters, and a plain assignment after `unset` drops the export
# attribute, so the script under test would never see the value.
expect_rc 2 "diff: a scope matching nothing exits 2 rather than passing" \
    env CLANG_TIDY_SCOPE='nothing/**' bash "$SUT" diff
expect_rc 2 "diff: a missing compile database exits 2" \
    env CLANG_TIDY_BUILD_DIR=absent bash "$SUT" diff
expect_rc 2 "diff: no diff base exits 2" \
    env -u CLANG_TIDY_BASE bash "$SUT" diff
expect_rc 2 "diff: no diff driver exits 2" \
    env CLANG_TIDY_DIFF=/absent.py bash "$SUT" diff

# --- the published status --------------------------------------------------
# An intermediary need not preserve an exit code -- `make` answers 2 for any failed
# recipe -- so the status is published where a caller can read it back.
setup; fake_driver; change_a_compiled_source
export CLANG_TIDY_BIN="$REPO/bin/ct-find"
bash "$SUT" diff >/dev/null 2>&1
if [ "$(cat clang-tidy-status.txt 2>/dev/null)" = "1" ]; then
    ok "diff: findings publish status 1 to clang-tidy-status.txt"
else
    no "diff: findings publish status 1 to clang-tidy-status.txt" "got '$(cat clang-tidy-status.txt 2>/dev/null)'"
fi

export CLANG_TIDY_BIN="$REPO/bin/ct-crash"
bash "$SUT" diff >/dev/null 2>&1
if [ "$(cat clang-tidy-status.txt 2>/dev/null)" = "2" ]; then
    ok "diff: a crash publishes status 2, which a caller must not downgrade"
else
    no "diff: a crash publishes status 2" "got '$(cat clang-tidy-status.txt 2>/dev/null)'"
fi

export CLANG_TIDY_BIN="$REPO/bin/ct-clean"
bash "$SUT" diff >/dev/null 2>&1
if [ "$(cat clang-tidy-status.txt 2>/dev/null)" = "0" ]; then
    ok "diff: a clean run replaces the previous status rather than leaving it"
else
    no "diff: a clean run replaces the previous status" "got '$(cat clang-tidy-status.txt 2>/dev/null)'"
fi

# --- selection -------------------------------------------------------------
setup; fake_driver
CLANG_TIDY_BASE="$(git rev-parse HEAD)"; export CLANG_TIDY_BASE
echo "int y;" >> src/Backend/skipped.cpp; git commit -qam skipped
export CLANG_TIDY_BIN="$REPO/bin/ct-find"
expect_out "No analyzable in-scope changes" \
    "diff: a changed source the build does not compile needs no hand-written exclusion" \
    bash "$SUT" diff
expect_rc 0 "diff: and that is a pass, not a finding" bash "$SUT" diff

setup
export CLANG_TIDY_BIN="$REPO/bin/ct-clean"
expect_out "analyzing 2 translation units" \
    "all: analyzes in-scope compiled units only — not the test, the tooling or the uncompiled source" \
    bash "$SUT" all
expect_out "2 compiled tracked unit\(s\) outside scope" \
    "all: reports what the scope leaves out" bash "$SUT" all

setup
export CLANG_TIDY_BIN="$REPO/bin/ct-clean"
bash "$SUT" all >/dev/null 2>&1
if grep -qE 'replay/tests/t\.cpp' clang-tidy-unscoped.txt && grep -qE 'tools/u\.cpp' clang-tidy-unscoped.txt; then
    ok "all: names the excluded units"
else
    no "all: names the excluded units" "$(cat clang-tidy-unscoped.txt)"
fi

# --- state that must not survive a run -------------------------------------
setup
export CLANG_TIDY_BIN="$REPO/bin/ct-clean"
echo "src/gone.cpp" > clang-tidy-crashes.txt
bash "$SUT" all >/dev/null 2>&1
if [ -f clang-tidy-crashes.txt ]; then
    no "all: a stale crash list does not survive a clean run" "the file is still there"
else
    ok "all: a stale crash list does not survive a clean run"
fi

setup
export CLANG_TIDY_BIN="$REPO/bin/ct-crash"
expect_rc 2 "all: a crashed unit fails the survey — its totals would understate the debt" bash "$SUT" all
if [ -s clang-tidy-crashes.txt ]; then ok "all: a real crash is recorded"; else no "all: a real crash is recorded" "empty"; fi

# --- the report is only diagnostics ----------------------------------------
setup
export CLANG_TIDY_BIN="$REPO/bin/ct-find"
bash "$SUT" all >/dev/null 2>&1
# Every line must be a diagnostic. The file lists of units and of excluded paths are
# *.txt too, and a flat working directory would let them be concatenated in here,
# where they parse as nothing and quietly pad the artifact.
if stray=$(grep -vE ':[0-9]+:[0-9]+: (warning|error): ' clang-tidy-full.txt | grep -vE '^\s*$'); then
    no "all: the report holds diagnostics only" "$(head -3 <<<"$stray")"
else
    ok "all: the report holds diagnostics only"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
