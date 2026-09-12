# Codex Orchestration Symphony

This public fork packages the Symphony scheduler used by the Codex Orchestration plugin. The managed product has one supported host: Windows 11 x64.

The desktop Codex task remains the delivery PM. It talks to a loopback-only MCP bridge; Symphony owns scheduling and recovery; native Windows Codex app-server workers execute assignments in isolated local workspaces.

## Supported product path

- Windows 11 x64.
- GitHub Projects and repository issues as the managed work source.
- A standard Mix release ZIP built on Windows with Erlang/OTP 28, Elixir 1.19, native dependencies, and the small Windows worker-host helper included.
- `%LOCALAPPDATA%\CodexOrchestration` for versioned releases, configuration, state, logs, and workspaces.
- One hidden least-privilege Task Scheduler logon task installed by the plugin.
- A single SQLite snapshot connection for managed state.
- Per-attempt Windows Job Objects for worker and hook process trees.

End users do not need Erlang, Elixir, Rust, a compiler, WSL, or a second Codex installation. WSL may still be used independently as repository tooling, but it is not an orchestration runtime or fallback. Managed SSH and Linux release targets are not supported.

Other upstream tracker adapters remain source-level Symphony components. They are not exposed as alternate managed-product paths.

## Install

Install the paired `0.3.0` Codex Orchestration plugin release. Its lifecycle commands download the pinned Windows runtime manifest or accept the same release ZIP offline with an explicit SHA-256 digest. The installer verifies the archive, stages an immutable version directory, and switches the stable launcher only after the prior runtime has stopped.

Runtime controls and setup are documented in the plugin repository: <https://github.com/iharc-jordan/codex-orchestration>.

## Build from source

Source builds require Windows x64, Erlang/OTP `28.5.0.6`, Elixir `1.19.6`, Rust, Git, and PowerShell 7:

```powershell
cd elixir
mix deps.get
mix test
.\scripts\build-windows-release.ps1
```

The build emits a ZIP, checksum, and release manifest under `elixir\dist`. The ZIP contains the standard Mix release tree, embedded ERTS, `bin\symphony.bat`, `bin\symphony-worker-host.exe`, the license, and notices.

See [the implementation guide](elixir/README.md) for configuration and focused validation.

## Operational boundaries

- The HTTP control endpoint binds only to `127.0.0.1` and requires the protected local token.
- WORKFLOW.md owns managed policy and prompts. The installed launcher resolves machine paths before the OTP application supervisor starts.
- SQLite keeps one versioned snapshot row; the existing bounded event list stays inside that state.
- Worker shutdown first uses the app-server protocol, then terminates only the verified owned Job Object after the bounded grace period.
- Browser-capable workers use their own installed tools. Shared browser state is serialized through managed resource claims; there is no browser relay.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
