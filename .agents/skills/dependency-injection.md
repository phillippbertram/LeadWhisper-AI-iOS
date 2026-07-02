# Dependency Injection

Use this skill when adding, refactoring, or reviewing dependency injection with
Factory in LeadWhisper.

## Container Shape

- Keep Factory registrations in `LeadWhisper/Core/Dependencies/AppDependencies.swift`.
- Put construction details that are not simple wiring in focused factory helpers,
  such as `LeadWhisperModelContainerFactory`.
- Define dependencies from the bottom up: `ModelContainer`, then
  `CRMRepository`, then data sources, services, and executors.
- Let higher-level factories call lower-level factories instead of rebuilding
  their inputs.
- Mark factories `@MainActor` when they create SwiftData-backed repositories,
  UI-facing services, or other main-actor-bound objects.
- Use `.singleton` only for app-wide shared state such as `ModelContainer` and
  `CRMRepository`. Prefer transient factories for services and executors unless
  the state must intentionally be shared.

## Injection Boundaries

- Prefer explicit initializer injection inside services, tools, executors, and
  reusable views. This keeps behavior easy to verify without global lookups.
- Resolve `Container.shared` at composition boundaries: app startup, feature view
  state creation, or short UI actions that need a configured service.
- Do not pass `Container` into domain types or service methods. Pass the concrete
  dependency they need.
- Keep SwiftData access centralized through `CRMRepository`; Factory should wire
  the repository, not become an alternate data-access path.
- Preserve LeadWhisper's review-before-save invariant when wiring agent services:
  draft services propose changes, and `ChangeExecutor` applies approved drafts.

## Adding A Dependency

1. Give the consumer an explicit initializer parameter.
2. Register the dependency in `AppDependencies.swift` with the narrowest useful
   type.
3. Reuse existing factories for shared inputs instead of constructing parallel
   instances.
4. Resolve the factory at the nearest composition boundary.
5. Do not add or update tests unless the user explicitly asks for test work.

## Optional Verification

- Existing Factory tests may be run as confidence checks when available, but new
  tests are not required.
- If the user asks for test work, use `FactoryTesting` and `@Suite(.container)`
  for overrides of `Container.shared` registrations.
- For requested tests, override `modelContainer` with
  `makeTestModelContainer()` and build one `CRMRepository` from that context.
- Register related dependencies against the same repository so the graph is
  coherent.

## Review Checklist

- A new service can be constructed directly without touching Factory.
- `Container.shared` lookups are limited to composition boundaries.
- SwiftData-backed dependencies are `@MainActor` and share the intended
  `ModelContainer`.
- Singleton usage is deliberate and does not hide stale UI or stale state.
- No private CRM content is introduced into logs while wiring dependencies.
