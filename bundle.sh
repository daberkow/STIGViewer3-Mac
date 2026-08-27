#!/bin/bash
set -euxo pipefail

# Vars
ARCH=(x64 arm64)
CATALOG_API='https://www.cyber.mil/webruntime/api/apex/execute?language=en-US&asGuest=true&htmlEncode=false'
SQLITE="https://github.com/TryGhost/node-sqlite3/releases/download/v5.1.7/sqlite3-v5.1.7-napi-v3-darwin-arm64.tar.gz"

# Dependencies
for dep in curl jq unzip tar file python3; do
  command -v "$dep" >/dev/null || { echo "Missing dependency: $dep" >&2; exit 1; }
done


# Process

# Fetch the STIG Viewer 3.x download catalog from cyber.mil
fetch_catalog() {
  curl -sSf --compressed -X POST "$CATALOG_API" \
    -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:154.0) Gecko/20100101 Firefox/154.0' \
    -H 'Accept: */*' \
    -H 'Content-Type: application/json; charset=utf-8' \
    -H 'Referer: https://www.cyber.mil/stigs/srg-stig-tools' \
    -H 'Origin: https://www.cyber.mil' \
    -H 'Cookie: CookieConsentPolicy=0:1; LSKey-c$CookieConsentPolicy=0:1' \
    --data-raw '{"namespace":"","classname":"@udd/01pRw0000002mOj","method":"getCyberDocumentCatalogByDownloadType","isContinuation":false,"params":{"downloadType":"STIG Viewer 3.x"},"cacheable":false}'
}

# Print "<version> <url>" for the newest "STIG Viewer 3.<x>.<y>-Linux" entry
latest_linux() {
  fetch_catalog \
    | jq -r '.returnValue[]
             | select(.FileName | test("^STIG Viewer 3\\.[0-9]+\\.[0-9]+-Linux$"))
             | "\(.FileName | capture("3\\.(?<v>[0-9]+\\.[0-9]+)").v) \(.DownloadLink)"' \
    | sort -V | tail -n1
}

# Get Latest Version
read -r VERSION URL < <(latest_linux)
[[ -n "${URL:-}" ]] || { echo "Could not find a STIG Viewer 3.x Linux download" >&2; exit 1; }
ZIP="stigviewer_latest.zip"
REPO_ROOT="$(pwd)"
# latest_linux() captures only the part after "3.", so 3.8.0 arrives as "8.0".
FULL_VERSION="3.$VERSION"


# Starting file editing process
rm -f ./stigviewer_latest.zip # Just in case
rm -rf ./stig_viewer
rm -rf ./sqlite3
mkdir ./sqlite3

# Download
echo "STIG Viewer $FULL_VERSION -> $URL"
curl -sSfL -o "$ZIP" "$URL"
curl -sSfL -o ./sqlite3.tar.gz "${SQLITE}"


# Extract
unzip "$ZIP" -d ./stig_viewer
tar -xzvf ./sqlite3.tar.gz -C ./sqlite3
cd ./stig_viewer/stig_viewer_3*/resources/
npx --yes @electron/asar@4.3.0 extract app.asar unpacked_stig_viewer/
cd unpacked_stig_viewer
npm install --legacy-peer-deps
# electron-installer-dmg declares appdmg as an "os": "darwin" optionalDependency.
# The lockfile inside the asar was generated on Linux, where npm skipped it, and
# npm will not re-add a skipped optional dep when installing on another platform.
# Install it explicitly so maker-dmg can find it.
if [[ "$(uname)" == "Darwin" ]]; then
  npm install --no-save --legacy-peer-deps appdmg@^0.6.6
  node -e "require.resolve('appdmg')" || {
    echo "appdmg still not resolvable - the dmg maker will fail" >&2
    exit 1
  }
fi

# sqlite3-offline-next ships a working darwin-x64 binary but omits darwin-arm64,
# so only arm64 needs to be supplied here.
SQLITE_DEST="./node_modules/sqlite3-offline-next/binaries/sqlite3-darwin/napi-v3-darwin-arm64"
mkdir -p "$SQLITE_DEST"
cp ../../../../sqlite3/build/Release/node_sqlite3.node "$SQLITE_DEST/"
file "$SQLITE_DEST/node_sqlite3.node" | grep -q 'Mach-O.*arm64' || {
  echo "sqlite3 arm64 binary failed verification - got: $(file "$SQLITE_DEST/node_sqlite3.node")" >&2
  exit 1
}


