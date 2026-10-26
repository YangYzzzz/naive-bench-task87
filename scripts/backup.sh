#!/bin/bash
# Manual/standalone database backup. scripts/deploy-remote.sh performs the
# same backup automatically before every migration.
set -euo pipefail
server=${1:?test-server or prod-server}
ssh "$server" 'python3 -' <<'PY'
import datetime, pathlib, sqlite3
directory = pathlib.Path('/srv/microblog/backups')
directory.mkdir(parents=True, exist_ok=True)
path = directory / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.db')
source = sqlite3.connect('file:/srv/microblog/data/app.db?mode=ro', uri=True)
target = sqlite3.connect(path)
source.backup(target)
target.close()
source.close()
print(path)
PY
