# clang-tidy — shared implementation

`clang_tidy.sh` is the one way a project runs clang-tidy. Developers reach it through
`make clang-tidy`; CI reaches it through the same target. A local check and the gate
cannot report different things if they are the same command over the same file.

| File | Role |
|---|---|
| `clang_tidy.sh` | the analysis: `check-tool`, `diff`, `all` |
| `compile_db.py` | intersects candidate paths with `compile_commands.json` |
| `clang_tidy_report.py` | renders annotations, a job summary, or a count |
| `setup_clang_tidy.sh` | installs the pinned analyzer; prints its path. Handy locally too |

The scripts are secret-free. They read no token and need none.

## How a consumer gets them

As a submodule, pinned by commit SHA: one implementation, a pin git itself enforces, and
no way for a local edit to enter the consumer's history — the gitlink would not change.

```sh
git submodule add https://github.com/NiobiumInc/niobium-ci .niobium-ci
git commit -m "ci: add shared CI as a submodule"
```

Nothing else in the consumer needs to change for the *configuration*: `.clang-tidy`
stays where it is and remains that repository's own. What is shared is the runner, not
the policy.

### What a developer does

Once:

```sh
git submodule update --init .niobium-ci        # already required to build
bash .niobium-ci/clang-tidy/setup_clang_tidy.sh   # unless clang-tools-extra is installed
```

`setup_clang_tidy.sh` installs the pinned analyzer and caches `clang-tidy-diff.py`
beside it. It exists so that nothing has to be configured by hand: without it, anyone
lacking clang-tools-extra would have to locate that script and set `CLANG_TIDY_DIFF`.

Then, day to day:

```sh
make clang-tidy       # the lines you changed
make clang-tidy-all   # every in-scope translation unit — slow
make clang-tidy-version   # is my analyzer the one CI uses?
```

No variables, no flags. Two things must already be true, and both are for anyone who
builds the project: the submodule is initialised, and the build is configured — the
analysis reads `compile_commands.json` and does not generate it.

Locally `make clang-tidy` analyzes the **working tree**, which is what you are about to
commit. CI analyzes the committed range. `make clang-tidy COMMITTED=1` reproduces the
gate exactly; it is the only knob, and it is optional.

### Makefile

The variables are the consumer's; only the script path points into the submodule.

```make
NIOBIUM_CI           ?= .niobium-ci
CLANG_TIDY_VERSION   ?= 21.1.6
CLANG_TIDY_BIN       ?= clang-tidy
CLANG_TIDY_BUILD_DIR ?= build
# What to analyze: everything this repository's release build compiles, minus what is
# not ours to fix. One definition, used by the gate and the survey alike.
#
# Prefer stating exclusions over listing directories: code newly added to the product
# is then analyzed without anyone remembering to add it. Submodule contents need no
# exclusion — git does not list them — so this covers third-party committed in-tree.
CLANG_TIDY_SCOPE     ?= :(exclude)**/tests/** :(exclude)examples/** :(exclude)vendor/**
# Where the change starts. Locally the fork point; CI overrides it with the base its
# pull request merges into.
CLANG_TIDY_BASE      ?= $(shell git merge-base origin/main HEAD 2>/dev/null)
# Analyze the working tree by default — what you are about to commit. COMMITTED=1
# reproduces what CI reviews.
CLANG_TIDY_COMMITTED ?= $(if $(COMMITTED),1,0)

CLANG_TIDY_ENV = CLANG_TIDY_VERSION="$(CLANG_TIDY_VERSION)" \
	CLANG_TIDY_BIN="$(CLANG_TIDY_BIN)" \
	CLANG_TIDY_BUILD_DIR="$(CLANG_TIDY_BUILD_DIR)" \
	CLANG_TIDY_SCOPE="$(CLANG_TIDY_SCOPE)" \
	CLANG_TIDY_BASE="$(CLANG_TIDY_BASE)" \
	CLANG_TIDY_COMMITTED="$(CLANG_TIDY_COMMITTED)" \
	CLANG_TIDY_DIFF="$(CLANG_TIDY_DIFF)"

# Fail with instructions rather than a confusing "no such file": a fresh clone without
# --recurse-submodules has the directory but not the contents.
CLANG_TIDY_SH = $(NIOBIUM_CI)/clang-tidy/clang_tidy.sh
$(CLANG_TIDY_SH):
	@echo "$(NIOBIUM_CI) is empty — run: git submodule update --init $(NIOBIUM_CI)" >&2; exit 1

clang-tidy: $(CLANG_TIDY_SH) ## clang-tidy on the lines changed against main (COMMITTED=1 for HEAD only)
	@$(CLANG_TIDY_ENV) bash $(CLANG_TIDY_SH) diff

clang-tidy-all: $(CLANG_TIDY_SH) ## clang-tidy over every in-scope translation unit (slow)
	@$(CLANG_TIDY_ENV) bash $(CLANG_TIDY_SH) all

clang-tidy-version: $(CLANG_TIDY_SH) ## Check the local clang-tidy is the version CI uses
	@$(CLANG_TIDY_ENV) bash $(CLANG_TIDY_SH) check-tool

print-clang-tidy-version: ## Print the analyzer version this project expects
	@echo $(CLANG_TIDY_VERSION)

print-clang-tidy-scope: ## Print the pathspec of product code
	@echo '$(CLANG_TIDY_SCOPE)'
```

