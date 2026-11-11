#!/bin/sh
set -euo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_root=${TELISTEN_MAC_TMP_ROOT:-/private/tmp/TelistenMacTmp}
build_root=${TELISTEN_MAC_BUILD_ROOT:-/private/tmp/TelistenMacBuild}
source_packages_dir=${TELISTEN_SWIFT_PACKAGES:-/private/tmp/TelistenSwiftPackages}
dmg_work_dir=${TELISTEN_MAC_DMG_WORK_DIR:-/private/tmp/TelistenMacDmg}
framework_zip=${TELISTEN_FRAMEWORK_ZIP:-/private/tmp/TDLibFramework.zip}
build_log=${TELISTEN_MAC_BUILD_LOG:-/private/tmp/Telisten-macOS-13.0-build.log}
code_signing_allowed=${TELISTEN_CODE_SIGNING_ALLOWED:-YES}
allow_provisioning_updates=${TELISTEN_ALLOW_PROVISIONING_UPDATES:-YES}
minimum_os='13.0'
framework_url='https://github.com/Swiftgram/TDLibFramework/releases/download/1.8.69-6126ecae/TDLibFramework.zip'
framework_sha256='97c34692d08d1bde70e73c97d2ac6afae1c0009416018509c78a7d939ebdc00c'
framework_artifacts_dir="$source_packages_dir/artifacts/tdlibframework/TDLibFramework"
framework_bundle="$framework_artifacts_dir/TDLibFramework.xcframework"
app="$build_root/Products/Release/Telisten.app"
dmg="${TELISTEN_MAC_DMG:-$project_dir/Telisten-macOS-13.0.dmg}"

case "$code_signing_allowed" in
  YES|NO) ;;
  *) echo 'TELISTEN_CODE_SIGNING_ALLOWED must be YES or NO.' >&2; exit 1 ;;
esac
case "$allow_provisioning_updates" in
  YES|NO) ;;
  *) echo 'TELISTEN_ALLOW_PROVISIONING_UPDATES must be YES or NO.' >&2; exit 1 ;;
esac

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

if [ ! -d "$framework_bundle/macos-arm64_x86_64/TDLibFramework.framework" ]; then
  mkdir -p "$framework_artifacts_dir"
  unzip -q -o "$framework_zip" -d "$framework_artifacts_dir"
fi
if [ ! -d "$framework_bundle/macos-arm64_x86_64/TDLibFramework.framework" ]; then
  echo "TDLibFramework macOS universal slice is missing from $framework_bundle" >&2
  exit 1
fi

cd "$project_dir"
echo "Building Telisten-macOS Release with minimum macOS $minimum_os"
echo "Code signing allowed: $code_signing_allowed"
echo "Allow provisioning updates: $allow_provisioning_updates"
set --
if [ "$allow_provisioning_updates" = 'YES' ]; then
  set -- -allowProvisioningUpdates
fi
xcodebuild "$@" \
  -project Telisten.xcodeproj \
  -target Telisten-macOS \
  -configuration Release \
  -sdk macosx \
  -clonedSourcePackagesDirPath "$source_packages_dir" \
  SYMROOT="$build_root/Products" \
  OBJROOT="$build_root/Intermediates" \
  MACOSX_DEPLOYMENT_TARGET="$minimum_os" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED="$code_signing_allowed" \
  build 2>&1 | tee "$build_log"

if [ ! -d "$app" ]; then
  echo "Build did not produce $app" >&2
  exit 1
fi

minimum_os_in_app=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
architectures=$(lipo -archs "$app/Contents/MacOS/Telisten")
if [ "$minimum_os_in_app" != "$minimum_os" ]; then
  echo "Expected LSMinimumSystemVersion $minimum_os, got $minimum_os_in_app" >&2
  exit 1
fi
case " $architectures " in
  *' arm64 '*) ;;
  *) echo "Expected arm64 app binary, got: $architectures" >&2; exit 1 ;;
esac
case " $architectures " in
  *' x86_64 '*) ;;
  *) echo "Expected x86_64 app binary, got: $architectures" >&2; exit 1 ;;
esac

if [ "$code_signing_allowed" = 'YES' ]; then
  codesign --verify --deep --strict "$app"
  signing_details=$(codesign -dv --verbose=4 "$app" 2>&1)
  case "$signing_details" in
    *'Signature=adhoc'*|*'TeamIdentifier=not set'*)
      echo 'The app is not team-signed; Keychain access may fail.' >&2
      exit 1
      ;;
  esac
else
  echo 'Warning: this unsigned build may not be able to save Telegram sessions in Keychain.' >&2
fi

if grep -q "built for newer 'macOS' version" "$build_log"; then
  echo 'Warning: a linked framework contains object files built for a newer macOS version; compatibility with macOS 13 is not guaranteed.' >&2
fi

rm -rf "$dmg_work_dir"
mkdir -p "$dmg_work_dir/Stage"
ditto "$app" "$dmg_work_dir/Stage/Telisten.app"
hdiutil create -quiet -volname Telisten -srcfolder "$dmg_work_dir/Stage" -format UDZO "$dmg_work_dir/Telisten-macOS-13.0.dmg"
hdiutil verify -quiet "$dmg_work_dir/Telisten-macOS-13.0.dmg"
mv -f "$dmg_work_dir/Telisten-macOS-13.0.dmg" "$dmg"

echo "Created $dmg"
echo "Minimum macOS: $minimum_os_in_app"
echo "Architectures: $architectures"
ls -lh "$dmg"
