# Manual acceptance checklist

The unit tests cover the pure logic, and CI compiles and packages the app, but
the cross-application behaviour below **can only be verified by a person on a
real macOS desktop**. None of these have been verified in this environment; they
are the acceptance criteria for a release, to be filled in on a Mac.

Mark each row `pass`, `fail`, or `not run`, and note the macOS version and the app
versions used.

| # | Scenario | Steps | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | Browser search box | Focus a browser search field with no selection, press the main shortcut | Clipboard panel opens, not the action bar | not run |
| 2 | WeChat / Electron input | Same, in the WeChat input box | Clipboard panel opens; an item pastes into the box | not run |
| 3 | Ordinary selection | Select text in any app, press the shortcut | Action bar opens; AI actions run | not run |
| 4 | Selection inside an input | Highlight text inside a text field, press the shortcut | Action bar opens (scenario 1 wins) | not run |
| 5 | PDF reader | Select text in Preview, press the shortcut | Action bar opens with the text | not run |
| 6 | No focus / desktop | Click the desktop, press the shortcut | Quick search box opens | not run |
| 7 | Password field | Focus a password box, press the shortcut | Nothing is read; search box or no scenario 2 | not run |
| 8 | Second press closes | Open any scene, press the shortcut again | The surface closes immediately | not run |
| 9 | Esc / outside click | Open a panel, press Esc; then click outside | Both close it | not run |
| 10 | Multi-monitor | Repeat 1–3 on a second display (incl. a display to the left) | Panels land on the correct screen | not run |
| 11 | Shortcut conflict | Record a shortcut already held by another app | Settings shows it is occupied and keeps the old one | not run |
| 12 | OCR permission denied | Deny Screen Recording, trigger Screenshot Text | A clear prompt; other scenes still work | not run |
| 13 | Screenshot copy | Quick search → Screenshot, drag a region | PNG on the clipboard; a toast confirms | not run |
| 14 | Screenshot cancel | Same, then Esc / right-click | Clipboard is unchanged | not run |
| 15 | Clipboard persistence | Copy several things, quit and relaunch Mtool | History and snippets are still there | not run |
| 16 | Clipboard pause | Pause recording, copy something | Not stored; the system clipboard still works | not run |
| 17 | Excluded app | Add an app to the exclusion list, copy there | Not stored | not run |
| 18 | Paste after focus change | Open the clipboard panel, switch apps, choose an item | It is copied (with a message), not pasted into the wrong app | not run |
| 19 | Double-tap Command | Enable it, double-tap Command in another app | The same three scenes open; Settings reports availability | not run |
| 20 | Auto popup off by default | Fresh install, select text without pressing anything | Nothing opens | not run |
| 21 | Gatekeeper | Open the downloaded DMG on a clean Mac | Right-click → Open works; the app runs | not run |
| 22 | Snippet editing | Open the clipboard panel, add a saved item, edit title/content, reorder, relaunch | Everything persists in the chosen order | not run |
| 23 | Stale read discarded | Press the shortcut, then switch apps before the surface appears | Nothing opens over the newly-frontmost app | not run |

## Notes on limits

- Automatic paste into browser/Electron controls is gated behind
  `FocusedInputInspector.browserFallbackEnabled`, which is **off** until rows 1
  and 2 pass on a real desktop.
- Rows 1–3, 10 and 18 are the highest risk: they exercise cross-process
  accessibility that no unit test can cover.
