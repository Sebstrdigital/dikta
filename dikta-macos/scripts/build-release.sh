#!/bin/bash
set -euo pipefail

# ============================================================
# Dikta — Build, Sign, Notarize, and Package as DMG
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
SCHEME="Dikta"
APP_NAME="Dikta"
ARCHIVE_PATH="${PROJECT_DIR}/build/Dikta.xcarchive"
DMG_PATH="${PROJECT_DIR}/build/Dikta.dmg"
NOTARIZE_PROFILE="DuaTalk-Notarize"

SIGNING_IDENTITY="Developer ID Application: Sebastian Strandberg (UUM29335B4)"

# Use /tmp for export/signing to avoid iCloud re-adding extended attributes
# (~/Documents is iCloud-synced; macOS re-adds com.apple.FinderInfo xattrs
#  that cause "resource fork, Finder information, or similar detritus" errors)
WORK_DIR=$(mktemp -d /tmp/Dikta-build.XXXXXX)
EXPORT_PATH="${WORK_DIR}/export"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> Cleaning previous build..."
rm -rf "${PROJECT_DIR}/build"
mkdir -p "${PROJECT_DIR}/build"

# Step 1: Archive
echo "==> Archiving ${SCHEME}..."
xcodebuild archive \
    -project "${PROJECT_DIR}/Dikta.xcodeproj" \
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

# Step 2b: Bundle Whisper small model into the app
WHISPER_MODEL_NAME="openai_whisper-small"
WHISPER_MODEL_SRC="${HOME}/work/artifacts/huggingface/models/argmaxinc/whisperkit-coreml/${WHISPER_MODEL_NAME}"
WHISPER_MODEL_DEST="${APP_EXPORT}/Contents/Resources/WhisperModels/${WHISPER_MODEL_NAME}"

if [ ! -d "${WHISPER_MODEL_SRC}" ]; then
    echo "ERROR: Whisper small model not found at ${WHISPER_MODEL_SRC}"
    echo ""
    echo "Download it first by running the app in dev mode (swift build && .build/debug/Dikta)"
    echo "or manually download from HuggingFace:"
    echo "  huggingface-cli download argmaxinc/whisperkit-coreml openai_whisper-small --local-dir ~/work/artifacts/huggingface/models/argmaxinc/whisperkit-coreml"
    exit 1
fi

echo "==> Bundling Whisper small model..."
mkdir -p "$(dirname "${WHISPER_MODEL_DEST}")"
cp -R "${WHISPER_MODEL_SRC}" "${WHISPER_MODEL_DEST}"
echo "    Model bundled ($(du -sh "${WHISPER_MODEL_DEST}" | cut -f1) total)"

# Strip extended attributes that break code signing
# (WhisperKit's swift-transformers_Hub.bundle gets com.apple.FinderInfo xattrs)
echo "==> Stripping extended attributes..."
xattr -cr "${APP_EXPORT}"

# Re-sign after stripping xattrs
# Sign inside-out: frameworks/helpers first, then the main app bundle.
# --deep is unreliable for nested frameworks; sign each component explicitly.
ENTITLEMENTS="${PROJECT_DIR}/Dikta/Resources/Dikta.entitlements"
echo "==> Signing app..."

# Sign all nested Mach-O binaries, bundles, and frameworks inside Frameworks/ (deepest first)
# This covers Sparkle's Autoupdate helper, XPC services, sub-frameworks, etc.
find "${APP_EXPORT}/Contents/Frameworks" -type f -perm +111 | while read -r binary; do
    # Only sign Mach-O binaries (skip scripts, plists, etc.)
    if file "${binary}" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${binary}"
    fi
done

# Sign Sparkle XPC services with their required entitlements
# Downloader.xpc needs sandbox + network.client to download updates
DOWNLOADER_XPC="${APP_EXPORT}/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
if [ -d "${DOWNLOADER_XPC}" ]; then
    DOWNLOADER_ENTITLEMENTS="${WORK_DIR}/Downloader.entitlements"
    cat > "${DOWNLOADER_ENTITLEMENTS}" << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTEOF
    codesign --force --options runtime --timestamp --entitlements "${DOWNLOADER_ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" "${DOWNLOADER_XPC}"
