#!/bin/bash
# Manual migration against the legacy "manual" release directory.
# scripts/deploy-remote.sh runs migrations inside each versioned release,
# after taking its own backup. Prefer scripts/deploy.sh.
set -euo pipefail
server=${1:?server}; backup=${2:?backup path required before database migrations}
ssh "$server" bash -s -- "$backup" <<'REMOTE'
set -euo pipefail
test -s "$1"
cd /srv/microblog/releases/manual
runuser -u app -- env FLASK_APP=microblog.py DATABASE_URL=sqlite:////srv/microblog/data/app.db SECRET_KEY=legacy-migration-local-key /opt/task87-venv/bin/flask db upgrade
REMOTE
