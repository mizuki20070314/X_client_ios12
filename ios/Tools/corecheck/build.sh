#!/bin/bash
# Builds the Foundation-only part of Core with the Linux Swift toolchain (Swift 5 mode) and runs corecheck.
# usage (from Git Bash): MSYS_NO_PATHCONV=1 wsl -e bash /mnt/c/Users/mizuk/X_client_ios12/ios/Tools/corecheck/build.sh [json files]
# Without arguments the bundled demo files are checked. The binary goes to $HOME, never into the repository.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/../../XRelayClient/Core"
OUT_DIR="$HOME/.cache/xrelay-corecheck"
SWIFTC="${SWIFTC:-/opt/swift/usr/bin/swiftc}"

mkdir -p "$OUT_DIR"
"$SWIFTC" -swift-version 5 \
  "$CORE/JSON.swift" \
  "$CORE/Models.swift" \
  "$CORE/TweetStore.swift" \
  "$CORE/Format.swift" \
  "$CORE/TwitterText.swift" \
  "$CORE/APIError.swift" \
  "$HERE/main.swift" \
  -o "$OUT_DIR/corecheck"
echo "built: $OUT_DIR/corecheck"

if [ "$#" -eq 0 ]; then
  set -- "$HERE/../../XRelayClient/Resources/Demo"/demo_*.json
fi
"$OUT_DIR/corecheck" "$@"
