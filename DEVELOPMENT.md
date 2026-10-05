# Developing Mtool

How to build, test and release Mtool. For *what* the app is and how to use it, see
[README.md](README.md). For the upstream project this is derived from, see
[NOTICE](NOTICE).

## Build

```sh
brew install xcodegen
xcodegen generate
open Mtool.xcodeproj        # or: xcodebuild build -scheme Mtool -destination 'platform=macOS'
```

- The Debug build is a separate app (`Mtool-Debug`, id `…mtool.debug`) so it can
  sit next to a Release install.
- Logs: `~/Library/Logs/Mtool-Debug/Mtool-Debug.log` — `tail -F` it.
- Tests: `xcodebuild test -project Mtool.xcodeproj -scheme Mtool -destination 'platform=macOS'`.

Linux has no Xcode and no AppKit, so the app itself only builds on macOS. The
pure-logic files (routing, the double-tap state machine, the clipboard policy and
store) are Foundation-only and can be type-checked and unit-tested anywhere a
Swift toolchain is available.

## Settings

Everything lives in one file, `~/.config/mtool/config.json`, with a JSON schema
beside it (`config.schema.json`) that editors use for completion and validation.
The file is read once at launch. **API keys are never in it** — they are in the
Keychain.

## Architecture in one breath

- `PopBarController` owns the global monitors and the window manager.
- `ContextRouter` owns the clipboard and search panels and the scene state, and
  decides which scene to show using the pure `ContextRouting`.
- `FocusedInputInspector` answers "is this an editable, non-secure control?".
- `ClipboardStore` / `ClipboardWatcher` are the local history.
- `ModifierDoubleTapMonitor` translates global events for the pure
  `ModifierDoubleTapDetector`.

## Releases

See [docs/RELEASING.md](docs/RELEASING.md). There are no upstream credentials in
the workflow; signing is optional and uses the fork owner's own secrets.

## Acceptance

Cross-application behaviour must be checked by hand on a Mac. The checklist is in
[docs/ACCEPTANCE.md](docs/ACCEPTANCE.md).

## License

GPL-3.0. Mtool is a derivative of QDuo © XueshiQiao; keep the copyright notices
and [NOTICE](NOTICE) intact when redistributing.
