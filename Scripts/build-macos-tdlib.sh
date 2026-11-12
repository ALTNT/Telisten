#!/bin/bash
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
source_packages_dir=${TELISTEN_SWIFT_PACKAGES:-/private/tmp/TelistenSwiftPackages}
work_root=${TELISTEN_MAC_TDLIB_BUILD_ROOT:-/private/tmp/TelistenMacTDLib}
jobs=${TELISTEN_TDLIB_JOBS:-4}
minimum_os='13.0'
td_revision='6126ecaea2f3c3d673c89d72b82518101cc6a51d'
openssl_version='3.1.5'
openssl_sha256='6ae015467dabf0469b139ada93319327be24b98251ffaeceda0221848dc09262'
framework="$source_packages_dir/artifacts/tdlibframework/TDLibFramework/TDLibFramework.xcframework/macos-arm64_x86_64/TDLibFramework.framework"
verifier="$project_dir/Scripts/verify-macos-deployment-target.py"

case "$jobs" in
  ''|*[!0-9]*|0) echo 'TELISTEN_TDLIB_JOBS must be a positive integer.' >&2; exit 1 ;;
esac
for tool in cmake git curl make perl python3; do
  command -v "$tool" >/dev/null || { echo "Required build tool is missing: $tool" >&2; exit 1; }
done
if [ ! -f "$framework/Versions/A/TDLibFramework" ]; then
  echo 'Resolve the macOS Swift packages before rebuilding TDLibFramework.' >&2
  exit 1
fi

sdk=$(xcrun --sdk macosx --show-sdk-path)
clang=$(xcrun --find clang)
clangxx=$(xcrun --find clang++)
build_key=$({
  # Bump the recipe when changing compiler options or archive composition.
  printf '%s\n' 'recipe=1' "$td_revision" "$openssl_sha256" "$minimum_os" "$sdk"
  xcodebuild -version
} | shasum -a 256 | cut -c 1-16)
build_dir="$work_root/$build_key"
binary="$build_dir/TDLibFramework"
mkdir -p "$build_dir"
export MACOSX_DEPLOYMENT_TARGET="$minimum_os"
export ZERO_AR_DATE=1
export LC_ALL=C

if [ ! -f "$build_dir/complete" ] || [ ! -f "$binary" ]; then
  td_source="$work_root/td-$td_revision"
  if [ ! -d "$td_source/.git" ]; then
    cached_source="$source_packages_dir/checkouts/TDLibFramework/td"
    if [ "$(git -C "$cached_source" rev-parse HEAD 2>/dev/null || true)" = "$td_revision" ]; then
      git clone --no-hardlinks --no-checkout "$cached_source" "$td_source"
    else
      git init "$td_source"
      git -C "$td_source" remote add origin https://github.com/tdlib/td.git
      git -C "$td_source" fetch --depth 1 origin "$td_revision"
    fi
    git -C "$td_source" checkout --detach "$td_revision"
  fi
  if [ "$(git -C "$td_source" rev-parse HEAD)" != "$td_revision" ] ||
     ! git -C "$td_source" diff --quiet HEAD; then
    echo "TDLib source must match the pinned revision: $td_source" >&2
    exit 1
  fi

  openssl_archive="$work_root/openssl-$openssl_version.tar.gz"
  if [ ! -f "$openssl_archive" ] || ! printf '%s  %s\n' "$openssl_sha256" "$openssl_archive" | shasum -a 256 --check --status; then
    curl --fail --location --silent --show-error \
      "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
      -o "$openssl_archive.download"
    printf '%s  %s\n' "$openssl_sha256" "$openssl_archive.download" | shasum -a 256 --check --status
    mv -f "$openssl_archive.download" "$openssl_archive"
  fi
  for architecture in arm64 x86_64; do
    openssl_source="$build_dir/openssl-$architecture"
    openssl_install="$build_dir/openssl-install-$architecture"
    if [ ! -f "$openssl_install/complete" ]; then
      mkdir -p "$openssl_source"
      tar -xzf "$openssl_archive" -C "$openssl_source" --strip-components=1
      (
        cd "$openssl_source"
        CC="$clang" CFLAGS="-isysroot \"$sdk\" -mmacosx-version-min=$minimum_os" \
          ./Configure "darwin64-$architecture-cc" no-shared no-tests \
          --prefix="$openssl_install" --libdir=lib
        make -j "$jobs"
        make install_sw
      )
      touch "$openssl_install/complete"
    fi
  done
  openssl_install="$build_dir/openssl-universal"
  mkdir -p "$openssl_install/lib"
  # Both 64-bit targets must use the same public OpenSSL configuration.
  diff -qr "$build_dir/openssl-install-arm64/include" "$build_dir/openssl-install-x86_64/include"
  ditto "$build_dir/openssl-install-arm64/include" "$openssl_install/include"
  for library in libcrypto.a libssl.a; do
    xcrun lipo -create \
      "$build_dir/openssl-install-arm64/lib/$library" \
      "$build_dir/openssl-install-x86_64/lib/$library" \
      -output "$openssl_install/lib/$library"
    python3 "$verifier" "$openssl_install/lib/$library" "$minimum_os"
  done

  cmake -S "$td_source" -B "$build_dir/td-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$clang" -DCMAKE_CXX_COMPILER="$clangxx" \
    -DCMAKE_OSX_SYSROOT="$sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum_os" \
    '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
    -DCMAKE_INSTALL_PREFIX="$build_dir/td-install" \
    -DTD_INSTALL_STATIC_LIBRARIES=ON -DTD_INSTALL_SHARED_LIBRARIES=OFF \
    -DOPENSSL_FOUND=TRUE -DOPENSSL_INCLUDE_DIR="$openssl_install/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_install/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$openssl_install/lib/libssl.a" \
    -DZLIB_LIBRARY="$sdk/usr/lib/libz.tbd" -DZLIB_INCLUDE_DIR="$sdk/usr/include" \
    "-DOPENSSL_LIBRARIES=$openssl_install/lib/libssl.a;$openssl_install/lib/libcrypto.a"
  cmake --build "$build_dir/td-build" --target tdjson_static --parallel "$jobs"
  cmake --install "$build_dir/td-build"
  libraries=("$build_dir/td-install/lib/"*.a "$openssl_install/lib/libssl.a" "$openssl_install/lib/libcrypto.a")
  xcrun libtool -static -o "$binary" "${libraries[@]}"
  python3 "$verifier" "$binary" "$minimum_os"
  touch "$build_dir/complete"
fi

python3 "$verifier" "$binary" "$minimum_os"
cp -f "$binary" "$framework/Versions/A/TDLibFramework"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $minimum_os" "$framework/Resources/Info.plist"
# The replaced static archive no longer matches the downloaded signature.
rm -rf "$framework/Versions/A/_CodeSignature" "$framework/_CodeSignature"
echo "Installed TDLibFramework $td_revision for macOS $minimum_os (arm64, x86_64)"