`print-clang-tidy-version` and `print-clang-tidy-scope` exist for CI: the gate reads the
version to install the analyzer, and reads the scope to decide whether anything relevant
changed before paying for a build.

Run the script from the repository root. It uses `git ls-files` and `git diff` against
the current directory, so from inside the submodule it would inspect the wrong
repository.

### Caller workflows

```yaml
# .github/workflows/ci-clang-tidy.yml
name: CI - clang-tidy static analysis
on:
  pull_request:
  workflow_dispatch:
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  clang-tidy:
    uses: NiobiumInc/niobium-ci/.github/workflows/clang-tidy-diff.yml@<commit-sha>
    with:
      runs-on: '["self-hosted","your-runner-label"]'
      build-command: bash .github/scripts/build-compile-db.sh
    secrets:
      token: ${{ secrets.YOUR_ORG_TOKEN }}
```

```yaml
# .github/workflows/nightly-clang-tidy.yml -- the cadence is the consumer's choice
name: Nightly - clang-tidy whole-repo survey
on:
  schedule: [{ cron: '0 7 * * *' }]
  workflow_dispatch:
jobs:
  survey:
    uses: NiobiumInc/niobium-ci/.github/workflows/clang-tidy-all.yml@<commit-sha>
    with:
      runs-on: '["self-hosted","your-runner-label"]'
      build-command: bash .github/scripts/build-compile-db.sh
    secrets:
      token: ${{ secrets.YOUR_ORG_TOKEN }}
```

Pin by commit SHA. These workflows reference nothing in `niobium-ci` by tag — the
analyzer install comes from the submodule, and the only remote actions they use are
third-party ones already pinned by SHA — so a SHA pin here is immutable end to end, and
no release or tag is required. Dependabot's `github-actions` ecosystem keeps it current
and annotates the bump with the version.

The two workflows are named after what they analyze — the changed lines, or everything
in scope — matching the modes of `clang_tidy.sh`. Whether findings block, and how often
the whole-repository pass runs, are the consumer's choices and do not appear in a name.

A reusable workflow cannot schedule itself — `on: schedule` and `on: workflow_call` are
different triggers — so the nightly needs this small caller even though no person
invokes it.

`build-command` is the consumer's own. Everything the build needs, submodule fetching
included, belongs there: it stays private, and the token reaches it as `$GH_TOKEN` from
the one step that legitimately holds a secret.

### Reporting without blocking

A gate that is routinely overridden protects nothing, so it can be made advisory:

```yaml
    with:
      fail-on-findings: false
```

The check then reports green while findings still appear as inline annotations on the
affected lines and in the job summary, with a note saying they did not block. Leniency
applies to findings only: a crashed analyzer, a version mismatch, a broken scope or a
missing compile database still fail, because there is no verdict to be lenient about and
a green check would assert something nobody verified.

The nightly is unaffected — it never failed on findings — so the debt total stays as the
signal for whether an advisory gate is letting findings accumulate.

Every other input has a working default; see the two workflow files for the full list.

### Files the analysis writes

Into the repository root, on each run: `clang-tidy-report.txt`, `clang-tidy-stderr.txt`
(diff mode), `clang-tidy-full.txt`, `clang-tidy-unscoped.txt`, `clang-tidy-status.txt`
and, only when something crashed, `clang-tidy-crashes.txt`. Add them to the consumer's `.gitignore` — CI
workspaces are disposable, but a developer's is not.

## Keeping the pin current

Bumping the submodule is a one-line change to the gitlink, so it goes through review
like anything else:

```sh
git -C .niobium-ci fetch origin
git -C .niobium-ci checkout <tag-or-sha>
git add .niobium-ci && git commit -m "ci: bump shared CI to <tag>"
```

Note what the reviewer sees: `-Subproject commit a1b2c3d` / `+Subproject commit e5f6a7b`
— the pointer, not the code. Include a compare link in the pull request body, or the
approval is a formality. `https://github.com/NiobiumInc/niobium-ci/compare/<old>...<new>`

Dependabot can raise these automatically with `package-ecosystem: gitsubmodule`.
**Check the scoping before enabling it in a repository with many submodules** — the
ecosystem covers *all* of them, so an unrestricted configuration in a repo carrying
twenty-odd dependencies will open twenty-odd pull requests. Restrict it to this
submodule, or bump by hand until that is confirmed.
