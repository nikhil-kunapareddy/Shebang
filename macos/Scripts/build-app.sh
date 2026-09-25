#!/bin/bash
# Builds dist/Shebang.app (menu bar app + `shebang` CLI in Contents/Helpers) from the Swift package.
#
#   Scripts/build-app.sh             build and sign dist/Shebang.app
#   Scripts/build-app.sh --install   also replace /Applications/Shebang.app
#   Scripts/build-app.sh --zip       also write dist/Shebang-v<version>-macos-<arch>.zip
#   Scripts/build-app.sh --dmg       also write dist/Shebang-v<version>-macos-<arch>.dmg (drag-to-install
#                                    window; needs dmgbuild: pip install dmgbuild)
#
# Signing: SIGN_IDENTITY overrides; otherwise the first "Developer ID Application" or
# "Apple Development" identity is used. Without one the app is ad-hoc signed, which works
# locally but macOS forgets the Accessibility grant every time the binary changes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

INSTALL=false
ZIP=false
DMG=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --zip) ZIP=true ;;
        --dmg) DMG=true ;;
        *) echo "Usage: $0 [--install] [--zip] [--dmg]" >&2; exit 1 ;;
    esac
done
if $DMG && ! command -v dmgbuild >/dev/null; then
    echo "--dmg needs dmgbuild on PATH: pip install dmgbuild" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ARCH="$(uname -m)"

echo "Building Shebang $VERSION ($ARCH)…"
swift build -c release --product ShebangApp
swift build -c release --product shebang
BIN="$(swift build -c release --show-bin-path)"

# Assemble and sign outside the source tree: iCloud-synced folders such as ~/Documents keep adding
# Finder info to bundles, which codesign rejects.
STAGE="$(mktemp -d -t shebang-app)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Shebang.app"
# The CLI lives in Helpers: on case-insensitive volumes MacOS/shebang would overwrite MacOS/Shebang.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ShebangApp" "$APP/Contents/MacOS/Shebang"
cp "$BIN/shebang" "$APP/Contents/Helpers/shebang"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/../.env.example" "$APP/Contents/Resources/env.example"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
    [[ -z "$IDENTITY" ]] && IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Apple Development:/ {print $2; exit}')"
fi

SIGN_FLAGS=(--force --options runtime --entitlements Resources/Shebang.entitlements)
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
    echo "warning: no signing identity found; ad-hoc signing. Re-grant Accessibility after each rebuild." >&2
    IDENTITY="-"
else
    SIGN_FLAGS+=(--timestamp)
    echo "Signing with: $IDENTITY"
fi
# Sign the nested CLI before the bundle that contains it.
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/Helpers/shebang"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/Shebang.app"
ditto --noextattr --norsrc "$APP" "$ROOT/dist/Shebang.app"
echo "Built: $ROOT/dist/Shebang.app"
if ! codesign --verify --strict "$ROOT/dist/Shebang.app" 2>/dev/null; then
    echo "note: this folder adds Finder metadata (iCloud Drive?), so dist/Shebang.app fails strict" \
         "signature checks; --install and --zip use the clean staged copy." >&2
fi

if $ZIP; then
    ARCHIVE="$ROOT/dist/Shebang-v$VERSION-macos-$ARCH.zip"
    rm -f "$ARCHIVE"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
    (cd "$ROOT/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
    echo "Archive: $ARCHIVE"
fi

if $DMG; then
    IMAGE="$ROOT/dist/Shebang-v$VERSION-macos-$ARCH.dmg"
    rm -f "$IMAGE"
    # Retries cover hdiutil detach failing while Spotlight or XProtect still hold the volume.
    dmgbuild -s Scripts/dmg-settings.py -D app="$APP" -D background="$ROOT/Resources/dmg-background.tiff" \
        -D icon="$ROOT/Resources/AppIcon.icns" --detach-retries 10 Shebang "$IMAGE"
    # A disk image carries no ad-hoc signature, so only sign it with a real identity.
    if [[ "$IDENTITY" != "-" ]]; then
        codesign --force --timestamp --sign "$IDENTITY" "$IMAGE"
    fi
    (cd "$ROOT/dist" && shasum -a 256 "$(basename "$IMAGE")" > "$(basename "$IMAGE").sha256")
    echo "Disk image: $IMAGE"
fi

if $INSTALL; then
    DEST="/Applications/Shebang.app"
    osascript -e 'tell application id "com.shebang.mac" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 50); do pgrep -xq Shebang || break; sleep 0.1; done
    if pgrep -xq Shebang; then
        echo "Shebang is still running; quit it and retry." >&2
        exit 1
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed: $DEST"
fi
