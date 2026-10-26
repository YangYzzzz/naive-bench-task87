#!/bin/bash
set -euo pipefail
server=${1:?server}
ssh "$server" 'docker rm -f microblog 2>/dev/null || true; docker run -d --name microblog --network microblog-net -p 8080:5000 -v microblog-data:/data -e DATABASE_URL=sqlite:////data/app.db -e SECRET_KEY=legacy-app-local-key -e LOG_TO_STDOUT=1 microblog:manual'
