# LeadWhisper Agent Guide

This is the canonical operating guide for AI agents working in this repository.
Read it before making changes, then load the relevant skill files from
[.agents/skills](.agents/skills/README.md).

## Project Facts

- LeadWhisper is a Swift-native iPhone CRM agent showcase for capturing lead
  updates from voice or text and turning them into reviewed local CRM changes.
- The original Apple On-device provider uses Foundation Models, but current
  context-window limits make that path too constrained for the practical
  showcase. Treat it as the limited on-device experiment, not as the primary
  usability target.
- The practical showcase provider is OpenAI via the Responses API. When OpenAI
  is selected, submitted agent messages and local CRM lookup results are sent
  directly to OpenAI. There is no backend proxy in this version.
- The app uses Swift 6, SwiftUI, SwiftData, Foundation Models, OpenAI Responses
  API, FactoryKit, Security / Keychain, Speech, AVFoundation, OSLog, and
  BeamBorder.
- The Xcode project is `LeadWhisper.xcodeproj`; the app scheme is `LeadWhisper`.
- Product context, provider trade-offs, and requirements live in
  [README.md](README.md).
- Current app data is local/demo-oriented. Preserve the review-before-save flow:
  AI drafts proposed CRM changes, the user reviews them, and only then are
  changes applied locally.

## First Steps For Agents

1. Run `git status --short` and treat any pre-existing changes as user-owned.
2. Read [README.md](README.md) for product context.
3. Read the skill index at [.agents/skills/README.md](.agents/skills/README.md)
   and load only the skills relevant to the task.
4. Inspect nearby code before editing. Follow the existing feature, model,
   repository, and view patterns.
5. Keep changes tightly scoped. Do not reformat unrelated files or clean up code
   that is outside the requested work.

## Repository Map

- `LeadWhisper/App/`: app entry point and root tab navigation.
- `LeadWhisper/Core/`: CRM models, repository, logging, seed data, and helpers.
- `LeadWhisper/Core/Dependencies/`: FactoryKit container wiring and dependency
  boundaries.
- `LeadWhisper/Features/`: Agent, Contacts, Opportunities, Today, Settings, and
  Editing feature surfaces.
- `LeadWhisper/Shared/UI/`: reusable UI helpers and view modifiers.
- `Screenshots/`: README screenshots and demo media.
- `.github/FUNDING.yml`: GitHub sponsor button funding metadata.

## Working Rules

- Never revert, overwrite, stage, or commit user changes unless the user
  explicitly asks for that exact action.
- Do not edit `LeadWhisper.xcodeproj` unless a source/build setting change
  genuinely requires it.
- Keep generated files, caches, local simulator output, and new user-specific
  Xcode state out of commits.
- When creating commits, always use an English Conventional Commit title and an
  English description/body. Do not create title-only commits.
- Prefer existing helper APIs such as `CRMRepository`, `AppLog`, `searchKey`,
  `nilIfBlank`, and tag-merging helpers over ad hoc replacements.
- Preserve the review-before-save invariant. The model may propose CRM changes,
  but SwiftData mutations must happen only after explicit user review and
  confirmation.
- Keep provider-specific logic behind the existing agent engine/client
  boundaries. Do not blur Foundation Models and OpenAI behavior into unrelated
  views, repositories, or model types.
- User-facing CRM, voice, agent, and provider workflows must fail with clear,
  friendly UI errors and should log useful diagnostics through `AppLog`.
- If a selected provider is unavailable, an OpenAI key is missing, or a model
  request fails, the app should explain the issue and draft nothing.
- Treat contact names, transcripts, notes, client context, OpenAI API keys, and
  tool observations as private. Do not log them in plaintext.
- Keep OpenAI credentials Keychain-only. Never place API keys in source code,
  README content, logs, screenshots, fixtures, or test data.
- Agents are not required to write, update, or maintain tests in this project.
  Only create or edit tests when the user explicitly asks for tests.

## Skills

Use the repo-local skills as focused playbooks:

- [Code Style](.agents/skills/code-style.md): Swift style, logging, SwiftData,
  concurrency, and comments.
- [Feature Work](.agents/skills/feature-work.md): how to add or change product
  behavior end to end.
- [SwiftUI](.agents/skills/swiftui.md): view composition, state, sheets,
  queries, errors, previews, and accessibility.
- [Dependency Injection](.agents/skills/dependency-injection.md): FactoryKit
  container wiring, overrides, dependency boundaries, and injectable services.
- [Agent CRM](.agents/skills/agent-crm.md): provider behavior, Foundation
  Models, OpenAI, CRM draft schema, lookup tools, tool planning, context
  pressure, and safe application.
- [Commits](.agents/skills/commits.md): staging, commit messages, and handoff
  discipline.

## Build And Checks

Tests are optional confidence checks, not required deliverables for agent work.
Do not add or update tests unless the user explicitly asks.

There is currently no dedicated test target in the repository. If useful, run a
build from Xcode, or use an available iPhone simulator for a command-line build:

```sh
xcodebuild build -project LeadWhisper.xcodeproj -scheme LeadWhisper -destination 'platform=iOS Simulator,name=iPhone 17'
```

If a test target is reintroduced later, use the project README or Xcode scheme
settings as the source of truth for the exact test command. If checks are
skipped, say so briefly in the handoff. If the simulator or Xcode cache
environment is unavailable, say so and include any error that affects
confidence.

## Handoff Checklist

- Summarize what changed and why.
- Mention checks run, including any optional tests, or say they were not run.
- Call out any intentionally untouched user-owned changes.
- For behavior changes, name the user-visible scenario that now works.
