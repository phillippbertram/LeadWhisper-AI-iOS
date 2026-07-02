# SwiftUI

Use this skill for SwiftUI screens, components, previews, and UI reviews.

## Screen Structure

- Match the existing app shape: `TabView` at the root, feature screens inside
  `NavigationStack`, and data-heavy views built from `List` and `Section`.
- Use `ContentUnavailableView` for empty states.
- Prefer native SwiftUI controls and SF Symbols for CRM actions.
- Keep feature rows and helper views private unless they are reused across
  feature boundaries.

## State And Data

- Read SwiftData through `@Query` for list-style views.
- Use `@Environment(\.modelContext)` to create a feature-local `CRMRepository`
  when an action needs to mutate data.
- Use `@State` for sheets, pending confirmation targets, and presentable errors.
- Model sheets with a private `Identifiable` enum when a screen can show more
  than one sheet.
- Keep derived sorting in computed properties when SwiftData cannot express the
  desired ordering in a descriptor.

## Actions And Errors

- Wrap repository actions so thrown errors are shown with `.crmErrorAlert`.
- Use confirmation dialogs for destructive actions such as deletes and resets.
- Keep swipe actions explicit and named with `Label`.

## Accessibility And Motion

- Add accessibility labels when an icon/button label is not enough.
- Respect `accessibilityReduceMotion`; animated affordances such as BeamBorder
  should have a reduced-motion path.
- Avoid text truncation for important CRM data. Use line limits only when the
  row still preserves the useful summary.

## Previews

- Use in-memory SwiftData containers in previews:

```swift
.modelContainer(for: [Contact.self, Opportunity.self, Interaction.self, FollowUpTask.self, ActivityEvent.self], inMemory: true)
```

- Keep previews cheap. Do not allocate voice/audio or model resources just to
  render a static screen.
