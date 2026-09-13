#!/bin/bash
set -e

APP_NAME="OppoPodsManager"
BUILD_DIR="bin/Release/net10.0/osx-x64/publish"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo "=== Building ${APP_NAME} for macOS x64 ==="

# 编译 IOBluetooth RFCOMM 助手（供 MacHelperRfcommTransport 拉起），需先完成
# dotnet publish -c Release -r osx-x64 --self-contained true -o "${BUILD_DIR}"
echo "[0/3] Building OppodsRfcommHelper..."
CLANG="${CC:-$(xcrun --find clang)}"
SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
"$CLANG" -fobjc-arc -isysroot "$SDKROOT" \
  -framework Foundation -framework IOBluetooth -lc++ -O2 \
  -sectcreate __TEXT __info_plist Transport/macOS/RfcommHelper/Info.plist \
  -o "${BUILD_DIR}/OppodsRfcommHelper" \
  Transport/macOS/RfcommHelper/main.mm

# Create .app bundle structure
echo "[1/3] Creating .app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy ALL files from publish directory
cp -R "${BUILD_DIR}"/* "${APP_DIR}/Contents/MacOS/"

# Create Info.plist
echo "[2/3] Creating Info.plist..."
cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OppoPodsManager</string>
    <key>CFBundleDisplayName</key>
    <string>OPPO Pods Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.oppo.podsmanager</string>
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0-macos</string>
    <key>CFBundleExecutable</key>
    <string>OppoPodsManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>OPPO Pods Manager needs Bluetooth to connect to your earbuds.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>OPPO Pods Manager needs Bluetooth to connect to your earbuds.</string>
    <key>CFBundleIconFile</key>
    <string>tuopan</string>
</dict>
</plist>
PLIST

# Ad-hoc sign
echo "[3/3] Ad-hoc signing..."
codesign --force --deep --sign - "${APP_DIR}"

echo "Build complete: ${APP_DIR}"
