# Mtool

Mtool is a **macOS menu-bar tool for research work**. One configurable global
shortcut reads the context of the app you are in *before* Mtool takes focus, then
opens exactly one of three surfaces:

| Priority | Context | Surface | Default actions |
| --- | --- | --- | --- |
| 1 | Non-empty selected text | The action bar (ring or capsule) | Translate, Explain, Read Paper, Polish, Abstract, Copy |
| 2 | Focus is in an editable control with no selection | Clipboard panel | Search history, pinned snippets, paste into the original box |
| 3 | Anything else, or the context could not be read | Quick search box | Free question or a preset mode; screenshot & copy |

Pressing the same shortcut again immediately closes whatever is showing. Esc or a
click outside also closes it. On first install the recommended shortcut is
`⌥Space`; it can be recorded to anything else in Settings. An optional
**double-tap Command** trigger is available too.

Mtool is a **GPL-3.0 derivative of [QDuo](https://github.com/XueshiQiao/qduo)** by
XueshiQiao. See [License and attribution](#license-and-attribution) below.

---

## Install

Download the latest `Mtool.dmg` from the
[Releases](https://github.com/zshao56/Mtool/releases) page, open it and drag
**Mtool** into Applications.

> **Mtool is not notarized.** The public builds are unsigned (ad-hoc signed) and
> have not been through Apple's notarization service. macOS Gatekeeper will warn
> on first launch. To open it: **right-click the app → Open**, then confirm. Do
> this once; afterwards it opens normally. This is expected and is not a defect.

## Permissions

Mtool asks for these only when the related feature needs them:

- **Accessibility** — to read the selected text, detect the focused input control
  and paste a history entry back. Without it, scenario 1 and the paste half of
  scenario 2 cannot work; the quick search box still works.
- **Screen Recording** — for Screenshot Text (OCR) and for *screenshot & copy* in
  the quick search box.
- **Input Monitoring** — sometimes required by macOS for the optional double-tap
  Command trigger. If the system does not deliver modifier events, Settings says
  the trigger is unavailable instead of pretending it works.

## AI setup

Translation, explanation, paper reading, polishing and summaries use an
**OpenAI-compatible API**. Open **Settings → AI Models**, pick a provider
(DeepSeek, OpenAI, Doubao, Qwen/DashScope or a local Ollama), and paste your API
key. Keys are stored **only in the macOS Keychain** — never in the config file or
the repository. The free-question search box and each preset mode reuse the same
provider.

Content is sent to a model **only** after you explicitly run an AI action.

## Clipboard history and snippets

When enabled, Mtool stores text, links and images copied on this Mac in a local
SQLite file and keeps images as PNGs next to it. It records every 500 ms,
de-duplicates by content, and applies your capacity/retention settings. Pinned
items and saved snippets ("常用词") are never removed automatically.

Privacy notes, stated plainly:

- Everything stays on this Mac. No history is ever sent to a model or a server.
- The system clipboard cannot label every password copy, so recording is
  **best-effort**. Common password managers are excluded by default, and you can
  pause recording or add exclusions in **Settings → Clipboard**. For secrets,
  prefer pausing or disabling the feature.

## Screenshots

- The quick search box has a fixed **Screenshot** button: click it, drag a region,
  and the pixels are copied to the clipboard as a PNG. Cancelling (Esc or
  right-click) leaves the clipboard untouched.
- **Screenshot Text** (OCR) keeps QDuo's original flow: a shortcut, a region,
  then the recognised text opens in the same action bar.

## Build from source

Requires macOS 13+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
xcodebuild test -project Mtool.xcodeproj -scheme Mtool -destination 'platform=macOS'
```

CI builds and packages the DMG on a macOS runner; see
[docs/RELEASING.md](docs/RELEASING.md). What has and has not been verified is
recorded in [docs/STATUS.md](docs/STATUS.md).

## License and attribution

Mtool is free software, licensed under the **GNU General Public License v3.0**
(see [LICENSE](LICENSE)).

It is a derivative work of **QDuo** (https://github.com/XueshiQiao/qduo),
© XueshiQiao, also GPL-3.0. The original copyright notice and license are
retained. A summary of the changes made for Mtool is in [NOTICE](NOTICE).
Because Mtool is distributed under the GPL, the complete corresponding source is
available in this repository.
