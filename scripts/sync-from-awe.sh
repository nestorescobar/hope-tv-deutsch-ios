#!/usr/bin/env bash
# Copies the App Contract code and the conformance fixtures from an awe checkout.
#
#   scripts/sync-from-awe.sh --seed <awe-checkout>   first run: ContractKit + HopeTViOS + tests
#   scripts/sync-from-awe.sh <awe-checkout>          later runs: ContractKit + fixtures only
#
# The source is `apps/tv/tvos/HopeTV` at the awe checkout's HEAD. A file is platform-free when it
# imports none of SwiftUI, AVKit, UIKit or CoreImage. Platform-free files go to ContractKit/ and
# are overwritten on every run. Every other file is UI: --seed copies it once into HopeTViOS/,
# and later runs never touch it, because the iPhone UI is owned by this repo.
#
# scripts/ios-owned.txt lists platform-free files that this repo owns anyway (an iPhone value
# differs). Sync skips them; --seed copies them into HopeTViOS/.
#
# UPSTREAM records the awe commit. A later run prints the upstream UI changes since that commit,
# so a person can port them by hand.
set -euo pipefail

seed=0
if [[ "${1:-}" == "--seed" ]]; then
  seed=1
  shift
fi
if [[ $# -ne 1 ]]; then
  echo "usage: scripts/sync-from-awe.sh [--seed] <awe-checkout>" >&2
  exit 2
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
awe="$(cd "$1" && pwd)"
src="$awe/apps/tv/tvos/HopeTV"
tests="$awe/apps/tv/tvos/HopeTVTests"
fixtures="$awe/fixtures/app-contract"

if [[ ! -d "$src" || ! -d "$fixtures" ]]; then
  echo "error: $awe is not an awe checkout (no apps/tv/tvos/HopeTV or fixtures/app-contract)" >&2
  exit 1
fi
if [[ -n "$(git -C "$awe" status --porcelain -- apps/tv/tvos fixtures/app-contract)" ]]; then
  echo "error: awe has uncommitted changes under apps/tv/tvos or fixtures/app-contract" >&2
  exit 1
fi
if [[ $seed -eq 1 && -d "$repo/ContractKit" ]]; then
  echo "error: ContractKit/ exists, so the repo is seeded already. Run without --seed." >&2
  exit 1
fi
if [[ $seed -eq 0 && ! -d "$repo/ContractKit" ]]; then
  echo "error: no ContractKit/ yet. Run with --seed first." >&2
  exit 1
fi

sha="$(git -C "$awe" rev-parse HEAD)"
previous="$(sed -n 's/^commit: //p' "$repo/UPSTREAM" 2>/dev/null || true)"

owned=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  owned+=("$line")
done < "$repo/scripts/ios-owned.txt"

is_owned() {
  local f
  # The `+` form keeps macOS bash 3.2 from failing on an empty array under `set -u`.
  for f in ${owned[@]+"${owned[@]}"}; do
    [[ "$f" == "$1" ]] && return 0
  done
  return 1
}

is_ui() {
  grep -qE '^import (SwiftUI|AVKit|UIKit|CoreImage)' "$1"
}

rm -rf "$repo/ContractKit"
mkdir -p "$repo/ContractKit"

kit=0
ui=0
while IFS= read -r rel; do
  rel="${rel#./}"
  file="$src/$rel"
  if ! is_ui "$file" && ! is_owned "$rel"; then
    mkdir -p "$repo/ContractKit/$(dirname "$rel")"
    cp "$file" "$repo/ContractKit/$rel"
    kit=$((kit + 1))
  elif [[ $seed -eq 1 ]]; then
    mkdir -p "$repo/HopeTViOS/$(dirname "$rel")"
    cp "$file" "$repo/HopeTViOS/$rel"
    ui=$((ui + 1))
  fi
done < <(cd "$src" && find . -name '*.swift' | sort)

# JSON beside the code (the registry key list), not the tvOS asset catalog. It belongs to
# the platform-free code, so it follows ContractKit.
while IFS= read -r rel; do
  rel="${rel#./}"
  mkdir -p "$repo/ContractKit/$(dirname "$rel")"
  cp "$src/$rel" "$repo/ContractKit/$rel"
done < <(cd "$src" && find . -name '*.json' -not -path './Assets.xcassets/*' | sort)

if [[ $seed -eq 1 ]]; then
  mkdir -p "$repo/HopeTViOSTests"
  cp -R "$tests/." "$repo/HopeTViOSTests/"
  # The tests import the app module by its target name.
  find "$repo/HopeTViOSTests" -name '*.swift' -exec sed -i '' 's/^@testable import HopeTV$/@testable import HopeTViOS/' {} + 2>/dev/null \
    || find "$repo/HopeTViOSTests" -name '*.swift' -exec sed -i 's/^@testable import HopeTV$/@testable import HopeTViOS/' {} +
fi

rm -rf "$repo/fixtures/app-contract"
mkdir -p "$repo/fixtures"
cp -R "$fixtures" "$repo/fixtures/app-contract"

cat > "$repo/UPSTREAM" <<EOF
# The awe commit that ContractKit/ and fixtures/ were copied from. Written by scripts/sync-from-awe.sh.
repository: https://github.com/hope-media/awe
path: apps/tv/tvos/HopeTV
commit: $sha
date: $(git -C "$awe" show -s --format=%cI "$sha")
EOF

echo "ContractKit: $kit files from awe $sha"
if [[ $seed -eq 1 ]]; then
  echo "HopeTViOS: $ui UI files seeded. Port them with docs/PORTING.md."
fi

if [[ -n "$previous" && "$previous" != "$sha" ]]; then
  echo
  echo "Upstream changes since $previous. ContractKit has them; port the UI ones by hand:"
  git -C "$awe" diff --stat "$previous" "$sha" -- apps/tv/tvos/HopeTV apps/tv/tvos/HopeTVTests || true
fi
