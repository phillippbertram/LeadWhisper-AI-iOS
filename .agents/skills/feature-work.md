# Feature Work

Use this skill when changing product behavior across models, services, views, or
tests.

## Product Invariants

- LeadWhisper is local-first. CRM lookup and mutation should stay on the local
  SwiftData store unless the user explicitly asks for a different architecture.
- Preserve review-before-save. The agent may propose CRM changes, but the user
  approves before `ChangeExecutor` applies anything.
- Keep simulator usability. Voice recording is unavailable in the simulator, but
  typed transcripts and deterministic demo parsing should keep the core workflow
  testable.
- Avoid hidden destructive behavior. Deletes, resets, archives, and stage changes
  need clear UI affordances, confirmation where appropriate, activity entries,
  and tests.

## Implementation Path

- Start with the domain: models, enum cases, relationships, snapshots, and
  repository methods.
- Add or adjust service behavior next, keeping mutation rules centralized in the
  repository or `ChangeExecutor`.
- Update UI last, following the existing feature folder and edit-draft patterns.
- Extend demo seed data or the demo parser when a new feature needs a reliable
  simulator/demo path.
- Add tests for the behavior boundary, not just the helper function. Prefer
  in-memory SwiftData containers from `LeadWhisperTests/TestSupport`.

## Data Changes

- If a SwiftData schema changes, update all schemas that list model types:
  app container, previews, and test containers.
- The current app can recreate demo-oriented local storage after incompatible
  schema changes. Do not use that as a substitute for thinking through user data
  impact if the product scope changes.
- Keep snapshots compact. Agent-facing snapshots should include only fields
  needed for lookup and drafting.

## UI And Error Flow

- Keep CRM actions wrapped in a small `perform` helper or equivalent so errors
  become `PresentableError`.
- Add activity entries for meaningful CRM changes.
- Prefer small feature-local views for rows and sections before extracting shared
  UI.

## Tests

- Repository/model changes need SwiftData tests.
- Agent draft changes need parser, lookup, and executor coverage as relevant.
- Date parsing, matching, and ambiguity handling deserve focused tests because
  small regressions can produce incorrect CRM changes.