fi

# Sign remaining framework/bundle directories (inside-out)
find "${APP_EXPORT}/Contents/Frameworks" -depth \
    \( -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.bundle" \) \
    ! -path "*/Downloader.xpc" | while read -r component; do
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${component}"
done

# Sign the main app bundle last
codesign --force --options runtime --timestamp --entitlements "${ENTITLEMENTS}" --sign "${SIGNING_IDENTITY}" "${APP_EXPORT}"

# Step 3: Verify code signing
echo "==> Verifying code signature..."
codesign --verify --deep --strict "${APP_EXPORT}"
echo "    Signature valid."

codesign -dv --verbose=2 "${APP_EXPORT}" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier"

# Step 4: Notarize
echo "==> Creating zip for notarization..."
NOTARIZE_ZIP="${WORK_DIR}/Dikta-notarize.zip"
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
echo "============================================================"

# ============================================================
# Step 7: Appcast + GitHub Release (Sparkle auto-update)
# ============================================================
#
# Prerequisites:
#   - gh CLI authenticated: gh auth login
#   - Sparkle private key at ~/.dikta-sparkle-key
#     (generated with: sparkle_bin/generate_keys)
#   - GitHub Pages enabled on the repo (docs/ folder on main)
#
# The appcast.xml is written to docs/appcast.xml and committed
# to main. Sparkle checks this URL for updates.
# ============================================================

# Locate Sparkle's sign_update tool (resolved from the Xcode SPM cache)
SPARKLE_BIN=""
if SPARKLE_CHECKOUT=$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
        -name "sign_update" 2>/dev/null | head -1); then
    SPARKLE_BIN="$(dirname "${SPARKLE_CHECKOUT}")"
fi
if [ -z "${SPARKLE_BIN}" ]; then
    # Fallback: look in SPM global cache
    SPARKLE_BIN_PATH=$(find "${HOME}/.spm/checkouts" \
        -name "sign_update" 2>/dev/null | head -1)
    [ -n "${SPARKLE_BIN_PATH}" ] && SPARKLE_BIN="$(dirname "${SPARKLE_BIN_PATH}")"
fi

if [ -z "${SPARKLE_BIN}" ]; then
    echo "WARN: sign_update not found — skipping appcast generation."
    echo "      Build and open the project in Xcode once to resolve Sparkle, then re-run."
    exit 0
fi

# Read version from the built app
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    "${APP_EXPORT}/Contents/Info.plist")
APP_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" \
    "${APP_EXPORT}/Contents/Info.plist")

PRIVATE_KEY="${HOME}/.dikta-sparkle-key"
if [ ! -f "${PRIVATE_KEY}" ]; then
    echo "ERROR: Sparkle private key not found at ${PRIVATE_KEY}"
    echo "       Generate one with: ${SPARKLE_BIN}/generate_keys"
    exit 1
fi

# Guard: abort if Info.plist still has the placeholder EdDSA key
EMBEDDED_KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "${APP_EXPORT}/Contents/Info.plist" 2>/dev/null || echo "")
if [ "${EMBEDDED_KEY}" = "PLACEHOLDER_EDKEY_REPLACE_BEFORE_RELEASE" ] || [ -z "${EMBEDDED_KEY}" ]; then
    echo "ERROR: SUPublicEDKey in Info.plist is still the placeholder value."
    echo "       Replace it with the real EdDSA public key before building a release."
    echo "       Generate the key: ${SPARKLE_BIN}/generate_keys"
    exit 1
fi

# GitHub repo (owner/name)
GITHUB_REPO="Sebstrdigital/dikta"
RELEASE_TAG="v${APP_VERSION}"
DMG_FILENAME="Dikta-${APP_VERSION}.dmg"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${DMG_FILENAME}"

