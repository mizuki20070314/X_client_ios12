#!/bin/bash
# Waits for the "iOS client" run of a commit, re-runs it when GitHub found no macOS runner, then prints the step
# results and the compiler errors. Used from Git Bash on the development PC.
#   tools/ci_wait.sh <commit sha prefix>
export PATH="/c/Users/mizuk/tools/gh/bin:$PATH"
REPO=mizuki20070314/X_client_ios12
SHA="$1"
id=""
for i in $(seq 1 30); do
  id=$(gh run list -R "$REPO" --limit 5 --json databaseId,headSha -q ".[] | select(.headSha|startswith(\"$SHA\")) | .databaseId" | head -1)
  [ -n "$id" ] && break
  sleep 5
done
echo "run=$id"
[ -z "$id" ] && exit 1
for attempt in 1 2 3 4; do
  gh run watch "$id" -R "$REPO" --interval 30 > /dev/null 2>&1
  steps=$(gh run view "$id" -R "$REPO" --json jobs -q '.jobs[0].steps|length')
  [ "$steps" != "0" ] && break
  echo "no runner (attempt $attempt), re-running"
  gh run rerun "$id" -R "$REPO"
  sleep 30
done
gh run view "$id" -R "$REPO" --json conclusion,jobs -q '.conclusion + "\n" + (.jobs[].steps | map(.name + " = " + (.conclusion // .status)) | join("\n"))'
gh run view "$id" -R "$REPO" --log 2>/dev/null | grep -E "error:|!!! app not running|=== " | grep -v "grep -E" \
  | sed -E 's#.*/X_client_ios12/X_client_ios12/##; s#^.*Take screenshots[^=]*##' | sort -u | head -120
