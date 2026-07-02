# Agent CRM

Use this skill for Foundation Models, CRM drafting, lookup tools, parser
fallbacks, and mutation application.

## Contract

- `AgentConversationEngine` runs the chat loop on one persistent
  `LanguageModelSession` per conversation. It drafts CRM changes; it must not
  save data or claim that data was saved.
- Each turn follows ReAct: the model records a `thought`, acts through the
  read-only lookup tools, observes the results, and finishes with one
  `AgentTurn`. The thought and the action/observation trace render in the
  result card details.
- `AgentTurn` is the structured response contract. The model picks the turn
  kind itself: `reply` (conversational answer), `clarify` (one focused
  question with options), or `propose` (reviewable changes). Normalize the
  kind from content via `resolvedKind` before rendering.
- `AgentDraft` is the review payload built from a propose turn. Keep summaries
  concise, detected facts explainable, and proposed changes reviewable.
- After the user saves or cancels a draft, tell the engine via
  `noteDraftSaved()` / `noteDraftCancelled()` so the model stays grounded.
- On `exceededContextWindowSize` the engine drops the session and retries the
  turn once in a condensed conversation. Preserve this recovery path.
- `ProposedChange.action` strings are part of the internal protocol:
  `createContact`, `updateContact`, `createOpportunity`,
  `updateOpportunityStage`, `createInteraction`, `createFollowUp`,
  `updateFollowUp`, and `archiveFollowUps`.
- If adding or changing an action, update the schema, engine instructions,
  result UI, and `ChangeExecutor` in the same change. Update tests only when
  the user explicitly asks for test work.

## Lookup Tools

- Agent tools are read-only. They search local snapshots and return compact text
  for Foundation Models.
- Keep lookup output short and deterministic. The current result limit is small
  to protect model context.
- All lookup tools are attached to the conversation session; the model decides
  when to call them. Keep tool output compact so this stays affordable for the
  on-device context window.
- Empty queries should be rejected with a helpful tool response.

## Availability And Loop Guards

- The agent works only with real local CRM data. There is no demo parser and
  no fabricated fallback data; when Foundation Models is unavailable the UI
  shows a clear error and drafts nothing.
- Loop guards live in `AgentConversationEngine` and must be preserved: a
  per-turn lookup budget (tools return `ToolText.lookupBudgetExhausted` past
  the limit), a cap on consecutive clarification turns (forced final reply
  past the cap), and a single condensed retry on context-window overflow.
- Voice is not required for the core agent path; typed transcripts must keep
  working.

## Applying Changes

- `ChangeExecutor` is the single place that turns an approved `AgentDraft` into
  SwiftData mutations.
- The review card lets the user deselect individual proposed changes; the
  composer filters the draft before calling `ChangeExecutor`, so apply only
  ever sees selected changes. Destructive confirmation is checked against the
  filtered draft.
- `ChangeDiffBuilder` resolves targeted records read-only and renders
  old -> new field diffs on update cards. Keep its resolution behavior aligned
  with `ChangeExecutor` lookups.
- It must reject drafts with clarification prompts and empty drafts.
- It should resolve existing records before creating new ones, append notes
  without duplicating them, merge tags through existing helpers, add activity
  entries, create an interaction, and save once at the end.
- Unknown proposed actions should be logged and ignored, not crash the app.

## Optional Verification

- Do not add or update tests unless the user explicitly asks.
- Existing tests may be run as confidence checks when available.
- For risky agent changes, mention suggested follow-up coverage for tool
  output limits, loop guards, or `ChangeExecutor` in the handoff instead of
  writing tests.
