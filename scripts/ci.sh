#!/usr/bin/env bash
# The CI gate. Runs on a Mac with Xcode 16+ and XcodeGen (`brew install xcodegen`).
#
#   scripts/ci.sh                    unit tests on an iPhone simulator, then a Release build
#   APP=hope-tv scripts/ci.sh        the same for another shell in Config/Shells/
#   SIMULATOR="iPhone 16" scripts/ci.sh
#
# The unit tests are offline: they read fixtures/app-contract, never the network, so an empty
# ClientToken is enough. Exit code 0 means every step passed.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

app="${APP:-hope-tv-deutsch-tv-app}"
shell_file="Config/Shells/$app.xcconfig"
results="build/ci"

fail() {
  echo "ci: $*" >&2
  exit 1
}

[[ "$(uname)" == "Darwin" ]] || fail "needs macOS with Xcode"
command -v xcodebuild >/dev/null || fail "xcodebuild not found: install Xcode and run xcode-select"
command -v xcodegen >/dev/null || fail "xcodegen not found: brew install xcodegen"
[[ -f "$shell_file" ]] || fail "no shell $shell_file"
[[ -d ContractKit && -d HopeTViOS && -d HopeTViOSTests ]] \
  || fail "not seeded: run scripts/sync-from-awe.sh --seed <awe-checkout>"
[[ -d fixtures/app-contract ]] || fail "no fixtures: run scripts/sync-from-awe.sh <awe-checkout>"

# A missing secrets file builds with an empty token; the shell's `#include?` allows it.
if [[ ! -f "Config/Secrets/$app.xcconfig" ]]; then
  echo "ci: no Config/Secrets/$app.xcconfig — building with an empty ClientToken (tests stay offline)"
fi

# One simulator by its id: a name alone can match one device per installed runtime.
# simctl lists runtimes oldest first, so the last iPhone line is on the newest runtime.
line="$(xcrun simctl list devices available | grep -E "^ +${SIMULATOR:-iPhone}" | tail -n 1 || true)"
[[ -n "$line" ]] || fail "no available simulator matches \"${SIMULATOR:-iPhone}\": add one in Xcode > Settings > Components"
simulator_id="$(echo "$line" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
simulator_name="$(echo "$line" | sed -E 's/^ +//; s/ \([0-9A-F-]{36}\).*$//')"

echo "ci: app $app, simulator $simulator_name ($simulator_id)"

rm -rf "$results"
mkdir -p "$results"

echo "ci: 1/3 xcodegen"
xcodegen generate --quiet

pretty() {
  if command -v xcbeautify >/dev/null; then
    xcbeautify
  else
    cat
  fi
}

echo "ci: 2/3 unit tests"
# Ad hoc signing, no team: the simulator's Keychain refuses an unsigned host (-34018), and
# SessionKeychainTests need it.
xcodebuild test \
  -project HopeTViOS.xcodeproj \
  -scheme HopeTViOS \
  -configuration Debug \
  -xcconfig "$shell_file" \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$results/tests.xcresult" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  | tee "$results/test.log" | pretty

echo "ci: 3/3 Release build"
xcodebuild build \
  -project HopeTViOS.xcodeproj \
  -scheme HopeTViOS \
  -configuration Release \
  -xcconfig "$shell_file" \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  | tee "$results/release.log" | pretty

echo "ci: passed — results in $results/"
