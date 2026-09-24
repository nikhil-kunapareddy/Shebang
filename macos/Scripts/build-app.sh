#!/bin/bash
# Builds dist/GhostHand.app (menu bar app + bundled `ghosthand` CLI) from the Swift package.
#
#   Scripts/build-app.sh             build and sign dist/GhostHand.app
#   Scripts/build-app.sh --install   also replace /Applications/GhostHand.app
#   Scripts/build-app.sh --zip       also write dist/GhostHand-v<version>-macos-<arch>.zip
#
# Signing: SIGN_IDENTITY overrides; otherwise the first "Developer ID Application" or
# "Apple Development" identity is used. Without one the app is ad-hoc signed, which works
# locally but macOS forgets the Accessibility grant every time the binary changes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

INSTALL=false
ZIP=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --zip) ZIP=true ;;
        *) echo "Usage: $0 [--install] [--zip]" >&2; exit 1 ;;
    esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"

echo "Building GhostHand $VERSION ($ARCH)…"
swift build -c release --product GhostHandApp
swift build -c release --product ghosthand
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/GhostHand.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GhostHandApp" "$APP/Contents/MacOS/GhostHand"
cp "$BIN/ghosthand" "$APP/Contents/MacOS/ghosthand"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/../.env.example" "$APP/Contents/Resources/env.example"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
    [[ -z "$IDENTITY" ]] && IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Apple Development:/ {print $2; exit}')"
fi

SIGN_FLAGS=(--force --options runtime --entitlements Resources/GhostHand.entitlements)
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
    echo "warning: no signing identity found; ad-hoc signing. Re-grant Accessibility after each rebuild." >&2
    IDENTITY="-"
else
    SIGN_FLAGS+=(--timestamp)
    echo "Signing with: $IDENTITY"
fi
# Sign the nested CLI before the bundle that contains it.
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/ghosthand"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"

if $ZIP; then
    ARCHIVE="$ROOT/dist/GhostHand-v$VERSION-macos-$ARCH.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    (cd "$ROOT/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
    echo "Archive: $ARCHIVE"
fi

if $INSTALL; then
    DEST="/Applications/GhostHand.app"
    osascript -e 'tell application id "com.ghosthand.mac" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 50); do pgrep -xq GhostHand || break; sleep 0.1; done
    if pgrep -xq GhostHand; then
        echo "GhostHand is still running; quit it and retry." >&2
        exit 1
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed: $DEST"
fi
