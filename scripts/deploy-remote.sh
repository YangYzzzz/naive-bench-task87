#!/usr/bin/env bash
#
# Remote half of scripts/deploy.sh. Runs as root on the target server.
#
# Transactional, versioned deploy:
#   prepare dirs -> unpack release -> unit tests -> DB backup -> migrate
#   -> snapshot migrated DB -> switch symlink -> restart -> health check
# Any failure automatically restores the database from the pre-migration
# backup and points /srv/microblog/current back at the previous release.
#
# Invoked by scripts/deploy.sh as:
#   ssh <host> "env ... bash -s -- <version>" < scripts/deploy-remote.sh
#
set -uo pipefail

VERSION=${1:?usage: bash -s -- <version>}
NAMESPACE='task87-48f9273e96924437833f'
ROOT=/srv/microblog
RELEASES="$ROOT/releases"
RELEASE="$RELEASES/$VERSION"
DATA="$ROOT/data/app.db"
PIDFILE="$ROOT/run/gunicorn.pid"
ARCHIVE="/tmp/task87-code-${VERSION}.tar.gz"
DEPLOY_LOG="$ROOT/logs/deploy.log"

if [[ "$VERSION" != "$NAMESPACE-"* ]]; then
  echo "error: version '$VERSION' is not from this round (expected ${NAMESPACE}-*)" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: version name must be a plain directory name" >&2
  exit 2
fi

log() {
  echo "[deploy ${VERSION}] $(date -u +%FT%TZ) $*" | tee -a "$DEPLOY_LOG"
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
  # Prints the backup path, or "SKIP" when there is no database yet.
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

PREVIOUS=''
BACKUP=''

do_rollback() {
  log "automatic rollback starting (previous=${PREVIOUS:-none})"
  stop_gunicorn || true
  if [[ -n "$BACKUP" && -s "$BACKUP" ]]; then
    if cp -f "$BACKUP" "$DATA" && chown app:app "$DATA"; then
      log "database restored from $BACKUP"
    else
      log "CRITICAL: could not restore database from $BACKUP"
    fi
  fi
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" ]]; then
    ln -sfn "$PREVIOUS" "$ROOT/current"
    log "current -> $PREVIOUS"
  fi
  if start_gunicorn && health_check; then
    log "automatic rollback complete; service healthy on ${PREVIOUS:-unknown}"
    return 0
  fi
  log "CRITICAL: service unhealthy after rollback"
  return 1
}

fail() {
  log "ERROR: $*"
  do_rollback || true
  rm -f "$ARCHIVE"
  exit 1
}

# --- prepare (this permission setup used to exist only in deploy.md) -------
install -d -o app -g app -m 750 "$ROOT/data" "$ROOT/logs" "$ROOT/run" "$ROOT/backups"
: >> "$DEPLOY_LOG"
PREVIOUS=$(readlink -f "$ROOT/current" 2>/dev/null || true)
log "starting deploy (previous=${PREVIOUS:-none} sha=${DEPLOY_GIT_SHA:-unknown} run=${DEPLOY_RUN_ID:-unknown} ref=${DEPLOY_REF:-local})"

[[ -s "$ARCHIVE" ]] || fail "code archive missing: $ARCHIVE"

# --- unpack the release ----------------------------------------------------
rm -rf "$RELEASE"
install -d -o app -g app -m 750 "$RELEASE"
tar xzf "$ARCHIVE" -C "$RELEASE" || fail "failed to extract code archive"
[[ -f "$RELEASE/microblog.py" ]] || fail "archive does not contain microblog.py"
chown -R app:app "$RELEASE" || fail "could not change release ownership"
cd "$RELEASE" || fail "cannot enter $RELEASE"

# --- quality gate ----------------------------------------------------------
if [[ -f tests.py ]]; then
  log "running unit tests"
  runuser -u app -- env ELASTICSEARCH_URL= \
    /opt/task87-venv/bin/python tests.py >> "$DEPLOY_LOG" 2>&1 \
    || fail "unit tests failed"
fi

# --- database backup before migration --------------------------------------
BACKUP=$(take_backup '-pre-deploy.db') || fail "database backup failed"
BACKUP=${BACKUP//$'\r'/}
if [[ "$BACKUP" == 'SKIP' ]]; then
  BACKUP=''
fi
if [[ -n "$BACKUP" ]]; then
  printf '%s\n' "$BACKUP" > "$RELEASE/.db-backup"
  chown app:app "$RELEASE/.db-backup"
  log "database backup: $BACKUP"
else
  log "no existing database; migrations will create it"
fi

# --- migrations ------------------------------------------------------------
log "running database migrations"
if ! runuser -u app -- env \
      FLASK_APP=microblog.py \
      DATABASE_URL="sqlite:///$DATA" \
      SECRET_KEY=legacy-migration-local-key \
      /opt/task87-venv/bin/flask db upgrade >> "$DEPLOY_LOG" 2>&1; then
  fail "database migration failed"
fi

# Snapshot the migrated database: this is the consistent DB state for this
# release and is what a manual rollback to this version restores.
install -d -o app -g app -m 750 "$RELEASE/.db-state"
if [[ -s "$DATA" ]]; then
  cp -f "$DATA" "$RELEASE/.db-state/app.db" || fail "cannot snapshot migrated database"
  chown app:app "$RELEASE/.db-state/app.db"
fi

# --- switch release and restart --------------------------------------------
log "switching release"
stop_gunicorn || fail "could not stop the running service"
ln -sfn "$RELEASE" "$ROOT/current" || fail "could not update the current symlink"
start_gunicorn || fail "gunicorn failed to start"
health_check || fail "health check failed"

# Only successful releases get metadata, so the manual rollback entry point
# can refuse partial/failed release directories.
cat > "$RELEASE/.deploy-meta" <<EOF
version=$VERSION
previous=$PREVIOUS
backup=$BACKUP
git_sha=${DEPLOY_GIT_SHA:-unknown}
run_id=${DEPLOY_RUN_ID:-unknown}
ref=${DEPLOY_REF:-local}
deployed_at=$(date -u +%FT%TZ)
EOF
chown app:app "$RELEASE/.deploy-meta"

rm -f "$ARCHIVE"
log "deploy succeeded"
exit 0
