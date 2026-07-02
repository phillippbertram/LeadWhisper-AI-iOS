# LeadWhisper

LeadWhisper is a Swift-native agent showcase for iPhone CRM workflows. It started as a private-first, on-device CRM companion, but the current Foundation Models limits make that path too constrained for a genuinely usable agent. The practical showcase path now uses OpenAI for model reasoning while keeping CRM storage, local tools, and review-before-save behavior in the Swift app.

The app is built around a simple idea: after a call, meeting, or quick thought, you can speak or type what happened. LeadWhisper extracts contacts, opportunities, follow-ups, notes, stages, and activity history, then proposes safe CRM changes you can approve or discard.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="Screenshots/app-2026-07-02/leadwhisper-agent.jpg" alt="LeadWhisper Agent screen" width="180"><br><sub>Agent</sub></td>
    <td align="center"><img src="Screenshots/app-2026-07-02/leadwhisper-today.jpg" alt="LeadWhisper Today screen" width="180"><br><sub>Today</sub></td>
    <td align="center"><img src="Screenshots/app-2026-07-02/leadwhisper-contacts.jpg" alt="LeadWhisper Contacts screen" width="180"><br><sub>Contacts</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="Screenshots/app-2026-07-02/leadwhisper-opportunities.jpg" alt="LeadWhisper Opportunities screen" width="180"><br><sub>Opportunities</sub></td>
    <td align="center"><img src="Screenshots/app-2026-07-02/leadwhisper-settings.jpg" alt="LeadWhisper Settings screen" width="180"><br><sub>Settings</sub></td>
    <td></td>
  </tr>
</table>

## Project Intent

LeadWhisper is an experiment in implementing an agent natively in Swift rather than wrapping a Python or JavaScript agent runtime. The original idea was to build a private-first agent on top of Apple's on-device [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework. In practice, the small context window and the overhead from instructions, tool schemas, structured output, observations, and prior turns leave too little room for a useful CRM agent.

OpenAI was added as the practical path for the showcase. That gives the agent enough context and model capability to demonstrate the architecture, but it also means the strict privacy story is no longer true when OpenAI is selected: prompts and local CRM lookup results leave the device and are sent to OpenAI.

Instead of treating the model as a plain text generator, the app uses it as the decision point in an agent loop: it receives compact instructions, plans which read-only local CRM tools should be available, can call those tools, returns a structured result, and never writes data directly. The product experience around that loop is just as important as the model call itself: every proposed CRM mutation is shown as a reviewable draft before SwiftData is changed.

The project intentionally stays narrow. A small CRM domain makes it possible to study the hard parts of Swift-native agents - grounding, tool output size, ambiguity, structured drafts, context pressure, provider boundaries, recovery, and human approval - without hiding those problems behind a full agent framework.

## What It Does

- Capture CRM updates by voice or text.
- Review AI-generated drafts before any local data changes are applied.
- Manage contacts, companies, notes, and tags.
- Track opportunities by stage, expected start, budget, and related contact.
- Keep follow-up tasks visible in a Today view.
- Save an activity trail for important changes.
- Switch manually between Apple On-device and OpenAI as the agent provider.
- Store a user-provided OpenAI API key in Keychain for cloud-backed drafting.
- Watch selected-provider context-window usage while composing.
- Load demo data to try ambiguity handling and common CRM flows quickly.

## AI And Privacy

LeadWhisper has two providers. Apple On-device uses Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework through `FoundationModels` when available on the device, but it is best understood as the limited original experiment. OpenAI uses the Responses API when the user selects OpenAI in Settings and saves an API key; this is the practical provider for demonstrating a more usable agent loop. The key is stored in Keychain on the device and is never logged.

CRM data remains stored locally in SwiftData, and the agent can use read-only tools to find matching contacts, opportunities, and follow-ups before proposing changes. With Apple On-device, prompts and tool observations stay on the device, but the agent is heavily constrained. With OpenAI, submitted agent messages and local CRM lookup results are sent directly to OpenAI so the cloud model can draft reviewable changes. There is no backend proxy in this version, so selecting OpenAI explicitly trades away the original private-first model.

The remaining safety boundary is product-level, not privacy-level: the agent works with real local CRM data, proposes drafts, and never applies changes without review. If the selected provider is unavailable, or OpenAI is selected without a saved key, the agent says so clearly and drafts nothing. Voice input uses Apple's Speech and AVFoundation APIs; on unsupported environments, you can type the transcript instead.

## Agent Architecture

The Agent tab is a Swift-native provider-backed agent: the model - not a scripted workflow - decides each turn whether to answer, ask one follow-up question, call a local lookup tool, or propose reviewable CRM changes. The showcase is the native Swift harness around the model: planning, tool execution, compact memory, trace display, validation, and human approval.

