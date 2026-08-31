# Security Policy

## Status

This codebase is **unaudited**. The notes under `docs/*/security-notes/` are internal,
AI-assisted pre-audit reviews and fuzzing reports — they are **not** a third-party audit.
Deployments listed in `docs/deployments.md` are technical demos operated with EOA admin
and operator keys; see the *Trust assumptions* section of the README before depositing
any funds you are not prepared to lose.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security-sensitive findings.

Report privately via
[GitHub private vulnerability reporting](https://github.com/superfluid-org/stable-yield-vault/security/advisories/new).
Include a description of the issue, the affected contract(s) and function(s), and — if
possible — a Foundry test reproducing it against the current `main`.

We aim to acknowledge reports within 3 business days.

## Scope

- `src/**` — vault, fund manager, and macro contracts.
- `script/**` — deployment scripts and network configuration.

Out of scope: the Superfluid protocol itself (report via
[Superfluid's security policy](https://github.com/superfluid-finance/protocol-monorepo/blob/dev/SECURITY.md)),
OpenZeppelin, Morpho, and other third-party dependencies.
