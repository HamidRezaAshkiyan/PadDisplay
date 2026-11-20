#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="PadDisplay"
APP_BUNDLE="${ROOT_DIR}/build/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "==> Building ${APP_NAME} (${CONFIG})..."
cd "${ROOT_DIR}"
swift build -c "${CONFIG}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/${APP_NAME}"
RESOURCE_BUNDLE="${BIN_DIR}/PadDisplay_PadDisplayCore.bundle"

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${EXECUTABLE}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${RESOURCES_DIR}/"
fi

if [[ -f "${ROOT_DIR}/Assets/AppIcon.icns" ]]; then
    cp "${ROOT_DIR}/Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat > "${CONTENTS}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PadDisplay</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.paddisplay.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PadDisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>PadDisplay needs Screen Recording permission to capture the virtual display and stream it to your iPad.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>PadDisplay streams the virtual display over your local Wi-Fi or USB network to iPad Safari.</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc code signing ${APP_BUNDLE}..."
codesign --force --deep --sign - --identifier "com.paddisplay.app" "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Done! Launch with:"
echo "    open \"${APP_BUNDLE}\""
