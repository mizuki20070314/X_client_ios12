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

# The reference size is the iPod touch (320x568); a few shots use the full simulator screen (375 pt wide).
S="-xr-size 320x568"
shot 01_home_light_320 8 -xr-demo -xr-theme light $S
shot 02_home_scrolled_320 9 -xr-demo -xr-theme light $S -xr-route "wait:2;scroll:1600"
shot 03_home_following_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;hometab:1;wait:2"
shot 04_home_black 8 -xr-demo -xr-theme black
shot 05_home_dim 8 -xr-demo -xr-theme dim
shot 06_drawer_320 8 -xr-demo -xr-theme light $S -xr-route "wait:1;drawer"
shot 07_tweet_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;tweet:2122000000000000040"
shot 08_tweet_scrolled_320 10 -xr-demo -xr-theme light $S -xr-route "wait:1;tweet:2122000000000000040;wait:2;scroll:500"
shot 09_profile_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;profile:hanako_sato_demo"
shot 10_profile_scrolled_320 10 -xr-demo -xr-theme light $S -xr-route "wait:1;profile:hanako_sato_demo;wait:2;scroll:400"
shot 11_profile_self_black 9 -xr-demo -xr-theme black -xr-route "wait:1;profile:yamada_demo"
shot 12_search_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;tab:1;wait:2"
shot 13_search_results_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;search:猫;wait:2"
shot 14_search_people_320 10 -xr-demo -xr-theme light $S -xr-route "wait:1;search:猫;wait:2;mode:2;wait:1"
shot 15_notifications_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;tab:2;wait:2"
shot 16_messages_320 8 -xr-demo -xr-theme light $S -xr-route "wait:1;tab:3"
shot 17_compose_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;compose;wait:1;type:今日はいい天気ですね。散歩に行ってきます。"
shot 18_reply_320 9 -xr-demo -xr-theme light $S -xr-route "wait:2;reply:2122000000000000002;wait:1"
shot 19_overflow_320 9 -xr-demo -xr-theme light $S -xr-route "wait:2;overflow:2122000000000000001"
shot 20_repostmenu_320 9 -xr-demo -xr-theme light $S -xr-route "wait:2;repostmenu:2122000000000000002"
shot 21_viewer_320 9 -xr-demo -xr-theme light $S -xr-route "wait:2;viewer:2122000000000000002:0;wait:1"
shot 22_settings_320 8 -xr-demo -xr-theme light $S -xr-route "wait:1;settings"
shot 23_history_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;history;wait:2"
shot 24_themesheet_320 8 -xr-demo -xr-theme light $S -xr-route "wait:1;themesheet"
shot 25_userlist_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;userlist:100001;wait:1"
shot 28_compose 9 -xr-demo -xr-theme light -xr-route "wait:1;compose;wait:1;type:今日はいい天気ですね。散歩に行ってきます。"
shot 29_tweet_black 9 -xr-demo -xr-theme black -xr-route "wait:1;tweet:2122000000000000040"
shot 30_userlist_black 9 -xr-demo -xr-theme black -xr-route "wait:1;userlist:100001;wait:1"
shot 31_translate_before_320 8 -xr-demo -xr-theme light $S
shot 32_translate_after_320 10 -xr-demo -xr-theme light $S -xr-route "wait:2;translate:2122000000000000090;wait:1"
shot 33_profile_translate_320 11 -xr-demo -xr-theme light $S -xr-route "wait:1;profile:alex_demo;wait:2"
shot 26_icons_light_320 8 -xr-demo -xr-theme light $S -xr-route "icons"
shot 27_icons_black 8 -xr-demo -xr-theme black -xr-route "icons"

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
ls -la "$OUT"
