#!/bin/bash
set -euo pipefail
server=${1:?test-server or prod-server}
export FLASK_ENV=production
# The historical manual release directory is overwritten on each upload.
git archive HEAD | ssh "$server" 'mkdir -p /srv/microblog/releases/manual; tar xf - -C /srv/microblog/releases/manual'
