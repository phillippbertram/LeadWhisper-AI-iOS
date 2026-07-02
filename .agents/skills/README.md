# LeadWhisper Agent Skills

These are lightweight, repo-local playbooks for agents. They are intentionally
tool-agnostic so Codex, Claude, and other agents can share the same project
knowledge.

Load only the files that fit the current task:

- [Code Style](code-style.md): use for any Swift source change or review.
- [Feature Work](feature-work.md): use for product behavior, data model,
  repository, service, or test changes.
- [SwiftUI](swiftui.md): use for UI, navigation, sheets, state, previews, and
  accessibility changes.
- [Dependency Injection](dependency-injection.md): use for FactoryKit container
  wiring, overrides, dependency boundaries, and testable services.
- [Agent CRM](agent-crm.md): use for Foundation Models, agent tools, parser,
  draft schema, or CRM mutation flow changes.
- [Commits](commits.md): use before staging, committing, or preparing a handoff.

The root guide at [../../AGENTS.md](../../AGENTS.md) remains the source of truth
for repository-wide rules.
