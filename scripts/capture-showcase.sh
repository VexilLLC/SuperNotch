#!/bin/bash
# Regenerates the documentation screenshots from fabricated demo content.
#
# The app is staged under its own bundle identifier and pointed at a throwaway
# container, so the showcase instance shares neither preferences nor stored data
# with the installed app. Nothing real — clipboard history, shelves, notes,
# playback — reaches the images.
#
#   ./scripts/capture-showcase.sh [output-directory]
#
# Requires Screen Recording permission for the terminal running it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
OUTPUT="${1:-$ROOT/docs/images/showcase}"
BUNDLE_ID="com.vexil.supernotch.showcase"

if [ ! -d "$ROOT/build/SuperNotch.app" ]; then
  echo "building the app bundle first"
  ./scripts/build-app.sh release
fi

STAGE="$(mktemp -d)"
CONTAINER="$STAGE/container"
APP="$STAGE/SuperNotchShowcase.app"
mkdir -p "$CONTAINER"

cleanup() {
  if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "staging a separate bundle identity"
cp -R "$ROOT/build/SuperNotch.app" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName SuperNotchShowcase" "$APP/Contents/Info.plist"
codesign --force --sign - --deep "$APP" >/dev/null 2>&1
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "launching the showcase instance"
SUPERNOTCH_SHOWCASE=1 \
SUPERNOTCH_SHOWCASE_CONTAINER="$CONTAINER" \
  "$APP/Contents/MacOS/SuperNotch" >"$STAGE/app.log" 2>&1 &
APP_PID=$!

mkdir -p "$OUTPUT"
swift "$ROOT/scripts/showcase/ShowcaseDriver.swift" --pid "$APP_PID" --out "$OUTPUT"

HERO="$(dirname "$OUTPUT")/hero.png"
echo "composing the hero"
swift "$ROOT/scripts/showcase/ComposeHero.swift" --shots "$OUTPUT" --out "$HERO"

# The captures are Retina-resolution; README images never render that large.
# Only ever shrink: resampling a capture upwards costs size and sharpness.
shrink_to() {
  local image="$1" limit="$2"
  local width
  width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ { print $2 }')"
  if [ "$width" -gt "$limit" ]; then sips --resampleWidth "$limit" "$image" >/dev/null; fi
}

echo "resampling for the repository"
shrink_to "$HERO" 1920
for image in "$OUTPUT"/*.png; do
  shrink_to "$image" 1600
done
