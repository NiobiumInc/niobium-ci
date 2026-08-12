# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities **privately** via GitHub Security Advisories —
the "Report a vulnerability" button under this repository's **Security** tab. Do
not open a public issue for security reports.

## Secrets

This repository contains only reusable CI logic and **no secrets**. Consuming
repositories provide secrets at call time via the reusable-workflow `secrets:`
mechanism; nothing is stored here. Reusable workflows request minimal
`permissions:`, and consumers pin references by commit SHA or an immutable tag.
