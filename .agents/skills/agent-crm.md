# Agent CRM

Use this skill for Foundation Models, CRM drafting, lookup tools, parser
fallbacks, and mutation application.

## Contract

- `LeadAgentService` drafts CRM changes; it must not save data or claim that data
  was saved.
- `AgentDraft` is the structured response contract. Keep summaries concise,
  detected facts explainable, and proposed changes reviewable.
- `ProposedChange.action` strings are part of the internal protocol:
  `createContact`, `updateContact`, `createOpportunity`,
  `updateOpportunityStage`, `createInteraction`, `createFollowUp`,
  `updateFollowUp`, and `archiveFollowUps`.
- If adding or changing an action, update the schema, service instructions,
  result UI, demo parser, `ChangeExecutor`, and tests in the same change.

## Lookup Tools

- Agent tools are read-only. They search local snapshots and return compact text
  for Foundation Models.
- Keep lookup output short and deterministic. The current result limit is small
  to protect model context.
- `AgentLookupMode` intentionally attaches only the tools needed for a
  transcript. Preserve this compact-routing idea when adding lookup behavior.
- Empty queries should be rejected with a helpful tool response.

## Fallbacks

- Foundation Models may be unavailable or may exceed context. The app must fall
  back to `DemoAgentParser` so demos, simulator use, and tests remain useful.
- Keep `DemoAgentParser` deterministic. It should model important CRM flows and
  ambiguity handling without needing live model availability.
- Voice is not required for the core agent path; typed transcripts must keep
  working.

## Applying Changes

- `ChangeExecutor` is the single place that turns an approved `AgentDraft` into
  SwiftData mutations.
- It must reject drafts with clarification prompts and empty drafts.
- It should resolve existing records before creating new ones, append notes
  without duplicating them, merge tags through existing helpers, add activity
  entries, create an interaction, and save once at the end.
- Unknown proposed actions should be logged and ignored, not crash the app.

## Tests

- Cover lookup routing in `LeadAgentService`.
- Cover tool search output and limits when tool behavior changes.
- Cover `DemoAgentParser` fallback scenarios that a user can try in the
  simulator.
- Cover `ChangeExecutor` for every new action or changed matching rule.
