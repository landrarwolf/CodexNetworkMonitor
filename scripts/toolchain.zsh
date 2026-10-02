TASK_SWIFT="$(xcrun --find swift)"
TASK_SWIFT_VERSION="$("$TASK_SWIFT" --version)"
if [[ ! "$TASK_SWIFT_VERSION" =~ 'Swift version ([0-9]+)' ]] || (( match[1] < 6 )); then
    print -u2 -- 'Swift 6 or newer is required (including Swift Testing). Select a recent Xcode or Command Line Tools toolchain.'
    exit 1
fi
export CLANG_MODULE_CACHE_PATH="$TASK_SCRATCH/clang-modules"
export SWIFT_MODULECACHE_PATH="$TASK_SCRATCH/swift-modules"
