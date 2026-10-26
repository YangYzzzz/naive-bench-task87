#!/bin/bash
# Retired deployment: old location, old virtualenv, old port. Kept for historical reference.
set -euo pipefail
server=${1:-test-server}
ssh "$server" 'cd /srv/microblog-old; export DATABASE_URL=sqlite:////srv/microblog-old/app.db; export SECRET_KEY=legacy-v0-local-key; . venv/bin/activate; pkill -f "gunicorn.*microblog" || true; nohup gunicorn -b 0.0.0.0:5000 microblog:app >>old-app.log 2>&1 &'
