# TigreChat — Agent Instructions

## Skill Loading Protocol (MANDATORY)

Per user request (2026-08-16): review and load relevant skills BEFORE any technical work. Never skip, never wait to be asked.

This is a **SwiftUI iOS app** (iOS 26.5 target, Xcode 27 beta). Before working on it, load the matching skills from `<available_skills>`:

- **UI / SwiftUI**: `swiftui-patterns`, `swiftui-expert-skill`, `mobile-ios-design`, `ios-swiftui-development`, `swiftui-navigation`, `swiftui-animation`, `swiftui-performance`
- **Architecture**: `ios-app-architecture`, `swift-architecture`, `swiftui-patterns`
- **Data**: `swiftdata` (SwiftData + ModelContext), `swift-codable`, `swift-concurrency` (MainActor / actors — the codebase is MainActor-confined)
- **Networking**: `ios-networking` (XMPP via URLSession/streams lives in `TigreChat/Data/XMPP/`)
- **Localization**: `ios-localization` (Localizable.xcstrings — Spanish is the source language)
- **Testing**: `swift-testing`, `ios-testing` (tests live in `TigreChatTests/`)
- **Debugging**: `debugging-instruments` (Xcode-beta, simulator + physical iPhone 12 Pro Max)
- **Git/PRs**: `branch-pr`, `work-unit-commits`, `chained-pr` (if PRs or commits are involved)

Re-check skills when the task area shifts. If the target is not SwiftUI/iOS (e.g., the Android repo `TigreChatAndroid`), load the corresponding platform skills instead.