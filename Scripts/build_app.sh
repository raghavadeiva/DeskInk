#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-debug}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "Usage: Scripts/build_app.sh [debug|release]"
  exit 2
fi

cd "$project_root"

# SwiftPM normally inherits a matching SDK from Xcode. Some Command Line Tools-only
# installations leave MacOSX.sdk pointing at a newer SDK than the active compiler.
# In that case, prefer the newest SDK matching the compiler's target OS major.
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p 2>/dev/null || true)" == *"CommandLineTools"* ]]; then
  target_major="$(swift --version | sed -nE 's/.*macosx([0-9]+).*/\1/p' | head -1)"
  if [[ -n "$target_major" ]]; then
    matching_sdks=(/Library/Developer/CommandLineTools/SDKs/MacOSX${target_major}*.sdk(N))
    if (( ${#matching_sdks[@]} > 0 )); then
      export SDKROOT="${matching_sdks[-1]}"
    fi
  fi
fi

export CLANG_MODULE_CACHE_PATH="$project_root/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/swiftpm-module-cache"
swift build -c "$configuration" --disable-sandbox

binary_path="$(swift build -c "$configuration" --disable-sandbox --show-bin-path)/DeskInk"
app_path="$project_root/build/DeskInk.app"
contents_path="$app_path/Contents"

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/DeskInk"
cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
git_hash="$(git rev-parse --short=12 HEAD 2>/dev/null || print unknown)"
/usr/libexec/PlistBuddy -c "Set :DeskInkGitCommit $git_hash" "$contents_path/Info.plist"

codesign --force --sign - \
  --entitlements "$project_root/Resources/DeskInk.entitlements" \
  "$app_path"

print "$app_path"
