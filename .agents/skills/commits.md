# Commits

Use this skill before staging, committing, pushing, or preparing a handoff.

## Before Staging

- Run `git status --short` and identify which changes are yours.
- Inspect diffs before staging. Do not stage user-owned changes or unrelated
  cleanup.
- Keep new local caches, generated output, and user-specific Xcode files out of
  commits unless the user explicitly asked for them.

## Commit Style

Every commit created by an agent must have both:

- An English Conventional Commit title.
- An English description/body that explains the change.

Do not create title-only commits. Use concise Conventional Commit titles,
matching the existing history:

- `feat: add CRM follow-up editing`
- `fix: prevent voice recording main-thread stalls`
- `refactor: reorganize project structure`
- `docs: add agent repository guide`

Prefer a lower-case subject after the type. Keep it imperative and specific.

## Commit Body

Always include a short English body. It should cover:

- What changed.
- Why it changed.
- Tests or checks run.
- Any known limitation caused by local environment.

Example:

```text
docs: add agent repository guide

Document shared agent rules, repo-local skills, and commit expectations so
future agents can work consistently across Codex and Claude.
```

## Handoff Discipline

- Mention tests or checks in the final message, including docs-only decisions
  where no build was needed.
- Call out pre-existing modified files that were intentionally left untouched.
- If a build or test fails because of simulator, Xcode cache, signing, or
  sandbox restrictions, report the exact category instead of hiding it.
