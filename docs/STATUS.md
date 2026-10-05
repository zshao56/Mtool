# Implementation status

This file records exactly what has been verified and what has not. It is meant
to be updated as work lands.

## Verified

- **Automated CI build and unit tests pass** (commit `a094a42`, GitHub Actions run `37262310203` on 2026-10-05):
  - `xcodebuild test` executed 156 unit tests with **0 failures** on macOS runner.
  - Release build succeeded (universal binary for `x86_64` and `arm64`).
  - `Mtool.dmg` produced as a workflow artifact; the app uses an ad-hoc signature, not an Apple Developer ID signature.
- **Artifact integrity verified locally after download**:
  - `shasum -a 256 -c` verified (SHA-256: `069db596960b61da2c1dccf87ddbf2e7d379907af5d891feba8403eed6d3910a`).
  - `hdiutil verify` confirmed valid disk image.
  - DMG volume structure contains `Mtool.app` and `/Applications` shortcut.
  - Ad-hoc signature passes `codesign --verify --deep --strict`.
  - Confirmed as an **unnotarized preview build** (未公证预览构建); macOS Gatekeeper requires right-click → Open on first run.
- **Every Swift file parses** (`swiftc -parse` over all sources).
- **`project.yml` and the GitHub Actions workflow are valid YAML**, and
  `ConfigSchema.json` is valid JSON.

## NOT verified

- **Local compilation environment**: The local development machine only has Xcode
  CommandLineTools (no full `Xcode.app`), so local app compilation and local `xcodebuild`
  are not available. All builds and automated tests currently run on GitHub Actions macOS runners.
- **No real-desktop acceptance has been done**: The 37 checklist items in
  `docs/ACCEPTANCE.md` are **unrun**. CI build and test success proves compilation,
  packaging integrity, and unit logic, but **must NOT be conflated with real-world functional
  desktop acceptance**. Actual cross-application Accessibility permissions, system focus
  switches, pasteboard restoration, and window behaviors still require manual desktop testing.

## Deliberately conservative behaviour

- Editable detection for scenario 2 is **known text role + a writable attribute
  (`AXSelectedText` or `AXValue`) + enabled + non-secure**. The non-standard
  `AXEditable` attribute is kept **tri-state**: an explicit `false` always refuses
  scenario 2 (read-only control), a missing attribute falls back to the role rule
  (browser/Electron), and an explicit `true` is extra evidence for unfamiliar
  roles. A role alone never leads to a paste.
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
  is brought back, and focus is polled every 50 ms (up to 1 s) until the
  system-wide focused element is the *same* AX element (pid + identity). Only
  then do we write or synthesise a ⌘V. A timeout, a third app coming forward, or
  a generation change all copy the entry and show a toast instead.
- The transient clipboard used for a synthesised paste is only restored when the
  pasteboard's `changeCount` still matches the count Mtool's own write produced,
  so a copy the user makes in that window is never overwritten.
- Image entries can be pasted through the same confirmed-focus transient
  clipboard (the AX text write is skipped for them); if the target cannot be
  re-validated they are copied only.
- Snippets and history share one ↑/↓/Enter navigation order (snippets first), the
  editor owns the keyboard while open, and every row's paste area is a separate
  control from its action buttons.
- Fixed static logger references across controllers (`Self.log`) and explicit closure
  captures (`self.generation`, `self.isRunning`).
- Aligned `ActionRoundTripTests` with the 6 research presets (5 AI presets + copy),
  verifying polish compare mode and serialization round-trip; automated test suite expanded
  to 151 tests with 0 failures on CI runner.
