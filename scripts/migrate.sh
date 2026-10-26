#!/bin/bash
set -euo pipefail
server=${1:?server}; backup=${2:?backup path required before database migrations}
ssh "$server" "test -s '$backup'"
ssh "$server" 'docker run --rm --network microblog-net -v microblog-data:/data -e FLASK_APP=microblog.py -e DATABASE_URL=sqlite:////data/app.db -e SECRET_KEY=legacy-migration-local-key --entrypoint flask microblog:manual db upgrade'
