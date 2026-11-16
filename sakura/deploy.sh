#!/bin/sh
# Deploy the relay on the server, from the repository checkout:
#     sh sakura/deploy.sh [document root]     (default: ~/www/xclient)
# Steps, stopping at the first failure:
#   1. byte-compile the application and the CGI entry point
#   2. run the unit tests (third-party packages from the private python directory)
#   3. install the application package under the private root (directory swap)
#   4. copy the www files into the document root
#   5. smoke-test the installed CGI with /healthz
# POSIX sh only: this runs on FreeBSD, where bash is not there.
set -e

SAKURA_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$SAKURA_DIR")
PRIVATE_ROOT=${XRELAY_HOME:-$HOME/private/xrelay}
DOC_ROOT=${1:-$HOME/www/xclient}
APP_PARENT="$PRIVATE_ROOT/app"

fail() {
    printf 'deploy.sh: %s\n' "$1" >&2
    exit 1
}

cd "$REPO_DIR"

echo "== 1. byte-compile"
find sakura/app -name '*.py' -exec python -m py_compile {} \; || fail "compile failed under sakura/app"
python -m py_compile sakura/www/cgi-bin/xrelay.cgi || fail "compile failed: sakura/www/cgi-bin/xrelay.cgi"

echo "== 2. unit tests"
PYTHONPATH="$PRIVATE_ROOT/python${PYTHONPATH:+:$PYTHONPATH}" python -m unittest discover -s sakura/tests \
    || fail "tests failed; nothing was installed"

echo "== 3. install the application to $APP_PARENT/xrelay_app"
mkdir -p "$APP_PARENT"
rm -rf "$APP_PARENT/xrelay_app.new"
cp -R "$SAKURA_DIR/app/xrelay_app" "$APP_PARENT/xrelay_app.new"
find "$APP_PARENT/xrelay_app.new" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$APP_PARENT/xrelay_app.new" -type d -exec chmod 700 {} +
find "$APP_PARENT/xrelay_app.new" -type f -exec chmod 600 {} +
if [ -d "$APP_PARENT/xrelay_app" ]; then
    rm -rf "$APP_PARENT/xrelay_app.old"
    mv "$APP_PARENT/xrelay_app" "$APP_PARENT/xrelay_app.old"
fi
mv "$APP_PARENT/xrelay_app.new" "$APP_PARENT/xrelay_app"
rm -rf "$APP_PARENT/xrelay_app.old"

echo "== 4. copy the www files to $DOC_ROOT"
mkdir -p "$DOC_ROOT/cgi-bin"
cp "$SAKURA_DIR/www/.htaccess" "$DOC_ROOT/.htaccess"
cp "$SAKURA_DIR/www/requests.ndjson" "$DOC_ROOT/requests.ndjson"
cp "$SAKURA_DIR/www/cgi-bin/xrelay.cgi" "$DOC_ROOT/cgi-bin/xrelay.cgi.new"
chmod 755 "$DOC_ROOT/cgi-bin/xrelay.cgi.new"
mv "$DOC_ROOT/cgi-bin/xrelay.cgi.new" "$DOC_ROOT/cgi-bin/xrelay.cgi"

echo "== 5. smoke test"
OUT=$(mktemp) || fail "mktemp failed"
REQUEST_METHOD=GET QUERY_STRING='__path=/healthz' "$DOC_ROOT/cgi-bin/xrelay.cgi" > "$OUT" 2>&1 || true
if ! grep -F '{"status":"ok"}' "$OUT" > /dev/null; then
    cat "$OUT" >&2
    rm -f "$OUT"
    fail "smoke test failed: /healthz did not answer ok"
fi
rm -f "$OUT"
echo "deployed: $APP_PARENT/xrelay_app and $DOC_ROOT"
