---
paths: ["**/*.swift"]
---

<!-- synced with AGENTS.md rev 1 -->

- Swift 6 strict concurrency everywhere. View models are `@MainActor @Observable`. No `ObservableObject`, `@Published`, Combine, `DispatchQueue`, completion handlers in new code.
- `SmartTubeIOSCore` must stay Foundation-only (no SwiftUI/UIKit/AVFoundation/WebKit). Put platform code in `SmartTubeIOS`.
- One definition per constant/identifier/threshold. SF Symbols come from `AppSymbol` (`Views/ViewHelpers.swift`). Accessibility identifiers come from `AccessibilityID` (`Views/Common/AccessibilityID.swift`); add new ids there and keep every value byte-identical to the string UI tests match. There is no `PlaybackTuning` type yet (it is planned; a SwiftLint custom rule already warns on raw `accessibilityIdentifier("…")`). Until it exists, keep a new timeout as one named constant, and reuse an existing identifier rather than adding a near-duplicate.
- Wrap UIKit-only API in `#if os(iOS)`; provide AppKit/tvOS branches. Never nest `NavigationStack`s.
- Never hand-edit `project.pbxproj` (a hook blocks it).
- Tests: Swift Testing for unit tests; no `Task.sleep`, no live network, fakes at protocol seams. UI tests use the same identifiers and `waitForExistence`, never `sleep`.
- Logging via `os.Logger` (subsystem `appSubsystem`), never `print`.
