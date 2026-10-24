#!/bin/bash
# Builds build/SkyMount.app with libssh2 and OpenSSL bundled, so the app runs without Homebrew.
#   SIGN_ID   codesigning identity (default: first "Apple Development" identity, else ad-hoc "-")
#   BUNDLE_ID bundle identifier (default: id.inkpoint.skymount)
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-id.inkpoint.skymount}"
VERSION="0.1.0"
APP="build/SkyMount.app"
BREW="/opt/homebrew/opt"

if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
    SIGN_ID="${SIGN_ID:--}"
fi

# App and Finder extension share a folder through an app group, which must carry the team ID.
TEAM_ID=""
if [ "$SIGN_ID" != "-" ]; then
    TEAM_ID=$(security find-certificate -c "$SIGN_ID" -p | openssl x509 -noout -subject -nameopt multiline \
        | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
fi
APP_GROUP="${TEAM_ID:+$TEAM_ID.}${BUNDLE_ID}"

swift build -c release --product SkyMount
swift build -c release --product SkyMountFinder

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp .build/release/SkyMount "$APP/Contents/MacOS/SkyMount"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Licenses travel with the bundled libssh2 and OpenSSL.
cp LICENSE NOTICE "$APP/Contents/Resources/"
cp -R ThirdPartyLicenses "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>SkyMount</string>
    <key>CFBundleDisplayName</key><string>SkyMount</string>
    <key>CFBundleExecutable</key><string>SkyMount</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal build</string>
    <key>SkyMountAppGroup</key><string>${APP_GROUP}</string>
</dict>
</plist>
PLIST

# Finder Sync extension (badges and the Keep Offline menu).
APPEX="$APP/Contents/PlugIns/SkyMountFinder.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp .build/release/SkyMountFinder "$APPEX/Contents/MacOS/SkyMountFinder"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.finder</string>
    <key>CFBundleName</key><string>SkyMount Finder</string>
    <key>CFBundleDisplayName</key><string>SkyMount</string>
    <key>CFBundleExecutable</key><string>SkyMountFinder</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>SkyMountAppGroup</key><string>${APP_GROUP}</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
        <key>NSExtensionPrincipalClass</key><string>SkyMountFinderSync</string>
        <key>NSExtensionAttributes</key><dict/>
    </dict>
</dict>
</plist>
PLIST

ENT_DIR=$(mktemp -d)
cat > "$ENT_DIR/app.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key><array><string>${APP_GROUP}</string></array>
</dict>
</plist>
PLIST
# Finder only loads sandboxed Finder Sync extensions.
cat > "$ENT_DIR/finder.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key><array><string>${APP_GROUP}</string></array>
</dict>
</plist>
PLIST

# Bundle the Homebrew libraries and point every reference at @rpath.
FW="$APP/Contents/Frameworks"
cp "$BREW/libssh2/lib/libssh2.1.dylib" "$BREW/openssl@3/lib/libssl.3.dylib" "$BREW/openssl@3/lib/libcrypto.3.dylib" "$FW/"
chmod u+w "$FW"/*.dylib

relink() { # file
    for dep in $(otool -L "$1" | awk 'NR>1 {print $1}' | grep -E '^/opt/homebrew/'); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$1" 2>/dev/null
    done
}
for lib in "$FW"/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    relink "$lib"
done
relink "$APP/Contents/MacOS/SkyMount"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SkyMount" 2>/dev/null || true

if otool -L "$APP/Contents/MacOS/SkyMount" "$FW"/*.dylib | grep -q /opt/homebrew/; then
    echo "error: a Homebrew path is still referenced" >&2
    exit 1
fi

# Sign inside-out. Hardened runtime needs every library signed by the same team, so it is only
# enabled with a real identity.
OPTS=()
[ "$SIGN_ID" != "-" ] && OPTS=(--options runtime --timestamp=none)
for lib in "$FW"/*.dylib; do codesign --force "${OPTS[@]}" --sign "$SIGN_ID" "$lib"; done
codesign --force "${OPTS[@]}" --entitlements "$ENT_DIR/finder.entitlements" --sign "$SIGN_ID" "$APPEX"
codesign --force "${OPTS[@]}" --entitlements "$ENT_DIR/app.entitlements" --sign "$SIGN_ID" "$APP"
rm -rf "$ENT_DIR"
codesign --verify --strict --deep --verbose=1 "$APP"

echo "Built $APP (signed with: $SIGN_ID)"
