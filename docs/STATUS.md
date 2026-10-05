# Implementation status

This file records exactly what has been verified and what has not. It is meant
to be updated as work lands.

## Verified

- **Pure logic unit tests pass** (39 tests): three-scene routing
  (`ContextRoutingTests`, including the stale-PID check), the double-tap Command
  detector (`ModifierDoubleTapTests`), UTF-16 text insertion
  (`TextInsertionTests`), clipboard policy (`ClipboardPolicyTests`) and the
  clipboard SQLite store (`ClipboardStoreTests` — round trip, de-duplication,
  pinning, retention, capacity, search, snippets and snippet reordering). These
  were compiled and run with a Swift 5.10 toolchain; the store tests ran against
  the system SQLite.
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
  the panel is usable from the keyboard. Clicking a snippet pastes it through the
  same validated path as a history entry, with a separate copy button.
- The async selection read compares the frontmost process id on return and
  discards a result whose app is no longer frontmost.
- Accessibility writes are now strictly position-correct: `AXSelectedText`
  first, otherwise a UTF-16-range splice into `AXValue` when the caret range is
  readable (`TextInsertion`). A blind `AXValue` append was removed.
- Pasting re-validates more strongly: the panel is dismissed, the original app
  is brought back, and the system-wide focused element is re-read after focus
  settles. The write (or the synthesised ⌘V) only happens when the focused
  element is the *same* AX element (pid + identity). Any mismatch copies the
  entry and shows a toast instead.
