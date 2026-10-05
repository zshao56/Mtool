#!/usr/bin/env bash
#
# Kill any running debug build, regenerate the project, build Debug, relaunch.
#
# ALWAYS launches via `open` so LaunchServices registers and activates the app
# normally. A raw-binary launch comes up behind other windows and will not
# foreground cleanly — that is why there is no direct-exec path here.
#
# Nothing below names the app: both names are read out of project.yml, so a
# rename needs no edit here.
#
# Usage: scripts/run.sh [--page <id>] [--preview] [--quiet]
#   --page <id>  pre-select a settings page (general|advanced|actions|history|ocr|models|speech|about)
#   --preview    pop the sample popup ~2s after launch, for looking at the capsule/wheel
#   --quiet      do NOT open the settings window (test the menu-bar-only path)
set -euo pipefail
cd "$(dirname "$0")/.."

# `name: &ANCHOR Value` → Value   (the anchor is optional)
SCHEME=$(awk '/^name:/ {print $NF; exit}' project.yml)
# The Debug override of PRODUCT_NAME, i.e. what the .app is actually called.
DEBUG_NAME=$(awk '/^        Debug:/{f=1} f && /PRODUCT_NAME:/{print $2; exit}' project.yml)
: "${SCHEME:?could not read the scheme name from project.yml}"
: "${DEBUG_NAME:?could not read the Debug PRODUCT_NAME from project.yml}"

APP="build/dd/Build/Products/Debug/${DEBUG_NAME}.app"

ARGS=(--settings)
while [ $# -gt 0 ]; do
  case "$1" in
    --page)    ARGS+=(--page "${2:-}"); shift 2 ;;
    --preview) ARGS+=(--popbar-preview); shift ;;
    --quiet)   ARGS=("${ARGS[@]/--settings}"); shift ;;
    *) echo "unknown arg: $1 (see the header of $0)" >&2; exit 2 ;;
  esac
done

echo "› killing any running ${DEBUG_NAME}…"
pkill -f "${DEBUG_NAME}" 2>/dev/null || true
sleep 1

echo "› xcodegen generate…"
xcodegen generate >/dev/null

echo "› building (Debug)…"
xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" -configuration Debug \
  -derivedDataPath build/dd -destination 'platform=macOS' build \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" || true

[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

echo "› launching via open…"
open "$APP" --args "${ARGS[@]}"
echo "› done. logs: tail -F \"$HOME/Library/Logs/${DEBUG_NAME}/${DEBUG_NAME}.log\""
