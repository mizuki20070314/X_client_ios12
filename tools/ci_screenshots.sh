#!/bin/bash
# Installs the simulator build and takes screenshots of the app's screens (used by CI; run on macOS).
# usage: [GROUP=iphone|ipad] bash tools/ci_screenshots.sh <XRelayClient.app> <simulator-udid> [name-filter]
#   GROUP       = iphone (default: the iPhone shots) or ipad (only the iPad shots; the udid is the iPad simulator's)
#   name-filter = comma-separated substrings of the shot names; empty = every shot
set -u
APP="$1"
UDID="$2"
FILTER="${3:-}"
GROUP="${GROUP:-iphone}"
case "$GROUP" in
  iphone|ipad) ;;
  *) echo "unknown GROUP: $GROUP (iphone or ipad)" >&2; exit 2 ;;
esac
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

# iPad group (GROUP=ipad). Landscape first, then portrait. The simulator stays rotated between launches, so each
# landscape route starts with orient:landscape. The seconds after each launch are the matching iPhone shot's + 2 s
# (the iPad is slower and the rotation takes time). 49 runs last on purpose: the group ends with a launch in portrait.
if [ "$GROUP" = ipad ]; then
  SL="-xr-size 1024x768"
  SP="-xr-size 768x1024"
  shot 40_ipad_home_land 10 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:2"
  shot 41_ipad_home_scrolled_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:2;scroll:1600"
  shot 42_ipad_tweet_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:1;tweet:2122000000000000040;wait:2"
  shot 43_ipad_profile_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:1;profile:hanako_sato_demo;wait:2"
  shot 44_ipad_drawer_land 10 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:1;drawer;wait:1"
  shot 45_ipad_overflow_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:2;overflow:2122000000000000001;wait:1"
  shot 46_ipad_compose_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:1;compose;wait:1;type:今日はいい天気ですね。散歩に行ってきます。"
  shot 47_ipad_viewer_land 11 -xr-demo -xr-theme light $SL -xr-route "orient:landscape;wait:2;viewer:2122000000000000002:0;wait:2"
  shot 48_ipad_home_black_land 10 -xr-demo -xr-theme black $SL -xr-route "orient:landscape;wait:2"
  shot 50_ipad_home_portrait 10 -xr-demo -xr-theme light $SP -xr-route "orient:portrait;wait:2"
  shot 51_ipad_tweet_portrait 11 -xr-demo -xr-theme light $SP -xr-route "orient:portrait;wait:1;tweet:2122000000000000040;wait:2"
  shot 49_ipad_reset 10 -xr-demo -xr-theme light $SP -xr-route "orient:portrait"
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  ls -la "$OUT"
  exit 0
fi

# iPhone group (default, also when GROUP is unset).
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
shot 31_translate_before_320 9 -xr-demo -xr-theme light $S -xr-route "wait:1;hometab:0;wait:1"
shot 32_translate_after_320 10 -xr-demo -xr-theme light $S -xr-route "wait:1;hometab:0;wait:2;translate:2122000000000000090;wait:1"
shot 33_profile_translate_320 11 -xr-demo -xr-theme light $S -xr-route "wait:1;profile:alex_demo;wait:2"
shot 26_icons_light_320 8 -xr-demo -xr-theme light $S -xr-route "icons"
shot 27_icons_black 8 -xr-demo -xr-theme black -xr-route "icons"

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
ls -la "$OUT"
