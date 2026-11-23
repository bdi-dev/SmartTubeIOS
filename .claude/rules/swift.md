---
paths: ["**/*.swift"]
---

<!-- synced with AGENTS.md rev 1 -->

- Swift 6 strict concurrency everywhere. View models are `@MainActor @Observable`. No `ObservableObject`, `@Published`, Combine, `DispatchQueue`, completion handlers in new code.
- `SmartTubeIOSCore` must stay Foundation-only (no SwiftUI/UIKit/AVFoundation/WebKit). Put platform code in `SmartTubeIOS`.
- One definition per constant/identifier/threshold. SF Symbols come from `AppSymbol` (`Views/ViewHelpers.swift`). There is no `AccessibilityID` type and no `PlaybackTuning` type yet (both are planned; a SwiftLint custom rule already warns on raw `accessibilityIdentifier("…")`). Until they exist, use dotted string identifiers (`downloads.videoRow.<id>`), reuse an existing identifier rather than adding a near-duplicate, and keep a new timeout as one named constant.
- Wrap UIKit-only API in `#if os(iOS)`; provide AppKit/tvOS branches. Never nest `NavigationStack`s.
- Never hand-edit `project.pbxproj` (a hook blocks it).
- Tests: Swift Testing for unit tests; no `Task.sleep`, no live network, fakes at protocol seams. UI tests use the same identifiers and `waitForExistence`, never `sleep`.
- Logging via `os.Logger` (subsystem `appSubsystem`), never `print`.
