# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

Workspace lifecycle hooks can read bounded JSON issue identity in `SYMPHONY_ISSUE_CONTEXT`; removal hooks receive explicit null identity values when no issue is available.

The Elixir reference implementation also supports GitHub Projects as an additive tracker, using project item identity, configured status fields, and native cross-repository issue dependencies. See [the tracker configuration](elixir/README.md) for setup.

The optional managed control plane supports PM-owned assignments across multiple registered
GitHub Projects and repositories. Each assignment has one responsible PM; explicit, revision-fenced
handoffs transfer that responsibility while preserving a healthy worker. The operational journal
remains authoritative for ownership, and optional Project card summaries expose that state to users.
See [managed controls](elixir/README.md#managed-control-plane).

PMs can select existing reports as scoped findings for a worker's next turn. Compact and detail
reads expose the validated peer references, and the ownership dashboard keeps that review focused,
while corrected usage and runtime retain their source and history limits. Historical raw token
values are labelled unavailable or unreliable diagnostics and are never counted as spend. Accepted
assignments remain distinct from parent delivery.

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

The release build recipe and its pinned Linux runtime requirements are documented in the
[Elixir implementation guide](elixir/README.md#burrito-releases).

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
