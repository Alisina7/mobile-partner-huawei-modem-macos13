#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/Mobile Partner.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="x86_64-apple-macos13.0"

echo "==> Cleaning build directory"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$BUILD/pkg" "$BUILD/stage" "$BUILD/dmg"

echo "==> Copying resources"
cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "resources/MBBActivateApp" "$APP/Contents/Resources/MBBActivateApp"
chmod 755 "$APP/Contents/Resources/MBBActivateApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Mobile Partner</string>
	<key>CFBundleExecutable</key>
	<string>Mobile Partner</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.mobilepartner.replacement</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Mobile Partner</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSQuitAlwaysKeepsWindows</key>
	<false/>
	<key>NSHumanReadableCopyright</key>
	<string>Native replacement for Huawei Mobile Partner. For the E1550 3G modem.</string>
</dict>
</plist>
PLIST

echo "==> Building app"
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 \
    -target "$TARGET" -sdk "$SDK" \
    -framework SwiftUI -framework AppKit -framework Foundation \
    -framework IOKit -framework SystemConfiguration \
    "$ROOT/src/ATSerial.swift" \
    "$ROOT/src/HardwareProbe.swift" \
    "$ROOT/src/Telemetry.swift" \
    "$ROOT/src/HelperClient.swift" \
    "$ROOT/src/ModemModel.swift" \
    "$ROOT/src/Views.swift" \
    "$ROOT/src/App.swift" \
    -o "$APP/Contents/MacOS/Mobile Partner"

echo "==> Signing app (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> Building privileged helper"
mkdir -p "$BUILD/helper"
xcrun swiftc -O -swift-version 5 -target "$TARGET" -sdk "$SDK" \
    -framework Foundation -framework SystemConfiguration \
    "$ROOT/src/Helper/main.swift" \
    -o "$BUILD/helper/mphelper"
chmod 755 "$BUILD/helper/mphelper"
codesign --force --sign - "$BUILD/helper/mphelper"

echo "==> Staging package payload"
mkdir -p "$BUILD/stage/Applications"
mkdir -p "$BUILD/stage/Library/Extensions"
mkdir -p "$BUILD/stage/Library/LaunchDaemons"
mkdir -p "$BUILD/stage/Library/Modem Scripts"
mkdir -p "$BUILD/stage/usr/local/mobilepartner"

cp -R "$APP" "$BUILD/stage/Applications/"
cp -R "payloads/driver/HuaweiDataCardDriver_10_9.kext" "$BUILD/stage/Library/Extensions/"
cp "payload/Library/LaunchDaemons/com.mobilepartner.helper.plist" \
   "$BUILD/stage/Library/LaunchDaemons/com.mobilepartner.helper.plist"
cp "payloads/modem-script/HUAWEI Mobile Connect - 3G Modem" \
   "$BUILD/stage/Library/Modem Scripts/HUAWEI Mobile Connect - 3G Modem"
cp "$BUILD/helper/mphelper" "$BUILD/stage/usr/local/mobilepartner/mphelper"
cp "resources/MBBActivateApp" "$BUILD/stage/usr/local/mobilepartner/MBBActivateApp"
chmod 755 "$BUILD/stage/usr/local/mobilepartner/MBBActivateApp"

chmod 755 "$ROOT/scripts/preinstall" "$ROOT/scripts/postinstall"

echo "==> Building component package"
pkgbuild \
    --root "$BUILD/stage" \
    --identifier "com.mobilepartner.replacement.pkg" \
    --version "1.0" \
    --scripts "$ROOT/scripts" \
    --install-location "/" \
    --ownership recommended \
    "$BUILD/pkg/MobilePartner.pkg"

# Stop PackageKit from "relocating" the app to a previously launched copy
# (for example the build folder) instead of installing it into /Applications.
echo "==> Disabling bundle relocation for the app"
rm -rf "$BUILD/pkg-expanded"
pkgutil --expand "$BUILD/pkg/MobilePartner.pkg" "$BUILD/pkg-expanded"
python3 - "$BUILD/pkg-expanded/PackageInfo" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = re.sub(r"[ \t]*<relocate>.*?</relocate>\s*", "", text, flags=re.S)
text = re.sub(r"[ \t]*<upgrade-bundle>.*?</upgrade-bundle>\s*", "", text, flags=re.S)
open(path, "w", encoding="utf-8").write(text)
PY
pkgutil --flatten "$BUILD/pkg-expanded" "$BUILD/pkg/MobilePartner.pkg"
rm -rf "$BUILD/pkg-expanded"

echo "==> Building installer package"
productbuild \
    --distribution "$ROOT/installer/Distribution.xml" \
    --package-path "$BUILD/pkg" \
    --resources "$ROOT/installer" \
    "$BUILD/Install Mobile Partner.pkg"

cp "$ROOT/README.md" "$BUILD/dmg/Read Me.md"
cp "$ROOT/Uninstall Mobile Partner.command" "$BUILD/dmg/Uninstall Mobile Partner.command"
chmod 755 "$BUILD/dmg/Uninstall Mobile Partner.command"
cp "$BUILD/Install Mobile Partner.pkg" "$BUILD/dmg/Install Mobile Partner.pkg"

echo "==> Creating disk image"
hdiutil create -volname "Mobile Partner" -srcfolder "$BUILD/dmg" \
    -ov -format UDZO "$BUILD/Mobile Partner.dmg" >/dev/null

echo ""
echo "Done."
echo "  App:       $APP"
echo "  Installer: $BUILD/Install Mobile Partner.pkg"
echo "  Disk image: $BUILD/Mobile Partner.dmg"
