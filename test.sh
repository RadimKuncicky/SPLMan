#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swiftpm-cache"
swift run --disable-sandbox SPLMan --self-test
