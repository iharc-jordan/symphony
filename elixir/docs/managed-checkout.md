# Managed checkout preparation

Managed execution calls `SymphonyElixir.Managed.Checkout.prepare/5` through the
runner's trusted `workspace_preparer` callback, before `before_run` and before
starting Codex. Keep `hooks.after_create` empty for this profile; preparation
already supplies the provider-neutral `SYMPHONY_ISSUE_CONTEXT` to the plugin
helper. Generic workspace hooks retain their existing behavior.

The orchestrator passes its current assignment and attempt records. The helper
receives the Project membership identifier in `assignment_id`, the attempt ID,
base commit, repository, workspace, revision and generation. Underlying issue
ownership remains the orchestrator's responsibility. Issue requirements are not
copied into the hook context or checkout input.

Configure these values under `managed` in the service-owned `WORKFLOW.md`:

```yaml
managed:
  checkout_node: /opt/node/bin/node
  checkout_helper_path: /opt/symphony/plugin/mcp/cli.mjs
  checkout_policy_file: /etc/symphony-managed/checkout-policy.json
```

`managed.enabled: true` requires all three values and a non-empty control token.

Trusted options are absolute paths:

- `node_executable`: the existing Linux Node executable.
- `helper_path`: the pinned plugin `mcp/cli.mjs` bundle.
- `policy_file`: the private checkout policy supplied during setup.

The policy declares `control_root`, `workspace_root`, and the repository/remote
allowlist described in the plugin's checkout documentation. Preparation rejects
workspace escapes and a policy, helper, Node executable, or input directory
inside worker workspaces. The installed helper remains responsible for checking
the repository allowlist, native repository identity, Git origin and base commit.

Inputs are written under `control_root/attempts`. The directory has mode `0700`
and each input has mode `0600`. Repeating preparation for the same attempt may
reuse identical input; conflicting content or a symlink is rejected. Preparation
never overwrites an attempt input or deletes the checkout after failure. The
orchestrator must retain the attempt's ownership and reconcile uncertain effects
before authorizing another attempt.

The Node helper is invoked with separate arguments and a bounded hook-context
environment value. Tracker text is never inserted into shell source. Helper
failure is reported using its exit status without copying its output into logs.
Keep the pinned helper bundle available for the configured service's lifetime;
update its configured path as part of a plugin upgrade.

Focused verification:

```shell
mix test test/symphony_elixir/managed_checkout_test.exs
```

These tests execute a small argument/context probe and cover private immutable
inputs, revision mismatches, path escapes and preserved failures. The installed
plugin workflow separately proves the real repository checkout behavior.
