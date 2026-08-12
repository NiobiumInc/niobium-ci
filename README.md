# niobium-ci

Reusable CI workflows and composite actions shared across Niobium repositories,
so consumers avoid duplicating CI logic.

## How it works

Each capability is a reusable workflow (a secret-touching wrapper that checks out,
authenticates, and runs the consumer-provided task command) plus a secret-free
composite action (the core logic). A consumer invokes it with a small caller
workflow that supplies inputs and, when needed, a secret. Secrets stay in the
consumer repository and are passed at call time — never stored here. The caller
pins the reference to a commit SHA or an immutable tag — never a moving branch —
so a change here cannot alter its CI until the pin is deliberately bumped.

```mermaid
flowchart TD
  subgraph shared["NiobiumInc/niobium-ci — public, pinned @vN"]
    RW["reusable workflow (workflow_call)<br/>secret-touching: checkout, auth, run task"]
    CA["composite action(s)<br/>secret-free core logic + scripts"]
    RW --> CA
  end
  subgraph repoA["consumer repo A (private)"]
    A["caller workflow<br/>inputs: task cmd + params<br/>secret: token"]
  end
  subgraph repoB["consumer repo B (public)"]
    B["caller workflow<br/>inputs only (no secret)"]
  end
  A -- "uses @vN, with inputs + secret" --> RW
  B -- "uses @vN, with inputs" --> RW
```

A single run flows from the caller through the reusable workflow to the composite
action:

```mermaid
sequenceDiagram
  participant Dev as push / PR
  participant Caller as caller workflow<br/>(consumer repo)
  participant RW as reusable workflow<br/>(niobium-ci @vN)
  participant CA as composite action<br/>(niobium-ci, secret-free)
  Dev->>Caller: trigger
  Caller->>RW: uses @vN (inputs + secrets)
  RW->>RW: checkout + auth (secret-touching)
  RW->>RW: run consumer-provided task command
  RW->>CA: delegate core logic over the prepared workspace
  CA->>CA: do the work, produce report / annotations
  CA-->>RW: result
  RW-->>Caller: pass / fail
```

## Capabilities

Each capability is documented here as its workflow is added. _None yet._

## Security

Secrets never live in this repository; consumers pass them at call time. See
`SECURITY.md`.

## License

Apache 2.0.
