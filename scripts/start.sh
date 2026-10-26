#!/bin/bash
# Manual restart against the legacy "manual" release directory, without a
# health check or rollback. scripts/deploy-remote.sh restarts the versioned
# release and verifies it instead. Prefer scripts/deploy.sh.
set -euo pipefail
server=${1:?server}
ssh "$server" 'bash -s' <<'REMOTE'
set -euo pipefail
pid=/srv/microblog/run/gunicorn.pid
if [ -s "$pid" ]; then
  old=$(cat "$pid")
  kill -TERM "$old" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$old" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$old" 2>/dev/null; then echo 'old service did not stop' >&2; exit 1; fi
fi
rm -f "$pid"
ln -sfn /srv/microblog/releases/manual /srv/microblog/current
cd /srv/microblog/current
runuser -u app -- env FLASK_APP=microblog.py DATABASE_URL=sqlite:////srv/microblog/data/app.db SECRET_KEY=legacy-app-local-key LOG_TO_STDOUT=1 /opt/task87-venv/bin/gunicorn --daemon --workers 2 --bind 0.0.0.0:8080 --pid "$pid" --access-logfile /srv/microblog/logs/access.log --error-logfile /srv/microblog/logs/error.log microblog:app
REMOTE
