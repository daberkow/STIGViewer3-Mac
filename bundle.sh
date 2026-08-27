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


# Starting file editing process
rm -f ./stigviewer_latest.zip # Just in case
rm -rf ./stig_viewer
rm -rf ./sqlite3
mkdir ./sqlite3

# Download
echo "STIG Viewer 3.$VERSION -> $URL"
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

if [[ -f "$REPO_ROOT/icon.icns" ]]; then
  # A hand-authored icon wins: it carries real artwork at every size, whereas the
  # generated one upscales a 256x256 master. Keep it out of git; drop it in
  # locally, or have CI materialise it before the build.
  echo "Using supplied icon.icns from $REPO_ROOT"
  cp "$REPO_ROOT/icon.icns" ./src/assets/icon.icns
  ICON_ICNS="./src/assets/icon.icns"
elif [[ "$(uname)" == "Darwin" && -f "$ICON_SRC" ]]; then
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
  echo "No icon.icns supplied and no source at $ICON_SRC (or not on macOS) - building without a custom icon" >&2
fi

# Reference the icon only when it exists. maker-dmg treats a missing config.icon
# as fatal, unlike packagerConfig.icon which only warns.
if [[ -n "$ICON_ICNS" ]]; then
  PACKAGER_ICON='
        "icon": "'"$ICON_ICNS"'",'
  DMG_ICON=',
          "config": {
            "icon": "'"$ICON_ICNS"'"
          }'
else
  PACKAGER_ICON=''
  DMG_ICON=''
fi

# Package
# Signing is opt-in: SIGN=1 requires a Developer ID identity in the keychain.
# Left unset, the build is unsigned and runs anywhere without a certificate.
if [[ "${SIGN:-0}" == "1" ]]; then
  OSX_SIGN=',
        "osxSign": {}'
else
  OSX_SIGN=''
fi

REPLACEMENT_TEXT='"config": {
    "forge": {
      "packagerConfig": {'"$PACKAGER_ICON"'
        "name": "Stig Viewer 3"'"$OSX_SIGN"'
      },

      "makers": [
        {
          "name": "@electron-forge/maker-dmg"'"$DMG_ICON"'
        },
        {
          "name": "@electron-forge/maker-zip",
          "platforms": ["darwin"]
        }
      ]
    }
  },'

printf '%s\n' "$REPLACEMENT_TEXT" > ./forge-config.snippet
sed -i.bak -e '/  "config": {},/{
    r ./forge-config.snippet
    d
}' "./package.json"
rm -f ./forge-config.snippet

# Fail loudly if the injection did not take
grep -q '"@electron-forge/maker-dmg"' ./package.json || {
  echo "Forge config injection failed - package.json has no forge config" >&2
  exit 1
}


# At ./stig_viewer/stig_viewer_3*/resources/unpacked_stig_viewer/
for single_arch in "${ARCH[@]}"; do
  npm run make -- --platform=darwin --arch=$single_arch
  rm -rf /tmp/electron-packager/
done


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
  cp "$artifact" "$ARTIFACTS/StigViewer3-3.${VERSION}-${arch}.${ext}"
  found=$((found + 1))
done < <(find ./out/make -type f \( -name '*.zip' -o -name '*.dmg' \) )

[[ "$found" -gt 0 ]] || { echo "No artifacts produced under out/make" >&2; exit 1; }

printf '%s\n' "$VERSION" > "$ARTIFACTS/VERSION"

echo "Built $found artifact(s) for STIG Viewer 3.$VERSION:"
ls -la "$ARTIFACTS"
