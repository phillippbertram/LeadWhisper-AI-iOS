# Code Style

Use this skill for Swift implementation, review, or refactor work.

## Swift Shape

- Match the existing Swift 6 style: 4-space indentation, explicit imports,
  focused types, and private helpers near their call sites.
- Prefer concrete, local code over broad abstractions. Add an abstraction only
  when it clearly removes repeated behavior or matches an existing pattern.
- Keep files organized by current ownership boundaries: `Core` for domain/data,
  `Features` for screens and feature services, `Shared/UI` for reusable UI.
- Use `final class` for SwiftData models and reference-style services where the
  repo already does.
- Keep comments sparse and useful. Explain non-obvious concurrency, persistence,
  or framework behavior; do not narrate simple assignments.

## SwiftData And State

- SwiftData work should stay on `@MainActor` unless an existing API clearly
  establishes a safe nonisolated path.
- Use `CRMRepository` for data access and mutations instead of scattering fetch,
  save, and activity logging logic through views.
- Preserve model timestamps when changing persisted data: update `updatedAt`
  when a model is materially edited.
- Keep relationships and delete rules explicit. If a model relationship changes,
  update repository behavior and seed data together. Update tests only when the
  user explicitly asks for test work.
- Predicate limitations are real in this codebase. Follow existing raw-value
  patterns such as enum raw strings for `#Predicate` filters.

## Concurrency And Frameworks

- Keep UI state mutations on the main actor.
- For blocking system work, follow the existing pattern of small `@concurrent`
  helpers rather than freezing view construction or button actions.
- Avoid introducing global mutable state. Prefer injected services,
  environment-provided SwiftData context, or local view state.

## Logging And Privacy

- Use `AppLog` categories instead of creating ad hoc loggers.
- Log counts, states, action names, IDs, and framework errors when useful.
- Treat transcripts, notes, contact names, companies, and client details as
  private. Use OSLog privacy annotations intentionally.
- User-facing errors should be actionable and calm; diagnostic detail belongs in
  logs.

## Existing Helpers

- Use `searchKey` for case/diacritic-insensitive matching.
- Use `nilIfBlank` before treating optional user-entered strings as meaningful.
- Use tag helpers such as `mergingTags` to preserve normalization behavior.
- Reuse `PresentableError` and `.crmErrorAlert` for CRM actions in views.
