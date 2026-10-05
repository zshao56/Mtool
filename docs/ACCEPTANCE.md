# Manual acceptance checklist

The unit tests cover the pure logic, and CI compiles and packages the app, but
the cross-application behaviour below **can only be verified by a person on a
real macOS desktop**. None of these have been verified in this environment; they
are the acceptance criteria for a release, to be filled in on a Mac.

Mark each row `pass`, `fail`, or `not run`, and note the macOS version and the app
versions used.

| # | Scenario | Steps | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | Browser search box | Focus a browser search field with no selection, press the main shortcut | Question box opens with Clipboard button; choosing an item pastes into the original field | not run |
| 2 | WeChat / Electron input | Same, in the WeChat input box | Question box opens with Clipboard button; an item pastes into the box | not run |
| 3 | Ordinary selection | Select text in any app, press the shortcut | Action bar opens; AI actions run | not run |
| 4 | Selection inside an input | Highlight text inside a text field, press the shortcut | Action bar opens (scenario 1 wins) | not run |
| 5 | PDF reader | Select text in Preview, press the shortcut | Action bar opens with the text | not run |
| 6 | No focus / desktop | Click the desktop, press the shortcut | Quick search box opens | not run |
| 7 | Password field | Focus a password box, press the shortcut | Nothing is read; search box or no scenario 2 | not run |
| 8 | Second press closes | Open any scene, press the shortcut again | The surface closes immediately | not run |
| 9 | Esc / outside click | Open the question box, press Esc; reopen and click outside | Esc closes it; outside click leaves it floating | not run |
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
| 24 | Snippet keyboard paste | Open the clipboard panel, press ↓ to a snippet, Enter | It pastes into the original input through the validated path | not run |
| 25 | Clipboard preserved during paste | Trigger a paste, then immediately copy something else | The new copy is still on the clipboard (not overwritten by the restore) | not run |
| 26 | Image entry paste | Copy an image, open the panel in an input, choose it; then try when focus cannot be re-validated | Pastes only into the confirmed target, otherwise copies only | not run |
| 27 | Browser/WeChat editable detection | Focus a browser search box / WeChat input (no selection) | Question box with Clipboard button opens (role + writable attribute, not `AXEditable`) | not run |
| 28 | Re-record ⌥Space | In Keyboard settings click the main recorder, then press ⌥Space | Recorder accepts the combo; no search panel opens while recording | not run |
| 29 | Cancel main recording | Start recording, then press Esc, switch apps, close Settings, and wait for timeout in separate tries | The previous main shortcut works after every cancellation | not run |
| 30 | Re-record OCR and popup shortcuts | Record each feature's current shortcut again while it is enabled | Recorder receives the combo without launching OCR or the action bar | not run |
| 31 | Record double Command | Click the main recorder and double-tap Command | The local gesture is recognized and the double-Command switch turns on; global availability is shown separately | not run |
| 32 | Double Command across apps | With Accessibility granted, double-tap Command in another app; repeat without permission | Opens the expected scene when available; lack of permission is shown, not reported as success | not run |
| 33 | Search panel default layout | With no selection or editable focus, press the main shortcut | Compact question box opens with visible Ask, Translate and other configured modes below it | not run |
| 34 | Search mode and screenshot | Choose Translate, ask a question, reopen, then use Screenshot | Selected mode is used; result appears; reopen is compact and empty; screenshot is copied | not run |
| 35 | Editable question box | Focus an editable field, press shortcut, then click Clipboard | Question box opens first; history/snippets panel opens on click and can paste to the captured field | not run |
| 36 | Floating question box | Drag the top handle to another monitor, click in another app, submit a query, press shortcut again | Box stays at the moved location and in the visible screen, then closes on shortcut | not run |
| 37 | Custom AI prompts | Edit an AI action prompt/model and the Free Question prompt in Actions settings, then reopen box | Updated modes use the saved prompts and selected model; screenshot and clipboard remain built in | not run |

## Notes on limits

- Editable detection no longer depends on the non-standard `AXEditable`
  attribute: a known text role plus a writable `AXSelectedText`/`AXValue` is what
  routes to scenario 2, and a role alone never pastes. Row 27 is the one to run
  first on a real desktop.
- Rows 1–3, 10, 18, 27 and 28–32 are the highest risk: they exercise cross-process
  accessibility, Carbon hotkey suspension/restoration, and hardware modifier tap
  sequences that no unit test can fully cover.
