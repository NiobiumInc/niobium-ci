#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Installs the pinned clang-tidy and prints its absolute path on stdout.
#
# It lives here, reached through the submodule, rather than in a composite action
# referenced by tag. A commit cannot contain its own SHA, so an internal `uses:`
# reference can only name a tag — and a retag would then change behaviour underneath
# a consumer that pinned the workflow by SHA. Through the submodule it is pinned by
# the gitlink, like the rest of the analysis.
#
# The version is installed rather than taken from the host: with WarningsAsErrors
# every check is fatal, so an analyzer chosen by the runner makes a verdict depend on
# job placement rather than on the code.
#
# Useful locally too — it installs exactly what `make clang-tidy-version` demands.
# Progress goes to stderr so the path is the only thing on stdout.
set -euo pipefail

: "${CLANG_TIDY_VERSION:?}"

{
  echo "Installing clang-tidy==${CLANG_TIDY_VERSION}"
  python3 -m pip install --user --quiet "clang-tidy==${CLANG_TIDY_VERSION}" \
    || python3 -m pip install --user --quiet --break-system-packages "clang-tidy==${CLANG_TIDY_VERSION}"
} >&2

user_bin="$(python3 -m site --user-base)/bin"
bin="$user_bin/clang-tidy"
if [ ! -x "$bin" ]; then
  echo "::error::pip reported success but $bin is missing or not executable" >&2
  exit 1
fi

# Inside a GitHub Actions job this hands the directory to later steps. Absent
# elsewhere, where the caller uses the printed path.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$user_bin" >> "$GITHUB_PATH"
fi

"$bin" --version >&2

# clang-tidy-diff.py is not part of the pip package, and diff mode needs it. Fetching
# it here is what keeps `make clang-tidy` free of manual setup: without it, anyone
# lacking clang-tools-extra has to locate the script and set CLANG_TIDY_DIFF by hand.
#
# Fetched rather than vendored — its Apache-2.0-with-LLVM-exception licence would
# otherwise land in this repository — and pinned to the release tag matching the
# analyzer. The version is in the filename so a changed pin cannot reuse the old copy.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/niobium-ci"
driver="$cache/clang-tidy-diff-${CLANG_TIDY_VERSION}.py"   # keep in step with clang_tidy.sh
if [ ! -f "$driver" ]; then
  mkdir -p "$cache"
  echo "Fetching clang-tidy-diff.py for ${CLANG_TIDY_VERSION}" >&2
  curl -fsSL --retry 3 -o "$driver.tmp" \
    "https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-${CLANG_TIDY_VERSION}/clang-tools-extra/clang-tidy/tool/clang-tidy-diff.py"
  # Atomic: a truncated download must not be left looking like a cached one.
  mv "$driver.tmp" "$driver"
fi
echo "clang-tidy-diff.py at $driver" >&2

echo "$bin"
