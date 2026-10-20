#!/usr/bin/env bash
# Boots an unpacked desktop gateway package the way the desktop host does and
# checks that the backend becomes ready, the bootstrap admin can sign in and
# the console answers.
#
# Usage: deploy/desktop/smoke.sh <archive> [node]
#   node: the JavaScript runtime for frontend/server.js (default: node). Pass
#         an Electron binary to match the host; ELECTRON_RUN_AS_NODE is set.
#
# The package is unpacked under a directory whose name contains a space, so
# the sqlite: database URL and catalog paths are exercised with one, which
# matters for per-user profile paths such as C:/Users/John Smith/.
set -Eeuo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: %s <archive> [node]\n' "$0" >&2
  exit 2
fi
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
node_bin="${2:-node}"
api_port="${TOKENHUB_SMOKE_API_PORT:-18080}"
console_port="${TOKENHUB_SMOKE_CONSOLE_PORT:-18081}"

root="$(mktemp -d "${TMPDIR:-/tmp}/tokenhub-smoke.XXXXXX")/desktop gateway"
version_dir="$root/versions/current"
data_dir="$root/data"
mkdir -p "$version_dir" "$data_dir"
backend_pid=""
frontend_pid=""

log() {
  printf '[desktop-smoke] %s\n' "$*" >&2
}

cleanup() {
  local pid
  for pid in "$frontend_pid" "$backend_pid"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  for pid in "$frontend_pid" "$backend_pid"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "${root%/*}"
}
trap cleanup EXIT

fail() {
  printf '[desktop-smoke] ERROR: %s\n' "$*" >&2
  for log_file in "$root/backend.log" "$root/frontend.log"; do
    if [ -f "$log_file" ]; then
      printf -- '--- %s (last 40 lines)\n' "${log_file##*/}" >&2
      tail -n 40 "$log_file" >&2
    fi
  done
  exit 1
}

# Native Windows programs need C:/... paths rather than MSYS /c/... paths.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# Polls a URL until its status code is below 500 or the timeout elapses.
wait_for() {
  local url="$1" seconds="$2" pid="$3" deadline status
  deadline=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" || true)"
    if [ "$status" != "000" ] && [ "$status" -lt 500 ]; then
      printf '%s' "$status"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

case "$archive" in
  *.zip)
    if command -v 7z >/dev/null 2>&1; then
      7z x -bd -bso0 "-o$(native_path "$version_dir")" "$(native_path "$archive")"
    else
      unzip -q "$archive" -d "$version_dir"
    fi
    backend_bin="$version_dir/bin/tokenhub.exe"
    ;;
  *.tar.gz)
    tar -xzf "$archive" -C "$version_dir"
    backend_bin="$version_dir/bin/tokenhub"
    chmod 0755 "$backend_bin"
    ;;
  *) fail "unsupported archive $archive" ;;
esac
for required in VERSION frontend/server.js catalog/model-catalog.yaml catalog/provider-catalog.json; do
  [ -f "$version_dir/$required" ] || fail "package is missing $required"
done
[ -f "$backend_bin" ] || fail "package is missing ${backend_bin#"$version_dir/"}"
log "unpacked $(tr -d '\r\n' <"$version_dir/VERSION") into $root"

admin_password="$(openssl rand -hex 24)"
log "starting backend on 127.0.0.1:$api_port"
(
  cd "$data_dir"
  exec env \
    TOKENHUB_ENV=production \
    TOKENHUB_HTTP_ADDR="127.0.0.1:$api_port" \
    TOKENHUB_DATABASE_URL="sqlite:$(native_path "$data_dir/tokenhub.db")" \
    TOKENHUB_SECRET_KEY="$(openssl rand -hex 32)" \
    TOKENHUB_ADMIN_TOKEN="$(openssl rand -hex 32)" \
    TOKENHUB_BOOTSTRAP_ADMIN_PASSWORD="$admin_password" \
    TOKENHUB_CORS_ALLOWED_ORIGINS="http://127.0.0.1:$console_port" \
    TOKENHUB_PUBLIC_BASE_URL="http://127.0.0.1:$api_port" \
    TOKENHUB_MODEL_CATALOG_FILE="$(native_path "$version_dir/catalog/model-catalog.yaml")" \
    TOKENHUB_PROVIDER_CATALOG_FILE="$(native_path "$version_dir/catalog/provider-catalog.json")" \
    TOKENHUB_PLUGIN_DIR="$(native_path "$data_dir/plugins")" \
    TOKENHUB_SQLITE_BACKUP_DIR="$(native_path "$data_dir/backups")" \
    TOKENHUB_IMAGE_STORAGE_DIR="$(native_path "$data_dir/images")" \
    TOKENHUB_MANAGED_UPDATES=false \
    TOKENHUB_GRACEFUL_SHUTDOWN_SECONDS=8 \
    "$backend_bin"
) >"$root/backend.log" 2>&1 &
backend_pid=$!

status="$(wait_for "http://127.0.0.1:$api_port/readyz" 60 "$backend_pid")" || fail "backend did not become ready"
[ "$status" = "200" ] || fail "backend /readyz returned $status"
[ -f "$data_dir/tokenhub.db" ] || fail "backend did not create $data_dir/tokenhub.db"
log "backend ready"

login_status="$(curl -s -o "$root/login.json" -w '%{http_code}' --max-time 10 \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":\"admin\",\"password\":\"$admin_password\"}" \
  "http://127.0.0.1:$api_port/api/admin/auth/login")"
[ "$login_status" = "200" ] || fail "bootstrap admin login returned $login_status"
grep -q '"token"' "$root/login.json" || fail "login response has no session token"
log "bootstrap admin login succeeded"

log "starting console on 127.0.0.1:$console_port with $node_bin"
(
  cd "$version_dir/frontend"
  exec env \
    ELECTRON_RUN_AS_NODE=1 \
    NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=127.0.0.1 \
    PORT="$console_port" \
    TOKENHUB_API_BASE_URL="http://127.0.0.1:$api_port" \
    "$node_bin" server.js
) >"$root/frontend.log" 2>&1 &
frontend_pid=$!

status="$(wait_for "http://127.0.0.1:$console_port/" 30 "$frontend_pid")" || fail "console did not answer"
log "console answered with $status"
log "ok"
