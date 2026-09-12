# Codex Orchestration Symphony

This directory contains the Windows 11 x64 Symphony scheduler used by Codex Orchestration. It creates local per-assignment workspaces and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` on OTP 28. Release builds run natively on Windows x64.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Policy and prompts are loaded from `WORKFLOW.md`; the installed launcher supplies resolved absolute machine paths before supervisors start.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
  - Reject reparse-point, case, drive, root, and outside-root escapes on every create, reuse, and delete.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Simplicity is a project constraint: prefer the smallest coherent design with one clear owner and
  invariant. Push back on extra abstractions, duplicated policy, and speculative flexibility.
- For stateful changes, check startup, reload, restart, and failure recovery together before editing.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

- Prefer narrow tests that exercise real OTP processes and observable behavior over mock-only or
  broad end-to-end coverage; prove health with a synchronous call or stable effect, not only a PID.
- For non-trivial changes, exercise concrete adjacent lifecycle failures; a reproducible failure blocks landing.
- If tests need repeated global restarts or bespoke cleanup, first fix the shared harness or
  ownership boundary.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Evaluate proposed directions instead of agreeing reflexively; surface simpler designs and material
  trade-offs early.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
