# niobium-ci

Shared CI for Niobium repositories, so consumers do not duplicate CI logic.

## How it works

Two kinds of thing live here, consumed two different ways.

**Reusable workflows** are referenced remotely with `uses:` at a pinned ref. They own
what a local run has no equivalent for: checkout and authentication, a pull request's
diff base, skipping expensive work when nothing relevant changed, and rendering
results into GitHub. They are the only place a consumer's secret is touched, and they
reference nothing in this repository by tag — so a consumer pinning by SHA gets a pin
that cannot move.

**Scripts** are checked out by the consumer as a **submodule**, pinned by commit SHA.
Work that a developer also runs on their own machine belongs here rather than inside a
workflow: a check that exists only in CI cannot be reproduced locally, and two copies
that merely ought to match eventually will not. Both sides execute the same file at
the same pinned commit.

Configuration is not shared. What a repository checks, which tool versions it expects
and which rules it enforces stay in that repository. What is shared is the runner, not
the policy.

```mermaid
flowchart TD
  subgraph shared["NiobiumInc/niobium-ci — public, zero secrets"]
    RW["reusable workflows (workflow_call)<br/>checkout · auth · diff base · rendering"]
    SC["scripts<br/>the work a developer also runs"]
  end
  subgraph consumer["consumer repository"]
    CW["caller workflow<br/>inputs + secret"]
    MK["Makefile<br/>one command per task"]
    SM[".niobium-ci/<br/>submodule, pinned by SHA"]
    CFG["configuration<br/>scope · tool versions · rules"]
  end
  DEV["developer"] --> MK
  CW -- "uses @pin, with inputs + secret" --> RW
  RW -- "runs the same command" --> MK
  MK --> SM
  MK -.- CFG
  SC -. "one implementation" .- SM
```

A run flows from the caller through the reusable workflow, which prepares the
workspace and then delegates the work to the consumer's own command:

```mermaid
sequenceDiagram
  participant Dev as pull request
  participant Caller as caller workflow<br/>(consumer)
  participant RW as reusable workflow<br/>(niobium-ci @pin)
  participant Repo as consumer workspace
  Dev->>Caller: trigger
  Caller->>RW: uses @pin (inputs + secrets)
  RW->>Repo: checkout, init the shared submodule
  RW->>RW: resolve what changed, skip if nothing relevant did
  RW->>Repo: run the consumer's build command (the only step holding a secret)
  RW->>Repo: run the same command a developer runs
  Repo-->>RW: result
  RW->>RW: annotations, job summary, artifact
  RW-->>Caller: pass / fail
```

## Capabilities

Each capability documents its own setup — the submodule, the commands a consumer wires
up, and the caller workflows.

- **clang-tidy** — diff-only gate and whole-repository survey.
  See [`clang-tidy/README.md`](clang-tidy/README.md).

## Security

Secrets never live in this repository. Consumers pass them at call time to a reusable
workflow, which exposes them to the single step that needs them; the shared scripts are
secret-free and read no token. Pin every reference — a commit SHA or an immutable tag,
never a moving branch — so a change here cannot alter a consumer's CI until the pin is
deliberately bumped. See `SECURITY.md`.

## License

Apache 2.0.
