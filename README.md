# Polyphony

Polyphony turns project work into isolated, autonomous implementation runs, so teams can manage work
instead of supervising coding agents.

[![Polyphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_The demo shows the orchestration model end to end: watch tracker work, spawn delegated agent runs,
validate outcomes, and hand off via PR workflow with minimal human babysitting._

> [!WARNING]
> Polyphony is an engineering preview for trusted environments.

## Running Polyphony

### Requirements

Polyphony works best in codebases that already follow
[harness engineering](https://openai.com/index/harness-engineering/).

### Option 1. Build your own

Tell your coding agent to implement Polyphony in your language of choice using the repository spec:

> Implement Polyphony according to:
> ./SPEC.md

### Option 2. Use the Elixir reference implementation

See [elixir/README.md](elixir/README.md) for setup and runtime instructions for the current Elixir
reference service.

---

## Why GitHub-first

Linear free-tier issue limits can constrain agentic development at scale. A GitHub-native tracker
model keeps planning, execution history, issue context, and PR evidence in the repository system
teams already use.

Polyphony implements the Symphony orchestration spec while mapping it onto GitHub primitives such as:

- Issues and issue forms
- Projects fields/views
- Labels, milestones, and relationships
- PR links, reviews, checks, and merge state

Per-issue runtime artifacts are stored in `docs/issues/<issue-id>/` (plan, run log, decisions, evidence, handoff).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
