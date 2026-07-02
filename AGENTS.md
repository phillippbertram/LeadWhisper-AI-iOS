# LeadWhisper Agent Guide

This is the canonical operating guide for AI agents working in this repository.
Read it before making changes, then load the relevant skill files from
[.agents/skills](.agents/skills/README.md).

## Project Facts

- LeadWhisper is a private-first iPhone CRM companion for capturing lead updates
  from voice or text and turning them into reviewed local CRM changes.
- The app uses Swift 6, SwiftUI, SwiftData, Foundation Models, Speech,
  AVFoundation, OSLog, Swift Testing, and BeamBorder.
- The Xcode project is `LeadWhisper.xcodeproj`; the app scheme is `LeadWhisper`.
- Product context, requirements, and the command-line test command live in
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
   repository, view, and test patterns.
5. Keep changes tightly scoped. Do not reformat unrelated files or clean up code
   that is outside the requested work.

## Repository Map

- `LeadWhisper/App/`: app entry point and root tab navigation.
- `LeadWhisper/Core/`: CRM models, repository, logging, seed data, and helpers.
- `LeadWhisper/Features/`: Agent, Contacts, Opportunities, Today, Settings, and
  Editing feature surfaces.
- `LeadWhisper/Shared/UI/`: reusable UI helpers and view modifiers.
- `LeadWhisperTests/`: unit tests for CRM, agent, editing, voice, and utilities.

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
- User-facing CRM and voice workflows must fail with clear, friendly UI errors
  and should log useful diagnostics through `AppLog`.
- Treat contact names, transcripts, notes, and client context as private in logs.

## Skills

Use the repo-local skills as focused playbooks:

- [Code Style](.agents/skills/code-style.md): Swift style, logging, SwiftData,
  concurrency, and comments.
- [Feature Work](.agents/skills/feature-work.md): how to add or change product
  behavior end to end.
- [SwiftUI](.agents/skills/swiftui.md): view composition, state, sheets,
  queries, errors, previews, and accessibility.
- [Dependency Injection](.agents/skills/dependency-injection.md): FactoryKit
  container wiring, overrides, dependency boundaries, and testable services.
- [Agent CRM](.agents/skills/agent-crm.md): Foundation Models, CRM draft schema,
  lookup tools, fallback parser, and safe application.
- [Commits](.agents/skills/commits.md): staging, commit messages, and handoff
  discipline.

## Build And Test

Run tests from Xcode with `Cmd+U`, or use an available iPhone simulator:

```sh
xcodebuild test -project LeadWhisper.xcodeproj -scheme LeadWhisper -destination 'platform=iOS Simulator,name=iPhone 17'
```

If the simulator or Xcode cache environment is unavailable, say so in the
handoff and include any error that affects confidence.

## Handoff Checklist

- Summarize what changed and why.
- Mention tests or checks run, including failures caused by the environment.
- Call out any intentionally untouched user-owned changes.
- For behavior changes, name the user-visible scenario that now works.
