#!/bin/sh
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_root=${TELISTEN_TMP_ROOT:-/private/tmp/TelistenTmp}
build_root=${TELISTEN_BUILD_ROOT:-/private/tmp/TelistenBuild}
source_packages_dir=${TELISTEN_SWIFT_PACKAGES:-/private/tmp/TelistenSwiftPackages}
tipa_work_dir=${TELISTEN_TIPA_WORK_DIR:-/private/tmp/TelistenTipa}
framework_zip=${TELISTEN_FRAMEWORK_ZIP:-/private/tmp/TDLibFramework.zip}
build_log=${TELISTEN_BUILD_LOG:-/private/tmp/Telisten-iOS-16.3-build.log}
framework_url='https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.69-6126ecae/TDLibFramework.zip'
framework_sha256='97c34692d08d1bde70e73c97d2ac6afae1c0009416018509c78a7d939ebdc00c'
framework_artifacts_dir="$source_packages_dir/artifacts/tdlibframework/TDLibFramework"
framework_bundle="$framework_artifacts_dir/TDLibFramework.xcframework"
app="$build_root/Products/Release-iphoneos/Telisten.app"
tipa="$project_dir/Telisten-iOS-16.3.tipa"

mkdir -p "$tmp_root" "$source_packages_dir" "$build_root/Products" "$build_root/Intermediates"
chmod 700 "$tmp_root"
export TMPDIR="$tmp_root"

if [ -f "$project_dir/.env" ] || { [ -n "${TELEGRAM_API_ID:-}" ] && [ -n "${TELEGRAM_API_HASH:-}" ]; }; then
  "$project_dir/Scripts/generate-local-config.sh"
elif [ ! -f "$project_dir/.local/Telegram.xcconfig" ]; then
  echo 'Missing Telegram credentials. Set TELEGRAM_API_ID and TELEGRAM_API_HASH, or create .env first.' >&2
  exit 1
fi

if [ ! -f "$framework_zip" ] || ! printf '%s  %s\n' "$framework_sha256" "$framework_zip" | shasum -a 256 --check --status; then
  echo "Downloading TDLibFramework to $framework_zip"
  curl --fail --location --silent --show-error "$framework_url" -o "$framework_zip.download"
  printf '%s  %s\n' "$framework_sha256" "$framework_zip.download" | shasum -a 256 --check --status
  mv -f "$framework_zip.download" "$framework_zip"
fi

if [ ! -d "$framework_bundle" ]; then
  mkdir -p "$framework_artifacts_dir"
  unzip -q -o "$framework_zip" -d "$framework_artifacts_dir"
fi
if [ ! -d "$framework_bundle/ios-arm64/TDLibFramework.framework" ]; then
  echo "TDLibFramework iOS arm64 slice is missing from $framework_bundle" >&2
  exit 1
fi

cd "$project_dir"
echo "Building Telisten-iOS with Xcode 16.2 / iOS 18.2 SDK"
xcodebuild \
  -project Telisten.xcodeproj \
  -target Telisten-iOS \
  -configuration Release \
  -sdk iphoneos18.2 \
  -clonedSourcePackagesDirPath "$source_packages_dir" \
  SYMROOT="$build_root/Products" \
  OBJROOT="$build_root/Intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$build_log"

if [ ! -d "$app" ]; then
  echo "Build did not produce $app" >&2
  exit 1
fi
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")
architectures=$(lipo -archs "$app/Telisten")
if [ "$minimum_os" != '16.3' ]; then
  echo "Expected MinimumOSVersion 16.3, got $minimum_os" >&2
  exit 1
fi
case " $architectures " in
  *' arm64 '*) ;;
  *) echo "Expected arm64 app binary, got: $architectures" >&2; exit 1 ;;
esac

rm -rf "$tipa_work_dir"
mkdir -p "$tipa_work_dir/Payload"
ditto "$app" "$tipa_work_dir/Payload/Telisten.app"
ditto -c -k --sequesterRsrc --keepParent \
  "$tipa_work_dir/Payload" \
  "$tipa_work_dir/Telisten-iOS-16.3.tipa.zip"
mv -f "$tipa_work_dir/Telisten-iOS-16.3.tipa.zip" "$tipa"
unzip -tqq "$tipa"

echo "Created $tipa"
echo "Minimum iOS: $minimum_os"
echo "Architectures: $architectures"
ls -lh "$tipa"
