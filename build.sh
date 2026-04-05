#!/bin/bash
# Build ClaudeNotch.app from Swift sources (no Xcode required).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeNotch"
APP_BUNDLE="${APP_NAME}.app"

echo "▸ Compiling (release)..."
swift build -c release

echo "▸ Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "${APP_BUNDLE}" >/dev/null 2>&1 || true

echo "▸ Done: ${APP_BUNDLE}"
echo "▸ Launch:  open ${APP_BUNDLE}"
echo "▸ Or run:  ./run.sh"
