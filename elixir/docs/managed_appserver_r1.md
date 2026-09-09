# Managed AppServer R1

Managed sessions are opt in through AppServer.start_session/2 and AgentRunner.run/3.
They carry one attempt identity for the lifetime of the worker:

- assignment_id: tracker assignment identity
- revision: source or assignment revision
- generation: non negative retry generation
- attempt_id: unique worker attempt identity

The managed route defaults to model gpt-5.6-luna with xhigh effort. The permitted
managed routes are Luna or Terra with xhigh or max effort. Terra or max requires
an escalation_reason. If route copies are present in the attempt metadata, they
must equal the explicit route options. Astra and silent substitutions are
rejected.

A resumed managed session sends thread/resume with the exact supplied
resume_thread_id. A start or resume response must contain the same thread id and
must report the requested model. Missing or different model identity stops the
attempt before on_session or the first turn. The initial reasoningEffort may be
null because effort is applied by turn/start; the selected turn wire includes
and records the configured effort.

The managed dynamic tool orchestration_report accepts result, checkpoint, and
context_needed reports. Every accepted report callback payload includes the
attempt identity, thread id, turn id, report kind, report id, summary, and
evidence. Checkpoint reports continue the current turn. Result and
context_needed reports return the tool response, issue turn/interrupt, and stop
the worker so no later model output can mutate the workspace. A callback error
also returns the tool error, interrupts the turn, and stops the worker.

Managed runner callbacks are synchronous. on_session receives thread id, actual
model, selected turn effort, initial thread reasoning effort when available,
workspace, process metadata, and attempt identity. before_turn runs before each
turn and receives the same identity plus turn number and remaining allowance.
Managed codex update and runtime envelopes include the full attempt identity;
generic callers keep the existing message shapes.

Managed worker exits preserve structured reasons for core classification:

- managed_agent_terminal with the accepted terminal report
- managed_agent_guard_stop for callback or exhausted allowance stops
- managed_agent_failed for execution failures

Generic callers continue to receive the historical RuntimeError wrapping.