# Icon
# Upstream ships only .ico art and this repo deliberately holds no binary assets,
# so build the .icns at packaging time. The 256x256 entry inside ag_icon.ico is
# stored as a raw PNG, which makes it a byte-slice away; sips and iconutil are
# both macOS built-ins, so no extra tooling is needed.
ICON_ICNS=""
ICON_SRC="./src/assets/ag_icon.ico"

if [[ "$(uname)" == "Darwin" && -f "$ICON_SRC" ]]; then
  python3 - "$ICON_SRC" ./icon_master.png <<'PYICON'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
_, _, n = struct.unpack('<HHH', d[:6])
best = None
for i in range(n):
    w, h, _c, _r, _p, _b, size, off = struct.unpack('<BBBBHHII', d[6 + i*16 : 22 + i*16])
    w = w or 256
    if d[off:off+4] == b'\x89PNG' and (best is None or w > best[0]):
        best = (w, off, size)
if best is None:
    sys.exit("no PNG-encoded entry found in %s" % src)
open(dst, 'wb').write(d[best[1] : best[1] + best[2]])
print("extracted %dx%d master icon" % (best[0], best[0]))
PYICON

  rm -rf ./icon.iconset
  mkdir ./icon.iconset
  while read -r px name; do
    [[ -n "$px" ]] || continue
    # </dev/null so sips cannot consume the heredoc feeding this loop
    sips -z "$px" "$px" ./icon_master.png --out "./icon.iconset/${name}.png" >/dev/null </dev/null
  done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES

  iconutil -c icns ./icon.iconset -o ./src/assets/icon.icns
  rm -rf ./icon.iconset ./icon_master.png

  [[ -f ./src/assets/icon.icns ]] || { echo "icns generation failed" >&2; exit 1; }
  ICON_ICNS="./src/assets/icon.icns"
else
  echo "No icon source at $ICON_SRC (or not on macOS) - building without a custom icon" >&2
fi

# Package
# Signing is opt-in: SIGN=1 requires a Developer ID Application identity in the
# keychain plus App Store Connect API credentials for notarization. Left unset,
# the build is unsigned and needs no certificate at all.
SIGN_IDENTITY=""
if [[ "${SIGN:-0}" == "1" ]]; then
  # set +x: under xtrace the [[ -n "$VAR" ]] tests would print the expanded
  # credential values into the build log.
  set +x
  for var in APPLE_TEAM_ID ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    [[ -n "${!var:-}" ]] || { echo "SIGN=1 but $var is not set" >&2; exit 1; }
  done
  [[ -f "$ASC_KEY_PATH" ]] || { echo "ASC_KEY_PATH does not exist: $ASC_KEY_PATH" >&2; exit 1; }
  set -x

  # Resolve the identity from the keychain rather than hardcoding a name that
  # changes whenever the certificate is reissued. The identity string is public
  # (it is embedded in every signed binary), so tracing it is fine.
  SIGN_IDENTITY=$(security find-identity -v -p codesigning \
             | grep "Developer ID Application" \
             | grep "$APPLE_TEAM_ID" \
             | head -1 \
             | sed -E 's/.*"(.*)".*/\1/')
  [[ -n "$SIGN_IDENTITY" ]] || {
    echo "No 'Developer ID Application' identity for team $APPLE_TEAM_ID. Available:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
  }
  echo "Signing as: $SIGN_IDENTITY"

  # Electron needs these under the hardened runtime that notarization requires.
  # disable-library-validation is what lets the app load the prebuilt
  # node_sqlite3.node injected above, which carries a different signature.
  cat > ./entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST
fi

# Forge config lives in a JS file rather than package.json for two reasons:
#  - package.json is bundled into the shipped app (it is inside the vendor's
#    app.asar), so anything injected there - like notarization key IDs - would
#    be published with every release. forge.config.js is excluded via
#    packagerConfig.ignore and reads credentials from the environment instead.
#  - Forge falls back to forge.config.js automatically when package.json has no
#    config.forge, which the vendor's "config": {} satisfies, so no sed surgery.
export SIGN SIGN_IDENTITY ICON_ICNS
cat > ./forge.config.js <<'FORGE'
// Generated by bundle.sh. Read by Electron Forge at build time and excluded
// from the packaged app via packagerConfig.ignore, so nothing here ships.
const env = (k) => process.env[k] || '';
const icon = env('ICON_ICNS');

