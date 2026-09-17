---
tracker:
  kind: github_projects
  provider:
    owner_type: user
    owner: your-account
    project_number: 1
    token: $GITHUB_TOKEN
  active_states:
    - READY
    - IN PROGRESS
    - REWORK
  terminal_states:
    - DONE
    - CANCELLED
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 10
  max_concurrent_agents_by_state: {}
  max_turns: 20
codex:
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
  read_timeout_ms: 60000
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
managed:
  enabled: true
---

Complete the assigned work in the provided repository workspace.

Use the assignment requirements and current repository state as the source of truth. Preserve
unrelated work, validate the changed behavior, and report concrete completion evidence or the exact
external blocker. Do not delegate: Symphony owns worker scheduling and peer-evidence routing.
