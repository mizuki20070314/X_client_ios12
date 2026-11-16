#!/bin/bash
# Installs the simulator build and takes screenshots of the app's screens (used by CI; run on macOS).
# usage: bash tools/ci_screenshots.sh <XRelayClient.app> <simulator-udid> [name-filter]
#   name-filter = comma-separated substrings of the shot names; empty = every shot
set -u
APP="$1"
UDID="$2"
FILTER="${3:-}"
BUNDLE=com.mizuki20070314.XRelayClient
OUT=shots
mkdir -p "$OUT"

xcrun simctl install "$UDID" "$APP"

# is a shot selected by the filter?
want() {
  [ -z "$FILTER" ] && return 0
  local f
  for f in ${FILTER//,/ }; do [[ "$1" == *"$f"* ]] && return 0; done
  return 1
}

# name, seconds to wait, launch args...
shot() {
  local name="$1"; local seconds="$2"; shift 2
  want "$name" || return
  echo "=== $name"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BUNDLE" -AppleLanguages "(ja)" -AppleLocale ja_JP "$@" || echo "launch failed"
  sleep "$seconds"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" || echo "screenshot failed"
  # keep a crash marker if the app is no longer running
  if ! xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE"; then
    echo "!!! app not running after $name" | tee -a "$OUT/crashes.txt"
  fi
}

shot 01_placeholder_320 8 -xr-demo -xr-theme light -xr-size 320x568
shot 02_icons_light_320 8 -xr-demo -xr-theme light -xr-size 320x568 -xr-route "icons"
shot 03_icons_black_320 8 -xr-demo -xr-theme black -xr-size 320x568 -xr-route "icons"
shot 04_icons_dim 8 -xr-demo -xr-theme dim -xr-route "icons"

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
ls -la "$OUT"
