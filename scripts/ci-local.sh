#!/usr/bin/env bash
#
# Reproduce the GitHub Actions build locally on a Mac.
#
#   scripts/ci-local.sh            # generate, test, build, package a DMG
#
# Mirrors .github/workflows/build.yml: unsigned/ad-hoc build, no secrets.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME=$(awk '/^name:/ {print $NF; exit}' project.yml)
[ -n "$APP_NAME" ] || { echo "could not read the app name from project.yml" >&2; exit 1; }
echo "Building ${APP_NAME}"

command -v xcodegen >/dev/null || { echo "install xcodegen first: brew install xcodegen" >&2; exit 1; }

xcodegen generate

echo "== tests =="
xcodebuild test \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

echo "== release build =="
xcodebuild -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  ARCHS="x86_64 arm64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build \
  SYMROOT="$PWD/build"

APP_PATH="build/Release/${APP_NAME}.app"
codesign --force --deep --sign - "$APP_PATH" || true

echo "== DMG =="
cd build/Release
rm -f "${APP_NAME}.dmg"
mkdir -p dmg-root
cp -R "${APP_NAME}.app" dmg-root/
ln -s /Applications dmg-root/Applications
hdiutil create -volname "${APP_NAME}" -srcfolder dmg-root -ov -format UDZO "${APP_NAME}.dmg"
rm -rf dmg-root
shasum -a 256 "${APP_NAME}.dmg" | tee "${APP_NAME}.dmg.sha256"
echo "Built $(pwd)/${APP_NAME}.dmg"
