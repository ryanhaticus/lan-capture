#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP_DIR="$PROJECT_DIR/dist/LAN Capture.app"
readonly BUILD_CONFIGURATION="${LANCAPTURE_BUILD_CONFIGURATION:-release}"

if [[ "$BUILD_CONFIGURATION" != "debug" && "$BUILD_CONFIGURATION" != "release" ]]; then
    echo "LANCAPTURE_BUILD_CONFIGURATION must be 'debug' or 'release'." >&2
    exit 2
fi

cd "$PROJECT_DIR"
swift build -c "$BUILD_CONFIGURATION"

readonly BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lan-capture-build.XXXXXX")"
readonly STAGED_APP="$TEMP_DIR/LAN Capture.app"
readonly CONTENTS_DIR="$STAGED_APP/Contents"
readonly ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/lancapture" "$CONTENTS_DIR/MacOS/lancapture"
cp "Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

VERSION="${LANCAPTURE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)}"
BUILD_NUMBER="${LANCAPTURE_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "LANCAPTURE_VERSION must use the form MAJOR.MINOR.PATCH." >&2
    exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "LANCAPTURE_BUILD_NUMBER must contain one to three numeric components." >&2
    exit 2
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

swift "scripts/generate-icon.swift" "$ICONSET_DIR"
iconutil --convert icns "$ICONSET_DIR" \
    --output "$CONTENTS_DIR/Resources/AppIcon.icns"

SIGNING_IDENTITY="${LANCAPTURE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
            | head -1
    )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
            | head -1
    )"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --options runtime --sign - "$STAGED_APP"
    echo "Signed with an ad-hoc signature."
elif [[ -n "$SIGNING_IDENTITY" ]]; then
    SIGNING_OPTIONS=(--force --options runtime --sign "$SIGNING_IDENTITY")
    if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
        SIGNING_OPTIONS+=(--timestamp)
    fi
    codesign "${SIGNING_OPTIONS[@]}" "$STAGED_APP"
    echo "Signed with: $SIGNING_IDENTITY"
else
    codesign --force --options runtime --sign - "$STAGED_APP"
    echo "Warning: no signing identity was found; used an ad-hoc signature."
    echo "Screen Recording permission can be requested again after each rebuild."
fi

codesign --verify --deep --strict "$STAGED_APP"
mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"

echo "Built LAN Capture $VERSION ($BUILD_NUMBER)"
echo "$APP_DIR"
