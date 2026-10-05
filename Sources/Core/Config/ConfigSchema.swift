import Foundation

/// The JSON Schema written next to the config file.
///
/// JSON has no comments, and that is the one real cost of choosing it for a file
/// people edit. A schema buys back more than comments would: an editor offers
/// completion for every key, lists the allowed values of an enum, shows the
/// documentation on hover, and marks a mistake as you type it. And unlike
/// comments, none of it is lost when the app rewrites the file.
///
/// It is regenerated on every launch, so it can never drift behind the app.
enum ConfigSchema {

    static let json = """
    {
      "$schema": "http://json-schema.org/draft-07/schema#",
      "title": "Selection popup configuration",
      "description": "Everything in the app's Settings window. Edit it by hand if you like — the app reads this file at launch, so changes take effect the next time it starts. API keys are NOT here; they live in the macOS Keychain, so this file holds no secrets and can be committed. Note that an action of kind \\"script\\" runs a shell command: read a config from someone else before using it (the app also asks before a script runs for the first time).",
      "type": "object",
      "properties": {
        "$schema": { "type": "string" },
        "version": {
          "type": "integer",
          "description": "Format version of this file. Written by the app; leave it alone."
        },

        "main": {
          "type": "object",
          "description": "Mtool's main shortcut and the optional double-tap Command trigger.",
          "properties": {
            "hotKeyEnabled": { "type": "boolean",
              "description": "Register the main three-scene shortcut. Default true." },
            "hotKey": { "type": "string",
              "description": "The main shortcut, written as spoken, e.g. \\\"opt+space\\\". There is a default (⌥Space)." },
            "autoPopupOnSelect": { "type": "boolean",
              "description": "Open the action bar automatically after a text selection. Default false so reading is not interrupted." },
            "autoPopupDelayMs": { "type": "number", "minimum": 0, "maximum": 2000,
              "description": "Delay before the automatic popup, so a double/triple click resolves first." },
            "doubleCommandEnabled": { "type": "boolean",
              "description": "Trigger the main shortcut by double-tapping Command. Default false; needs Accessibility/Input Monitoring." },
            "doubleCommandThresholdMs": { "type": "number", "minimum": 150, "maximum": 600,
              "description": "Maximum interval between the two Command releases, in milliseconds. Default 350." }
          },
          "additionalProperties": true
        },

        "search": {
          "type": "object",
          "description": "The floating question box used when there is no selected text.",
          "properties": {
            "askPrompt": { "type": "string",
              "description": "System prompt for the built-in free-question mode. Other modes use the editable AI action prompts." }
          },
          "additionalProperties": true
        },

        "clipboard": {
          "type": "object",
          "description": "The local clipboard history and snippets. Everything stays on this Mac.",
          "properties": {
            "enabled": { "type": "boolean", "description": "Record clipboard history. Default true." },
            "paused": { "type": "boolean", "description": "Temporarily stop recording without turning the feature off." },
            "maxItems": { "type": "integer", "minimum": 0, "maximum": 5000,
              "description": "Maximum non-pinned history rows. Pinned items and snippets are never removed." },
            "retentionDays": { "type": "integer", "minimum": 0, "maximum": 365,
              "description": "Days a history row is kept. 0 keeps until the capacity cap evicts it." },
            "maxImageMB": { "type": "number", "minimum": 0, "maximum": 100,
              "description": "Largest image stored, in megabytes." },
            "plainTextPaste": { "type": "boolean", "description": "Paste clipboard entries as plain text. Default true." },
            "excludedApps": {
              "type": "array", "items": { "type": "string" },
              "description": "Bundle ids the clipboard watcher will not record from. Starts with common password managers. The system clipboard cannot label every password copy, so this is best-effort."
            }
          },
          "additionalProperties": true
        },

        "general": {
          "type": "object",
          "description": "App-wide settings.",
          "properties": {
            "language": {
              "type": ["string", "null"],
              "enum": ["en", "zh-Hans", null],
              "description": "Interface language. null means follow the system."
            },
            "analytics": {
              "type": "boolean",
              "description": "Share anonymous usage statistics. No selected text, paths or personal data are ever sent."
            }
          },
          "additionalProperties": true
        },

        "popup": {
          "type": "object",
          "description": "The popup that appears when you select text. It runs whenever the app does — there is no on/off setting; quit the app to stop it.",
          "properties": {
            "style": {
              "type": "string",
              "enum": ["capsule", "liquidGlass", "donut"],
              "description": "capsule = a bar above the selection. liquidGlass / donut = a ring centred on the cursor (donut is the 3D glass ring). The old \\"wheel\\" value still loads, as liquidGlass with dividers on."
            },
            "autoExpandHeight": {
              "type": "boolean",
              "description": "Let a result panel grow to fit its text (up to a maximum, then scroll). Width is always fixed."
            },
            "resultFontSize": {
              "type": "number", "minimum": 11, "maximum": 20,
              "description": "Base font size of the rendered result."
            },
            "readingHighlight": {
              "type": "string", "enum": ["pill", "marker", "solid", "karaoke"],
              "description": "How the reading window marks the word being spoken: pill = a rounded pill behind the word, marker = a highlighter stroke across its lower half, solid = an accent-colour pill with the word in white, karaoke = unread text faded and the spoken word in the accent colour."
            },
            "compareView": {
              "type": "string", "enum": ["diff", "result"],
              "description": "What an action whose output is \\"compare\\" shows first: diff = the selection above the result with the changes marked, result = the result alone. The switch in the popup changes it. Default diff."
            },
            "hotKeyEnabled": {
              "type": "boolean",
              "description": "Register the popup hotkey: select text, press it, and the popup opens. Works while paused, in excludedApps and in address bars — it is pressed on purpose. Paused + hotkey = the popup opens only when asked. Default false."
            },
            "hotKey": {
              "type": "string",
              "pattern": "^(([a-zA-Z0-9]+\\\\+)*[a-zA-Z0-9]+)?$",
              "description": "The popup hotkey, written the way it is spoken, e.g. \\"opt+x\\". Empty = none recorded yet (there is no default). Same key names as ocr.hotKey, and it cannot be the same combo."
            },
            "simulateCopy": {
              "type": "boolean",
              "description": "When an app does not hand over the selection directly, press Cmd+C for you and read the clipboard (restored afterwards). Needed for most browsers and Electron apps. Default true."
            },
            "ignoreAddressBars": {
              "type": "boolean",
              "description": "Selecting text in a browser's address bar (Chrome and other Chromium browsers, Safari) does not open the popup. Default true."
            },
            "terminalApps": {
              "type": "array", "items": { "type": "string" },
              "description": "Bundle IDs of terminals where a program running inside (herdr, tmux with mouse mode, vim) may select and copy text by itself. Selecting there reads the clipboard when it changes during the drag. Written with the built-in list the first time it is missing."
            },
            "excludedApps": {
              "type": "array", "items": { "type": "string" },
              "description": "Bundle IDs of apps where selecting text never opens the popup, e.g. \\"com.microsoft.Excel\\". The screenshot-OCR hotkey still works in them."
            }
          },
          "additionalProperties": true
        },

        "wheel": {
          "type": "object",
          "description": "Geometry of the Liquid ring (popup.style liquidGlass). 3D Glass has its own copy in donut. Sizes are in points.",
          "properties": {
            "outerRadius": { "type": "number", "minimum": 90, "maximum": 170,
              "description": "Outer edge of the main ring." },
            "innerRadius": { "type": "number", "minimum": 28, "maximum": 140,
              "description": "The hole in the middle. Kept at least 26 below outerRadius." },
            "subSeam": { "type": "number", "minimum": 0, "maximum": 20,
              "description": "Gap between the main ring and a group's second ring." },
            "subThickness": { "type": "number", "minimum": 34, "maximum": 72,
              "description": "Band width of the second ring." },
            "showIcons": { "type": "boolean", "description": "Draw each action's icon." },
            "showLabels": { "type": "boolean", "description": "Draw each action's name." },
            "autoHideOnExit": { "type": "boolean",
              "description": "Dismiss the ring when the pointer leaves it." },
            "liquidDividers": { "type": "boolean",
              "description": "Liquid style: draw hairline dividers between slices." },
            "donutDividers": { "type": "boolean",
              "description": "3D style: carve a groove between neighbouring slices. Default false." }
          },
          "additionalProperties": true
        },

        "donut": {
          "type": "object",
          "description": "Geometry of the 3D Glass ring (popup.style donut), separate from Liquid's in wheel. Same knobs and ranges as wheel. Sizes are in points.",
          "properties": {
            "outerRadius": { "type": "number", "minimum": 90, "maximum": 170 },
            "innerRadius": { "type": "number", "minimum": 28, "maximum": 140 },
            "subSeam": { "type": "number", "minimum": 0, "maximum": 20 },
            "subThickness": { "type": "number", "minimum": 34, "maximum": 72 },
            "showIcons": { "type": "boolean" },
            "showLabels": { "type": "boolean" },
            "autoHideOnExit": { "type": "boolean" }
          },
          "additionalProperties": true
        },

        "capsule": {
          "type": "object",
          "description": "The capsule bar (popup.style capsule). Sizes are in points.",
          "properties": {
            "iconSize": { "type": "number", "minimum": 11, "maximum": 24,
              "description": "Size of each button's icon." },
            "labelSize": { "type": "number", "minimum": 8, "maximum": 14,
              "description": "Size of each button's name." },
            "border": { "type": "boolean",
              "description": "Draw a very thin outline around the bar and its dropdown. Default true." }
          },
          "additionalProperties": true
        },

        "ocr": {
          "type": "object",
          "description": "Press a hotkey, drag a box over anything on screen, get the text out of it. Needs the Screen Recording permission.",
          "properties": {
            "enabled": { "type": "boolean", "description": "Register the hotkey." },
            "autoCopy": { "type": "boolean",
              "description": "Also put the recognized text on the clipboard." },
            "hotKey": {
              "type": "string",
              "pattern": "^([a-zA-Z0-9]+\\\\+)*[a-zA-Z0-9]+$",
              "description": "Written the way it is spoken, e.g. \\"shift+cmd+s\\". Modifiers: ctrl, opt, shift, cmd. Keys: a-z, 0-9, f1-f12, space, return, tab, escape, delete, left, right, up, down."
            }
          },
          "additionalProperties": true
        },

        "history": {
          "type": "object",
          "description": "The History page: every action run from the popup, kept on this Mac only (~/Library/Application Support/<baseID>/history.sqlite).",
          "properties": {
            "enabled": { "type": "boolean", "description": "Record runs. Default true." },
            "retentionDays": { "type": "integer", "minimum": 0,
              "description": "Days a record is kept; 0 keeps them forever (the default)." },
            "recordCopy": { "type": "boolean", "description": "Record the Copy action too. Default true." },
            "excludedApps": {
              "type": "array", "items": { "type": "string" },
              "description": "Bundle ids of apps whose selections are never recorded. Starts with the common password managers."
            }
          },
          "additionalProperties": true
        },

        "webPreview": {
          "type": "object",
          "description": "Settings for the 'web preview' kind of action.",
          "properties": {
            "fallbackToSearch": { "type": "boolean",
              "description": "When the selection holds no link, search the web for the text instead." },
            "searchEngine": { "type": "string", "enum": ["bing", "google", "duckduckgo"] }
          },
          "additionalProperties": true
        },

        "models": {
          "type": "object",
          "description": "The default model for AI actions. The API key is NOT here — it is in the Keychain.",
          "properties": {
            "provider": { "type": "string",
              "description": "e.g. deepseek, openai, anthropic, ollama. Changing this resets model and apiURL to that provider's defaults." },
            "model": { "type": "string", "description": "Model id, as the provider spells it." },
            "apiURL": { "type": "string", "description": "Base URL of the provider's API." },
            "thinking": { "type": "string",
              "description": "Reasoning effort. Which values are allowed depends on the provider; anything it does not support is clamped. Use \\"none\\" for fast results." }
          },
          "additionalProperties": true
        },

        "speech": {
          "type": "object",
          "description": "Readers for the speak action. API keys are NOT here — they are in the Keychain.",
          "properties": {
            "defaultReader": { "type": "string",
              "description": "The id of the reader speak actions use unless they name one. \\"system\\" = the macOS system voice." },
            "readers": {
              "type": "array",
              "description": "Cloud voices set up in Settings › Speech.",
              "items": {
                "type": "object",
                "properties": {
                  "id": { "type": "string" },
                  "name": { "type": "string", "description": "What the settings and the reading window show." },
                  "engine": { "type": "string", "enum": ["qwen-audio", "minimax", "elevenlabs"] },
                  "model": { "type": "string", "description": "e.g. qwen-audio-3.0-tts-flash, speech-2.8-turbo, eleven_flash_v2_5" },
                  "voice": { "type": "string", "description": "The provider's voice id, e.g. longanhuan_v3.6" },
                  "speed": { "type": "number", "minimum": 0.5, "maximum": 2,
                    "description": "ElevenLabs accepts 0.7–1.2 only; a value outside is read at the nearest end." },
                  "region": { "type": "string", "enum": ["cn", "intl"],
                    "description": "cn = mainland China endpoint, intl = international endpoint. Not used by ElevenLabs." }
                },
                "required": ["id", "engine"],
                "additionalProperties": true
              }
            }
          },
          "additionalProperties": true
        },

        "actions": {
          "type": "array",
          "description": "The actions the popup offers, in order. An action with \\"kind\\": \\"group\\" opens a second ring holding its children.",
          "items": { "$ref": "#/definitions/action" }
        }
      },
      "additionalProperties": true,

      "definitions": {
        "action": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Stable id. Leave it alone; a new action needs a new one." },
            "title": { "type": "string", "description": "What the popup shows." },
            "iconSymbol": { "type": "string", "description": "An SF Symbol name, e.g. \\"doc.on.doc\\"." },
            "kind": {
              "type": "string",
              "enum": ["ai", "copy", "webPreview", "quickLook", "revealInFinder", "openURL", "speak",
                       "transform", "shortcut", "script", "systemTranslate", "pause", "inspect", "settings", "group"],
              "description": "What the action does. ai = send the selection to a model. openURL = open url with {text} filled in. speak = read it aloud. transform = a local text operation (op). shortcut = run a Shortcut. script = run a shell command. systemTranslate = translate with macOS's own on-device translator into targetLanguage (macOS 15+). pause = pause the popup, like the menu bar's Pause (resume from the menu bar or settings). inspect = show the selection's accessibility element and its path (a debugging aid). settings = open the app's settings window. group = hold children. The rest act on links and paths."
            },
            "prompt": { "type": "string",
              "description": "For \\"ai\\": the instruction sent with the selection." },
            "url": { "type": "string",
              "description": "For \\"openURL\\": the address. {text} is replaced by the selection, encoded as one query value. e.g. https://www.google.com/search?q={text} or dict://{text}" },
            "openIn": { "type": "string", "enum": ["browser", "preview"],
              "description": "For \\"openURL\\": browser (default) or the popup's preview window. Addresses that are not web pages always open in the app that handles them." },
            "op": { "type": "string",
              "enum": ["uppercase", "lowercase", "titleCase", "sentenceCase", "camelCase", "snakeCase", "kebabCase",
                       "sortLines", "uniqueLines", "reverseLines", "joinLines", "trim", "toSimplified", "toTraditional",
                       "pinyin", "spaceCJK", "jsonPretty", "jsonMinify", "urlEncode", "urlDecode", "cleanURL", "count"],
              "description": "For \\"transform\\": which operation. count always shows its result in the popup." },
            "shortcut": { "type": "string",
              "description": "For \\"shortcut\\": the name of a Shortcut. The selection is its input; its output is the result." },
            "script": { "type": "string",
              "description": "For \\"script\\": a shell command, run by your login shell. The selection is on standard input and in $MTOOL_TEXT; what it prints is the result. Times out after 10 seconds." },
            "output": { "type": "string", "enum": ["panel", "compare", "replace", "append", "copy"],
              "description": "For ai, transform, shortcut, script and systemTranslate: where the result goes. panel (default) shows it in the popup, which offers a Replace button; compare shows the selection above the result with the changes marked, then Replace; replace puts it in place of the selection; append puts it after the selection; copy puts it on the clipboard." },
            "targetLanguage": { "type": "string",
              "description": "For \\"systemTranslate\\": the language to translate into, as macOS names it, e.g. \\"zh\\" (Simplified Chinese), \\"zh-TW\\" (Traditional Chinese), \\"en\\", \\"en-GB\\", \\"ja\\", \\"fr\\"." },
            "reader": { "type": "string",
              "description": "For \\"speak\\": the id of the reader (see speech.readers, or \\"system\\"). Absent = speech.defaultReader." },
            "modelOverride": {
              "type": "object",
              "description": "Use a different model for THIS action only.",
              "properties": {
                "provider": { "type": "string" },
                "model": { "type": "string" },
                "effort": { "type": "string" }
              },
              "additionalProperties": true
            },
            "children": {
              "type": "array",
              "description": "Only for \\"kind\\": \\"group\\".",
              "items": { "$ref": "#/definitions/action" }
            }
          },
          "required": ["id", "title", "kind"],
          "additionalProperties": true
        }
      }
    }
    """
}
