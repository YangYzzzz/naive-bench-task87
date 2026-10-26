#!/bin/bash
set -euo pipefail
server=${1:?test-server or prod-server}
ssh "$server" 'mkdir -p /srv/microblog/backups; stamp=$(date -u +%Y%m%dT%H%M%SZ); docker exec microblog python -c "import sqlite3; s=sqlite3.connect("/data/app.db"); d=sqlite3.connect("/data/pre-migration.db"); s.backup(d); d.close(); s.close()"; docker cp microblog:/data/pre-migration.db /srv/microblog/backups/$stamp.db; printf "%s\n" /srv/microblog/backups/$stamp.db'
