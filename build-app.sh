#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-cache"
swift build -c release --disable-sandbox -debug-info-format none

APP_DIR="dist/SPLMan.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/SPLMan" "$APP_DIR/Contents/MacOS/SPLMan"
cp "Resources/SPLMan.icns" "$APP_DIR/Contents/Resources/SPLMan.icns"
RESOURCE_BUNDLE=".build/release/SPLMan_SPLMan.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
rm -rf "$APP_DIR/Contents/Resources/SPLMan_SPLMan.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
for LOCALIZATION in Sources/SPLMan/Resources/*.lproj; do
    cp -R "$LOCALIZATION" "$APP_DIR/Contents/Resources/"
done

PLIST="$APP_DIR/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleExecutable -string SPLMan "$PLIST"
plutil -insert CFBundleIdentifier -string cz.splman.app "$PLIST"
plutil -insert CFBundleName -string "SPL Man" "$PLIST"
plutil -insert CFBundleDisplayName -string "SPL Man" "$PLIST"
plutil -insert CFBundleIconFile -string SPLMan.icns "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$PLIST"
plutil -insert CFBundleShortVersionString -string 0.1.0 "$PLIST"
plutil -insert CFBundleVersion -string 1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string en "$PLIST"
plutil -insert LSMinimumSystemVersion -string 13.0 "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
plutil -insert NSPrincipalClass -string NSApplication "$PLIST"
plutil -insert LSApplicationCategoryType -string public.app-category.utilities "$PLIST"
plutil -insert NSMicrophoneUsageDescription -string "SPL Man needs audio input access to measure sound pressure levels." "$PLIST"

codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
