#!/usr/bin/env bash
#
# Remote half of scripts/rollback.sh. Runs as root on the target server.
#
# Rolls /srv/microblog back to a release that was successfully deployed by
# this round: takes a safety backup of the current database, restores the
# target release's database snapshot, switches the current symlink and
# restarts gunicorn. If the target does not become healthy the safety
# backup and the previous release are restored instead.
#
# Invoked as:  ssh <host> "bash -s -- <version>" < scripts/rollback-remote.sh
#
set -uo pipefail

VERSION=${1:?usage: bash -s -- <version>}
NAMESPACE='task87-48f9273e96924437833f'
ROOT=/srv/microblog
RELEASE="$ROOT/releases/$VERSION"
DATA="$ROOT/data/app.db"
PIDFILE="$ROOT/run/gunicorn.pid"
ROLLBACK_LOG="$ROOT/logs/rollback.log"

if [[ "$VERSION" != "$NAMESPACE-"* ]]; then
  echo "error: version '$VERSION' is not from this round (expected ${NAMESPACE}-*)" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: version name must be a plain directory name" >&2
  exit 2
fi
if [[ ! -f "$RELEASE/.deploy-meta" ]]; then
  echo "error: ${VERSION} is not a successfully deployed release of this round" >&2
  exit 2
fi
if ! grep -qx "version=$VERSION" "$RELEASE/.deploy-meta"; then
  echo "error: release metadata for ${VERSION} does not match" >&2
  exit 2
fi

log() {
  echo "[rollback ${VERSION}] $(date -u +%FT%TZ) $*" | tee -a "$ROLLBACK_LOG"
}

stop_gunicorn() {
  if [[ -s "$PIDFILE" ]]; then
    local old
    old=$(cat "$PIDFILE")
    kill -TERM "$old" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$old" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$old" 2>/dev/null; then
      echo "gunicorn master $old did not stop" >&2
      return 1
    fi
  fi
  rm -f "$PIDFILE"
}

start_gunicorn() {
  cd "$ROOT/current" || return 1
  runuser -u app -- env \
    FLASK_APP=microblog.py \
    DATABASE_URL="sqlite:///$DATA" \
    SECRET_KEY=legacy-app-local-key \
    LOG_TO_STDOUT=1 \
    /opt/task87-venv/bin/gunicorn --daemon --workers 2 --bind 0.0.0.0:8080 \
      --pid "$PIDFILE" \
      --access-logfile "$ROOT/logs/access.log" \
      --error-logfile "$ROOT/logs/error.log" \
      microblog:app
  for _ in $(seq 1 30); do
    [[ -s "$PIDFILE" ]] && return 0
    sleep 0.2
  done
  echo "gunicorn did not write its pid file" >&2
  return 1
}

health_check() {
  for _ in $(seq 1 20); do
    if curl -sf --max-time 3 -o /dev/null http://127.0.0.1:8080/auth/login; then
      return 0
    fi
    sleep 1
  done
  echo "service did not become healthy on :8080" >&2
  return 1
}

take_backup() {
  runuser -u app -- python3 - "$1" <<'PY'
import datetime
import pathlib
import sqlite3
import sys

suffix = sys.argv[1]
data = pathlib.Path('/srv/microblog/data/app.db')
if not data.exists():
    print('SKIP')
    raise SystemExit(0)
directory = pathlib.Path('/srv/microblog/backups')
directory.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
path = directory / (stamp + suffix)
source = sqlite3.connect('file:/srv/microblog/data/app.db?mode=ro', uri=True)
target = sqlite3.connect(str(path))
source.backup(target)
target.close()
source.close()
print(path)
PY
}

CURRENT=$(readlink -f "$ROOT/current" 2>/dev/null || true)
TARGET_DB=''
if [[ -s "$RELEASE/.db-state/app.db" ]]; then
  TARGET_DB="$RELEASE/.db-state/app.db"
elif [[ -s "$RELEASE/.db-backup" ]]; then
  TARGET_DB=$(cat "$RELEASE/.db-backup")
fi

SAFETY=$(take_backup '-pre-rollback.db') || true
SAFETY=${SAFETY//$'\r'/}
[[ "$SAFETY" == 'SKIP' ]] && SAFETY=''

log "rolling back (current=${CURRENT:-none} target=${VERSION})"
stop_gunicorn || { log "ERROR: could not stop the running service"; exit 1; }

if [[ -n "$TARGET_DB" && -s "$TARGET_DB" ]]; then
  cp -f "$TARGET_DB" "$DATA" && chown app:app "$DATA" \
    || { log "ERROR: could not restore database from $TARGET_DB"; exit 1; }
  log "database restored from $TARGET_DB"
else
  log "release has no database snapshot; leaving the database in place"
fi

ln -sfn "$RELEASE" "$ROOT/current" || { log "ERROR: could not switch current symlink"; exit 1; }

if start_gunicorn && health_check; then
  log "rollback complete; ${VERSION} is live"
  exit 0
fi

log "ERROR: ${VERSION} did not become healthy; reverting the rollback"
stop_gunicorn || true
if [[ -n "$SAFETY" && -s "$SAFETY" ]]; then
  cp -f "$SAFETY" "$DATA" && chown app:app "$DATA" || true
  log "database restored from safety backup $SAFETY"
fi
if [[ -n "$CURRENT" && -d "$CURRENT" ]]; then
  ln -sfn "$CURRENT" "$ROOT/current"
  log "current -> $CURRENT"
fi
start_gunicorn && health_check && log "previous release restored"
exit 1
