#!/bin/bash
set -euo pipefail
server=${1:?test-server or prod-server}
export FLASK_ENV=production
docker build -t microblog:manual .
docker save microblog:manual | ssh "$server" 'docker load'
