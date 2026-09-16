# Symphony Elixir for Codex Orchestration

This directory contains the native Windows 11 x64 Symphony runtime paired with the Codex
Orchestration plugin. Symphony polls or receives managed work, creates one local workspace per
assignment, and runs Codex App Server inside an owned Windows Job Object.

The supported installed path is the paired `0.4.0` plugin and runtime release. End users do not
install Erlang, Elixir, Rust, WSL, SSH services, or a second Codex copy. The plugin resolves the
installed `%APPDATA%\npm\codex.cmd`, creates the protected local configuration, installs the hidden
least-privilege Task Scheduler task, and downloads the pinned Windows runtime ZIP.

## Runtime layout

The installed launcher supplies absolute paths before the OTP supervisors start:

- workflow: `%LOCALAPPDATA%\CodexOrchestration\config\WORKFLOW.md`
- SQLite state: `%LOCALAPPDATA%\CodexOrchestration\state\managed.sqlite3`
- logs: `%LOCALAPPDATA%\CodexOrchestration\logs`
- workspaces: `%LOCALAPPDATA%\CodexOrchestration\workspaces`
- immutable releases: `%LOCALAPPDATA%\CodexOrchestration\releases\<version>`

The HTTP control server binds only to `127.0.0.1` and requires the protected installation token.
The native MCP bridge is the supported control client.

## Workflow configuration

`WORKFLOW.md` contains YAML front matter followed by the worker prompt. A minimal GitHub Projects
managed workflow is:

```md
---
tracker:
  kind: github_projects
  provider:
    owner_type: user
    owner: your-account
    project_number: 1
    token: $GITHUB_TOKEN
  active_states: [READY, IN PROGRESS]
  terminal_states: [DONE, CANCELLED]
polling:
  interval_ms: 30000
hooks:
  after_create: |
    git clone --depth 1 $env:SOURCE_REPOSITORY_URL .
  timeout_ms: 60000
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  launcher: C:\Users\you\AppData\Roaming\npm\codex.cmd
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
managed:
  enabled: true
---

Complete assignment {{ issue.identifier }} in the provided workspace.
```

The plugin writes `codex.launcher`; workflow authors cannot supply an arbitrary shell command or
launcher arguments. Symphony constructs the fixed `app-server` invocation and disables Codex
subagent delegation for managed workers because Symphony owns assignment scheduling.

Important settings:

- `tracker.kind` selects the provider adapter. Managed assignments use GitHub Projects and the
  repository recorded by the enrolled Project item.
- `tracker.provider` owns provider endpoint, scope, and credential references.
- `agent.max_concurrent_agents` is the global cap; positive entries in
  `agent.max_concurrent_agents_by_state` override it for named states.
- `agent.max_turns` limits continuation turns for one worker attempt.
- `codex.approval_policy`, `thread_sandbox`, and `turn_sandbox_policy` pass through to the installed
  Codex App Server protocol.
- `codex.read_timeout_ms`, `turn_timeout_ms`, and `stall_timeout_ms` bound protocol reads and worker
  silence.
- `managed.usage_limit_tokens` is optional. When set, persisted accounting must prove remaining
  headroom before dispatch.
- `managed.store_path` is the single SQLite state file used outside the installed launcher; the
  installed Windows service fixes it to `%LOCALAPPDATA%\CodexOrchestration\state\managed.sqlite3`.

Tracker credentials stay in the Symphony host process and are removed from the Codex child
environment. Do not place literal credentials in a repository-owned workflow; use `$VAR`
references.

Workspace hooks are non-interactive PowerShell. The hook receives `SYMPHONY_ISSUE_CONTEXT`, a
bounded UTF-8 JSON object containing only `id`, `identifier`, and provider-native identity metadata.
Hook and worker descendants share the same Job Object containment and bounded shutdown path.

## Native safety boundaries

- Workspace create, reuse, hooks, and deletion revalidate canonical descendant paths and reject
  junctions or other reparse points.
- Managed checkout uses the enrolled GitHub repository URL and base commit. There is no remote shell
  or alternate worker-host path.
- A worker identity records the Job name, PID, process creation time, and attempt. Stop validates
  process identity and Job membership before terminating that Job.
- Managed state is one versioned SQLite snapshot row on one connection. Writes use a transaction;
  lock, corruption, and write failures are surfaced rather than replayed as success.

## Build from source

Source builds require Windows x64, Erlang/OTP `28.5.0.6`, Elixir `1.19.6`, Rust, Git, and PowerShell
7:

```powershell
mix deps.get
mix compile --warnings-as-errors
mix test
.\scripts\build-windows-release.ps1
```

The build creates `dist\symphony-<version>-windows-x64.zip`, its SHA-256 file, and
`dist\release-manifest.json`. The ZIP contains a standard Mix release with embedded
ERTS, `bin\symphony.bat`, and `bin\symphony-worker-host.exe`; Erlang distribution is
disabled and no release cookie file is shipped. The installed controller is owned
by the native Windows Job helper, so stopping its Scheduled Task terminates the
complete controller process tree without Erlang RPC.

Focused Windows checks:

```powershell
cargo test --manifest-path native\symphony_worker_host\Cargo.toml
powershell.exe -NoProfile -ExecutionPolicy Bypass -File native\symphony_worker_host\tests\windows_job_regression.ps1
mix test test\symphony_elixir\windows_workspace_safety_test.exs
mix test test\symphony_elixir\managed_journal_test.exs test\symphony_elixir\managed_orchestrator_test.exs
```

See [`../SPEC.md`](../SPEC.md) for the runtime contract and the plugin repository for installation,
upgrade, rollback, diagnostics, and managed PM usage.

## License

Apache License 2.0. See [`../LICENSE`](../LICENSE) and [`../NOTICE`](../NOTICE).
