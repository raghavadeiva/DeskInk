#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

# Match the compiler's target SDK on Command Line Tools-only installations.
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

test_arguments=(--disable-sandbox)
testing_plugin="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_plugin" ]]; then
  test_arguments+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi

swift test "${test_arguments[@]}"