```mermaid
flowchart TD
    S[Settings<br/>provider + OpenAI key] --> E[AgentConversationEngine]
    U[User message] --> E
    E --> M[AgentContextMemory<br/>compact rolling continuity]
    E --> P[AgentToolPlan<br/>LLM tool planning]
    P --> R{ReAct loop}
    R -->|Action| T[Read-only tools<br/>findContacts / findOpportunities / findFollowUps<br/>getContactDetails / getPipelineSummary]
    T -->|Observation| R
    R -->|Thought recorded| A[AgentTurn]
    A -->|reply| C[Chat bubble]
    A -->|clarify| Q[One question with options]
    A -->|propose| V[Review card<br/>old-to-new diffs / per-change selection]
    Q --> U
    V -->|Cancel| U
    V -->|Save, destructive changes reconfirmed| X[ChangeExecutor]
    X --> D[(SwiftData)]
```

- **Provider abstraction.** `AgentConversationEngine` owns memory, loop guards, draft validation, and review-before-save. Provider clients handle model calls for Apple Foundation Models or OpenAI Responses, so the Swift agent harness stays separate from the selected model API.
- **The Foundation Models limit.** A Foundation Models session has a fixed context window. Apple exposes the limit through [`SystemLanguageModel.contextSize`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize); LeadWhisper reads it dynamically so the app can adapt to OS, model, or hardware changes. In practice, the current on-device budget is small enough that a 4096-token-class window is quickly exhausted by system instructions, tool definitions, tool output, structured schemas, model responses, and short conversation history. That makes Foundation Models useful for learning the APIs, but too brittle for the richer CRM agent this project wants to demonstrate.
- **OpenAI as the practical path.** OpenAI has a much larger configured context budget and stronger cloud-model behavior, which makes the agent loop usable enough for the showcase. It is not a privacy-preserving substitute for the on-device model: tool definitions, tool output, schemas, model responses, compact memory, and user messages still form cloud-bound prompt context.
- **Context-window management.** The engine uses the iOS 26.4+ Foundation Models token-count APIs to measure Apple instructions, tools, prompts, transcript, and schema usage. OpenAI context usage is estimated locally so draft text is not sent to the network just to count tokens while the user is typing. The composer shows a compact progress meter with remaining tokens.
- **Compact memory instead of full history.** The provider session is refreshed after drafts, save/cancel outcomes, overflow recovery, rolling turns, and provider switches. `AgentContextMemory` carries only recent turns, open clarifications, relevant local IDs, and draft outcomes into the next turn.
- **LLM-based tool planning.** Before the main ReAct turn, the selected model returns an `AgentToolPlan` with the smallest safe tool scope: none, contacts, opportunities, follow-ups, pipeline, or full. There are no keyword-based intent lists or local guided workflows; when planning fails, the engine conservatively exposes the full read-only tool set.
- **Provider sessions.** Apple runs the main turn in a [`LanguageModelSession`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession) with planned tools attached. OpenAI sends compact memory and tool roundtrips through the Responses API, using Structured Outputs for `AgentToolPlan` and `AgentTurn`.
- **ReAct trace.** Every turn records a thought plus the action/observation sequence, following the [ReAct pattern](https://arxiv.org/abs/2210.03629) of interleaving reasoning with tool use. The trace is visible behind a "Details" disclosure on each card, or always with the "Show Agent Reasoning" toggle in Settings.
- **Loop guards.** A per-turn lookup budget and a cap on consecutive clarification rounds keep the loop convergent - the LangChain `max_iterations` and early-stopping ideas applied to both providers.
- **Review before save.** The model only proposes. `ChangeDiffBuilder` resolves the targeted records and shows old-to-new diffs, individual changes can be deselected, and destructive changes require an extra confirmation before `ChangeExecutor` mutates SwiftData.

## Lessons And Constraints

Building this in Swift is still much more hands-on than building a comparable server-side agent in Python or TypeScript.

- **Limited community patterns.** Foundation Models is young, and there are fewer examples, blog posts, production write-ups, and battle-tested recipes than for cloud LLM stacks. Many choices in LeadWhisper are therefore first-principles product and systems design rather than "copy the common agent template."
- **Foundation Models is not enough for this app today.** The on-device privacy story is compelling, but the hard context limit makes real agent behavior fragile after only a small number of instructions, tool calls, observations, and structured responses. Context compression helps, but it does not turn the current on-device model into a comfortable foundation for a broader CRM assistant.
- **No full agent framework in Swift.** Foundation Models provides the model session, guided generation, schemas, token counting, and tools, but it is not a full agent runtime like [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents) or the [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/). LeadWhisper implements its own harness for provider switching, tool planning, tool calls, loop guards, compact memory, overflow retry, trace display, draft validation, and human approval.
- **A lot is built from scratch.** The app owns the CRM schema, local lookup tools, tool-output compression, draft validation, diffing, destructive-change confirmation, save/cancel feedback, and context-window recovery. Those are the pieces that hosted agent frameworks often package as middleware or runtime behavior.
- **Cloud providers change the privacy model.** The V1 OpenAI path is bring-your-own-key and direct from the app to OpenAI. It makes the showcase usable, but it also means LeadWhisper is no longer private-first when that provider is selected. A production iOS app would usually introduce a backend proxy for API-key protection, auth, rate limiting, logging, orchestration, and privacy controls.
- **The showcase moved up a layer.** The most interesting part of the project is no longer "can Foundation Models run a full CRM agent on device?" The practical answer is "not comfortably yet." The interesting part is how much of an agent runtime can be built cleanly in Swift around local data, local tools, provider abstraction, and reviewable CRM mutations.

## Outlook

LeadWhisper now has the first provider boundary in place: Apple On-device remains available as the constrained original path, and OpenAI can be selected manually for practical cloud-backed drafting. The next architectural step would be to replace the BYO-key path with a production proxy that protects credentials, adds auth and quotas, and makes cloud usage auditable.

The OS 27 betas also point toward a more flexible Foundation Models ecosystem. Anthropic's [Claude for Foundation Models](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models) package makes Claude available as a server-side `LanguageModel` provider for Apple's Foundation Models framework, and Apple documents [`PrivateCloudComputeLanguageModel`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel) as another Foundation Models type to watch. Both directions could strengthen the Swift-native provider interface and let LeadWhisper keep the same review-before-save harness while adding more provider choices later, but they do not automatically solve privacy, credential, backend, or auditability questions.

## Reference Links

- [ReAct: Synergizing Reasoning and Acting in Language Models](https://arxiv.org/abs/2210.03629)
- [Apple Foundation Models framework](https://developer.apple.com/documentation/foundationmodels)
- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [`LanguageModelSession`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [`Tool`](https://developer.apple.com/documentation/foundationmodels/tool) and [tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
- [`@Generable`](https://developer.apple.com/documentation/foundationmodels/generable)
- [`SystemLanguageModel.contextSize`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize)
- [`PrivateCloudComputeLanguageModel`](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)
- [OpenAI Responses API](https://platform.openai.com/docs/api-reference/responses)
- [OpenAI Function Calling](https://platform.openai.com/docs/guides/function-calling)
- [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs)
- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/)
- [Claude for Apple Foundation Models](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models)

## Tech Stack

- Swift 6, SwiftUI, and SwiftData
- Foundation Models and OpenAI Responses API
- Security / Keychain
- Speech and AVFoundation

## Requirements

- Xcode 26.5 or newer
- iOS 26.5 SDK or newer
- iPhone target or iPhone simulator
- Apple Intelligence-capable device for the Apple On-device provider
- OpenAI API key for the optional OpenAI provider
- Microphone and speech recognition permissions for voice input

Voice recording is intentionally unavailable in the simulator. You can type transcripts there instead. Drafting with Apple On-device requires a device with Apple Intelligence; drafting with OpenAI requires selecting OpenAI in Settings and saving an API key.

## Getting Started

1. Clone the repository.
2. Open `LeadWhisper.xcodeproj` in Xcode.
3. Select the `LeadWhisper` scheme.
4. Choose an iPhone simulator or device.
5. Build and run.

To try the app immediately, open Settings and tap `Load Demo Data`, then use the Agent tab or the floating talk button from the main CRM views. Apple On-device is selected by default. To use OpenAI, open Settings, switch the Agent provider to `OpenAI`, and save an API key in the OpenAI section.

## Support

<a href="https://www.buymeacoffee.com/phillippbertram" target="_blank">
  <img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=phillippbertram&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy me a coffee" />
</a>

<!-- GitHub does not execute script tags in README files, so the image link above is the rendered fallback for this requested button:
<script type="text/javascript" src="https://cdnjs.buymeacoffee.com/1.0.0/button.prod.min.js" data-name="bmc-button" data-slug="phillippbertram" data-color="#FFDD00" data-emoji="" data-font="Cookie" data-text="Buy me a coffee" data-outline-color="#000000" data-font-color="#000000" data-coffee-color="#ffffff" ></script>
-->

## License

LeadWhisper is available under the MIT License. See [LICENSE](LICENSE) for details.
