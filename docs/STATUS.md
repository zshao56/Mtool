# Implementation status

This file records exactly what has been verified and what has not. It is meant
to be updated as work lands.

## Verified

- **Pure logic unit tests pass** (32 tests): three-scene routing
  (`ContextRoutingTests`, including the stale-PID check), the double-tap Command
  detector (`ModifierDoubleTapTests`), clipboard policy (`ClipboardPolicyTests`)
  and the clipboard SQLite store (`ClipboardStoreTests` — round trip,
  de-duplication, pinning, retention, capacity, search, snippets and snippet
  reordering). These were compiled and run with a Swift 5.10 toolchain; the
  store tests ran against the system SQLite.
- **Every Swift file parses** (`swiftc -parse` over all sources).
- **`project.yml` and the GitHub Actions workflow are valid YAML**, and
  `ConfigSchema.json` is valid JSON.

## NOT verified

- **The macOS app has not been compiled.** There is no macOS/Xcode toolchain in
  the environment where this was written, and the GitHub repository cannot be
  pushed to from here (no credentials), so CI has not run. The AppKit/SwiftUI
  code is only syntax-checked.
- **No DMG has been produced.** It is built by CI on a macOS runner.
- **No real-desktop acceptance has been done.** The checklist in
  `docs/ACCEPTANCE.md` is unrun.

## Deliberately conservative behaviour

- `FocusedInputInspector.browserFallbackEnabled` is **false**: automatic pasting
  into browser/Electron text fields is off until a real-desktop pass records
  success in `docs/ACCEPTANCE.md`.
- Unknown or unreadable focus never enters scenario 2; it falls through to the
  search box.
- Secure/password focus is never read; secure keyboard entry pauses both the
  clipboard watcher and the double-tap trigger.

## Known gaps / not implemented

- The clipboard panel's history is not virtualized beyond `LazyVStack`; very
  large histories are capped by the policy anyway.
- No App Store / sandboxed build (the features require AX, global event taps and
  screen capture, which the sandbox forbids).

## Recently completed after the first status pass

- Saved snippets (常用词) can now be created, edited (title + content), reordered
  with up/down controls and deleted from the panel; all of it is persisted and
  the panel is usable from the keyboard. The async selection read now compares
  the frontmost process id on return and discards a result whose app is no longer
  frontmost.
