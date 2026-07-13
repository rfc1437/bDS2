#!/bin/bash
# End-to-end blogmark verification against the bundled macOS app.
#
# Launches BDS2.app through LaunchServices with an isolated database, fires
# bds2://new-post deep links the same way a browser bookmarklet does, and
# asserts draft posts show up in the database. Covers both the cold-start
# path (link launches the app, gets queued, drains on shell attach) and the
# already-running path.
#
# The app MUST be launched via LaunchServices (`open -a`): a process started
# by exec'ing Contents/MacOS/bds2 from a shell never receives Apple Events,
# so deep links silently go nowhere. Env vars are injected with
# `launchctl setenv` because `open` does not pass the shell environment.
#
# Usage: scripts/verify_blogmark_macos.sh [path/to/BDS2.app]
set -euo pipefail

APP="$(cd "${1:-dist/macos/BDS2.app}" 2>/dev/null && pwd)" || { echo "FAIL: app bundle not found" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$APP/Contents/MacOS/bds2" ] \
  || fail "$APP is not a built bundle. Build with: mix assets.deploy && MIX_ENV=prod mix release bds --overwrite && mix bds.bundle.macos"

# Guard against the regression that broke blogmarks in July 2026: a bundle
# whose server waits for the client's shell_ready event but whose stale
# app.js never sends it. Deep links then queue forever with no error anywhere.
grep -q shell_ready "$APP"/Contents/Resources/rel/lib/bds-*/priv/static/assets/app.js \
  || fail "bundle ships stale app.js (no shell_ready) — run mix assets.deploy BEFORE mix release"

# epmd survives app quit and lives under the .app path, so match the VM only.
# Any running BDS2 (installed or dist) makes LaunchServices routing ambiguous.
pgrep -f "BDS2.app.*beam" >/dev/null && fail "a BDS2.app instance is already running; quit it first"

WORK="$(mktemp -d /tmp/bds2-blogmark-verify.XXXXXX)"
DB="$WORK/bds.db"
STAMP="$(date +%s)"

cleanup() {
  # The launcher execs a script that runs beam as a child, so kill by path.
  pkill -f "$APP.*beam" 2>/dev/null || true
  launchctl unsetenv BDS_DATABASE_PATH
  rm -rf "$WORK"
}
trap cleanup EXIT

sql() { sqlite3 -cmd '.timeout 2000' "$DB" "$1" 2>/dev/null || true; }

wait_for_draft() { # $1 = title, $2 = timeout seconds
  local i row
  for i in $(seq 1 "$2"); do
    row="$(sql "select status || '|' || content from posts where title = '$1';")"
    if [ -n "$row" ]; then
      case "$row" in
        draft\|*example.com*) return 0 ;;
        *) fail "post '$1' found but wrong shape: $row" ;;
      esac
    fi
    sleep 1
  done
  return 1
}

launchctl setenv BDS_DATABASE_PATH "$DB"

# Cold start: the deep link itself launches the app. The link must survive
# boot (queued in BDS.Desktop.DeepLink) and import once the shell attaches.
COLD="Blogmark cold $STAMP"
echo "Cold start: launching $APP via deep link ..."
open -a "$APP" "bds2://new-post?title=${COLD// /%20}&url=https%3A%2F%2Fexample.com%2Fcold"
wait_for_draft "$COLD" 120 || fail "cold-start deep link produced no draft within 120s"
echo "  ok: cold-start draft created"

# Already running: a second link must import immediately.
WARM="Blogmark warm $STAMP"
open -a "$APP" "bds2://new-post?title=${WARM// /%20}&url=https%3A%2F%2Fexample.com%2Fwarm"
wait_for_draft "$WARM" 30 || fail "deep link to the running app produced no draft within 30s"
echo "  ok: already-running draft created"

echo "PASS: blogmark deep links verified against $APP"
