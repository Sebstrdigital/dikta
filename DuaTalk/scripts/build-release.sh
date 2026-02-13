#!/bin/bash
set -euo pipefail

# ============================================================
# Dua Talk — Build, Sign, Notarize, and Package as DMG
# ============================================================
#
# First-time setup (run once):
#   xcrun notarytool store-credentials "DuaTalk-Notarize" \
#     --apple-id YOUR_APPLE_ID@email.com \
#     --team-id UUM29335B4 \
#     --password YOUR_APP_SPECIFIC_PASSWORD
#
# Generate an app-specific password at:
#   https://appleid.apple.com → Sign-In and Security → App-Specific Passwords
#
# Usage:
#   ./scripts/build-release.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="DuaTalk"
APP_NAME="Dua Talk"
ARCHIVE_PATH="${PROJECT_DIR}/build/DuaTalk.xcarchive"
DMG_PATH="${PROJECT_DIR}/build/DuaTalk.dmg"
NOTARIZE_PROFILE="DuaTalk-Notarize"

SIGNING_IDENTITY="Developer ID Application: Sebastian Strandberg (UUM29335B4)"

# Use /tmp for export/signing to avoid iCloud re-adding extended attributes
# (~/Documents is iCloud-synced; macOS re-adds com.apple.FinderInfo xattrs
#  that cause "resource fork, Finder information, or similar detritus" errors)
WORK_DIR=$(mktemp -d /tmp/DuaTalk-build.XXXXXX)
EXPORT_PATH="${WORK_DIR}/export"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> Cleaning previous build..."
rm -rf "${PROJECT_DIR}/build"
mkdir -p "${PROJECT_DIR}/build"

# Step 1: Archive
echo "==> Archiving ${SCHEME}..."
xcodebuild archive \
    -project "${PROJECT_DIR}/DuaTalk.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    DEVELOPMENT_TEAM=UUM29335B4 \
    CODE_SIGN_STYLE=Manual \
    -quiet

echo "==> Archive complete: ${ARCHIVE_PATH}"

# Step 2: Export the .app from the archive to /tmp (avoids iCloud xattr issues)
echo "==> Exporting app..."
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: App not found at ${APP_PATH}"
    echo "Contents of archive:"
    find "${ARCHIVE_PATH}" -name "*.app" 2>/dev/null
    exit 1
fi

mkdir -p "${EXPORT_PATH}"
cp -R "${APP_PATH}" "${EXPORT_PATH}/${APP_NAME}.app"
APP_EXPORT="${EXPORT_PATH}/${APP_NAME}.app"

# Strip extended attributes that break code signing
# (WhisperKit's swift-transformers_Hub.bundle gets com.apple.FinderInfo xattrs)
echo "==> Stripping extended attributes..."
xattr -cr "${APP_EXPORT}"

# Re-sign after stripping xattrs
echo "==> Signing app..."
codesign --force --deep --options runtime --sign "${SIGNING_IDENTITY}" "${APP_EXPORT}"

# Step 3: Verify code signing
echo "==> Verifying code signature..."
codesign --verify --deep --strict "${APP_EXPORT}"
echo "    Signature valid."

codesign -dv --verbose=2 "${APP_EXPORT}" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"

# Step 4: Notarize
echo "==> Creating zip for notarization..."
NOTARIZE_ZIP="${WORK_DIR}/DuaTalk-notarize.zip"
ditto -c -k --keepParent "${APP_EXPORT}" "${NOTARIZE_ZIP}"

echo "==> Submitting for notarization..."
xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --keychain-profile "${NOTARIZE_PROFILE}" \
    --wait

# Step 5: Staple
echo "==> Stapling notarization ticket..."
xcrun stapler staple "${APP_EXPORT}"

echo "==> Verifying stapled app..."
spctl --assess --type execute --verbose=2 "${APP_EXPORT}"

# Step 6: Create DMG
echo "==> Creating DMG..."
rm -f "${DMG_PATH}"

DMG_STAGING="${WORK_DIR}/dmg-staging"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_EXPORT}" "${DMG_STAGING}/${APP_NAME}.app"
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

# Sign the DMG itself
codesign --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"

# Notarize the DMG too
echo "==> Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARIZE_PROFILE}" \
    --wait

xcrun stapler staple "${DMG_PATH}"

echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "  DMG: ${DMG_PATH}"
echo "  Send this file to your friends!"
echo "============================================================"