const packagerConfig = {
  name: 'Stig Viewer 3',
  ignore: [/^\/forge\.config\.js$/, /^\/entitlements\.plist$/],
};
if (icon) packagerConfig.icon = icon;

if (env('SIGN') === '1') {
  packagerConfig.osxSign = {
    identity: env('SIGN_IDENTITY'),
    hardenedRuntime: true,
    entitlements: './entitlements.plist',
    'entitlements-inherit': './entitlements.plist',
    'gatekeeper-assess': false,
  };
  // tool: notarytool is mandatory - the legacy altool path these vendored
  // packages default to was decommissioned by Apple in November 2023.
  packagerConfig.osxNotarize = {
    tool: 'notarytool',
    appleApiKey: env('ASC_KEY_PATH'),
    appleApiKeyId: env('ASC_KEY_ID'),
    appleApiIssuer: env('ASC_ISSUER_ID'),
  };
}

module.exports = {
  packagerConfig,
  makers: [
    // maker-dmg treats a missing config.icon as fatal, so only set it when
    // the .icns actually exists.
    { name: '@electron-forge/maker-dmg', ...(icon ? { config: { icon } } : {}) },
    { name: '@electron-forge/maker-zip', platforms: ['darwin'] },
  ],
};
FORGE

# Fail loudly if the config does not load or lacks what the makers need.
node -e "
  const c = require('./forge.config.js');
  if (!c.packagerConfig.name || c.makers.length !== 2) process.exit(1);
  if (process.env.SIGN === '1' && c.packagerConfig.osxNotarize.tool !== 'notarytool') process.exit(1);
" || { echo "forge.config.js failed validation" >&2; exit 1; }


# At ./stig_viewer/stig_viewer_3*/resources/unpacked_stig_viewer/
for single_arch in "${ARCH[@]}"; do
  npm run make -- --platform=darwin --arch=$single_arch
  rm -rf /tmp/electron-packager/
done


# Notarize the disk images themselves. The .app inside is already signed,
# notarized and stapled by electron-packager before the makers run, but a dmg
# carries no ticket of its own until it is submitted separately.
if [[ "${SIGN:-0}" == "1" ]]; then
  while IFS= read -r dmg; do
    echo "Notarizing $dmg"
    set +x  # key-id and issuer would otherwise be traced into the log
    xcrun notarytool submit "$dmg" \
      --key "$ASC_KEY_PATH" \
      --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" \
      --wait </dev/null
    set -x
    xcrun stapler staple "$dmg" </dev/null
    xcrun stapler validate "$dmg" </dev/null
  done < <(find ./out/make -type f -name '*.dmg')
fi

# Collect artifacts
# Forge nests output under out/make/<maker>/darwin/<arch>/, so find them rather
# than globbing a fixed depth, and give each a stable versioned name.
ARTIFACTS="$REPO_ROOT/dist-artifacts"
rm -rf "$ARTIFACTS"
mkdir -p "$ARTIFACTS"

found=0
while IFS= read -r artifact; do
  ext="${artifact##*.}"
  # Recover the arch from the path forge built it under
  arch="unknown"
  for candidate in "${ARCH[@]}"; do
    case "$artifact" in *"/$candidate/"*|*"$candidate."*) arch="$candidate";; esac
  done
  cp "$artifact" "$ARTIFACTS/StigViewer3-${FULL_VERSION}-${arch}.${ext}"
  found=$((found + 1))
done < <(find ./out/make -type f \( -name '*.zip' -o -name '*.dmg' \) )

[[ "$found" -gt 0 ]] || { echo "No artifacts produced under out/make" >&2; exit 1; }

printf '%s\n' "$FULL_VERSION" > "$ARTIFACTS/VERSION"

echo "Built $found artifact(s) for STIG Viewer $FULL_VERSION:"
ls -la "$ARTIFACTS"