# Copy DMG to release-named file
RELEASE_DMG="${PROJECT_DIR}/build/${DMG_FILENAME}"
cp "${DMG_PATH}" "${RELEASE_DMG}"

# Generate EdDSA signature
echo "==> Signing DMG with EdDSA..."
EDDSA_SIG=$("${SPARKLE_BIN}/sign_update" --ed-key-file "${PRIVATE_KEY}" "${RELEASE_DMG}" | \
    grep -E 'sparkle:edSignature' | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/')

if [ -z "${EDDSA_SIG}" ]; then
    echo "ERROR: Failed to generate EdDSA signature"
    exit 1
fi
echo "    Signature: ${EDDSA_SIG}"

DMG_SIZE=$(stat -f%z "${RELEASE_DMG}")
BUILD_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Generate/update appcast.xml in docs/
# Preserves existing <item> entries so users on older versions can still update.
DOCS_DIR="${PROJECT_DIR}/../docs"
mkdir -p "${DOCS_DIR}"
APPCAST_PATH="${DOCS_DIR}/appcast.xml"

# Build the new <item> block
NEW_ITEM="        <item>
            <title>Dikta ${APP_VERSION}</title>
            <pubDate>${BUILD_DATE}</pubDate>
            <sparkle:version>${APP_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${APP_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url=\"${DOWNLOAD_URL}\"
                sparkle:edSignature=\"${EDDSA_SIG}\"
                length=\"${DMG_SIZE}\"
                type=\"application/octet-stream\"
            />
        </item>"

if [ -f "${APPCAST_PATH}" ] && grep -q '<item>' "${APPCAST_PATH}" 2>/dev/null; then
    # Appcast already has entries — insert new item before first existing <item>
    # Use Python for reliable XML-safe insertion (available on macOS by default)
    python3 - "${APPCAST_PATH}" "${NEW_ITEM}" << 'PYEOF'
import sys, re

appcast_path = sys.argv[1]
new_item = sys.argv[2]

with open(appcast_path, 'r') as f:
    content = f.read()

# Insert new item before the first existing <item>
content = content.replace('<item>', new_item + '\n        <item>', 1)

with open(appcast_path, 'w') as f:
    f.write(content)
PYEOF
else
    # No existing appcast or no items yet — write a fresh one
    cat > "${APPCAST_PATH}" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Dikta Changelog</title>
        <link>https://sebstrdigital.github.io/dikta/appcast.xml</link>
        <description>Dikta app updates</description>
        <language>en</language>
${NEW_ITEM}
    </channel>
</rss>
APPCAST_EOF
fi

echo "==> Appcast written: ${APPCAST_PATH}"

# Commit and push appcast.xml to main (GitHub Pages serves from docs/)
git -C "${PROJECT_DIR}/.." add docs/appcast.xml
git -C "${PROJECT_DIR}/.." commit -m "chore: update appcast for v${APP_VERSION}"
git -C "${PROJECT_DIR}/.." push origin main
echo "==> Appcast pushed to main (GitHub Pages)"

# Create GitHub Release with DMG attached (delete existing if re-releasing same version)
echo "==> Creating GitHub Release ${RELEASE_TAG}..."
if gh release view "${RELEASE_TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo "    Replacing existing release ${RELEASE_TAG}..."
    gh release delete "${RELEASE_TAG}" --repo "${GITHUB_REPO}" --yes
fi
gh release create "${RELEASE_TAG}" \
    "${RELEASE_DMG}#Dikta ${APP_VERSION} (DMG)" \
    --repo "${GITHUB_REPO}" \
    --title "Dikta v${APP_VERSION}" \
    --notes "Dikta v${APP_VERSION}" \
    --latest

echo ""
echo "============================================================"
echo "  RELEASE COMPLETE"
echo "  Version: ${APP_VERSION}"
echo "  DMG:     ${RELEASE_DMG}"
echo "  Tag:     ${RELEASE_TAG}"
echo "  Appcast: https://sebstrdigital.github.io/dikta/appcast.xml"
echo "============================================================"
