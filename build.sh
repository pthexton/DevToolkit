#!/bin/bash
# Build DevToolkit.app into ./build.
#
# Auto-selects whichever local "Apple Development" identity belongs to the
# BeyondTrust team (OU 2ZS8T6NYB8) and signs the binary with it. Override the
# auto-selection with SIGN_IDENTITY=<name-or-sha1>.
set -euo pipefail

cd "$(dirname "$0")"

TEAM_OU="${TEAM_OU:-2ZS8T6NYB8}"
APP_ID="com.beyondtrust.devtoolkit"

# Find an Apple Development identity whose certificate OU == $TEAM_OU.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    echo "==> Looking for an Apple Development identity in team $TEAM_OU"
    while IFS= read -r line; do
        hash=$(printf '%s\n' "$line" | awk '{print $2}')
        name=$(printf '%s\n' "$line" | sed -E 's/^[^"]*"([^"]*)".*/\1/')
        case "$name" in "Apple Development:"*) ;; *) continue ;; esac
        ou=$(security find-certificate -c "$name" -p 2>/dev/null \
             | openssl x509 -noout -subject -nameopt sep_multiline,utf8 2>/dev/null \
             | sed -n 's/^[[:space:]]*OU=//p' | head -1)
        if [ "$ou" = "$TEAM_OU" ]; then
            SIGN_IDENTITY="$hash"; SIGN_NAME="$name"; break
        fi
    done < <(security find-identity -v -p codesigning | grep '"Apple Development:')

    if [ -z "${SIGN_IDENTITY:-}" ]; then
        echo "error: no 'Apple Development' identity found for team OU $TEAM_OU." >&2
        echo "       Install your BeyondTrust Apple Development cert, or pass SIGN_IDENTITY=…" >&2
        exit 1
    fi
    echo "    using: ${SIGN_NAME:-?}  [$SIGN_IDENTITY]"
fi

BUILD_DIR="build"
APP="$BUILD_DIR/DevToolkit.app"
MACOS="$APP/Contents/MacOS"

echo "==> swift build (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

cp "$BIN_DIR/DevToolkitApp"      "$MACOS/DevToolkitApp"
cp Packaging/Info.plist          "$APP/Contents/Info.plist"
# Bundled LaunchAgent for SMAppService self-registration (sealed by signing).
cp Packaging/LaunchAgent.plist   "$APP/Contents/Library/LaunchAgents/com.beyondtrust.devtoolkit.plist"

echo "==> Codesigning (identity: $SIGN_IDENTITY)"
codesign --force --options runtime --timestamp=none \
    --identifier "$APP_ID" \
    --entitlements Packaging/DevToolkit.entitlements \
    --sign "$SIGN_IDENTITY" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --strict --deep "$APP"
echo "--- signing cert team (must be $TEAM_OU on every teammate's build):"
codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=/    TeamIdentifier=/p'

echo "==> Done: $APP"
